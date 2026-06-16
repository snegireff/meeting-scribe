import Foundation

/// One finalized live-translation line.
struct LiveCaption: Identifiable, Equatable {
    let id = UUID()
    var original: String
    var translated: String
}

/// Drives a live-translation session: takes 16 kHz mono float samples from the
/// recording pipeline, packs them into 100 ms 16-bit PCM chunks, streams them to
/// the Gemini Live API, and turns the returned transcription text into captions.
///
/// Audio is fed from the capture thread; buffering happens on a private serial
/// queue. Caption updates are published via `onUpdate` on the main queue.
final class LiveTranslator {
    /// 100 ms at 16 kHz.
    private static let chunkFrames = 1600

    /// Touched only on `queue` (the buffer serial queue) so the capture-thread
    /// feed and the reconnect swap never race on it.
    private var client: GeminiLiveClient
    private let queue = DispatchQueue(label: "live.translate.buffer")
    private var pending: [Float] = []

    // Reconnect state — all on the main queue (set in start/finish/handle).
    private let apiKey: String
    private var targetCode = "en"
    private var stopped = false
    private var reconnectAttempt = 0

    // Accumulated text for the in-progress turn.
    private var currentOriginal = ""
    private var currentTranslated = ""

    /// (finalized captions, in-progress translated line). Main queue.
    var onUpdate: (([LiveCaption], String) -> Void)?
    /// Connection status. Main queue. nil error = healthy/closed cleanly.
    var onStatus: ((Status) -> Void)?

    enum Status: Equatable { case connecting, live, closed(String?) }

    private(set) var captions: [LiveCaption] = []

    init(apiKey: String) {
        self.apiKey = apiKey
        client = GeminiLiveClient(apiKey: apiKey)
        client.onEvent = { [weak self] event in self?.handle(event) }
    }

    func start(targetCode: String) {
        self.targetCode = targetCode
        stopped = false
        reconnectAttempt = 0
        onStatus?(.connecting)
        queue.async { [weak self] in self?.client.start(targetCode: targetCode) }
    }

    /// Rebuild the socket after an unexpected close (Gemini Live caps session
    /// length, so a long meeting will be kicked every few minutes) so subtitles
    /// resume instead of freezing on the last line. Accumulated captions are
    /// kept; only a brief gap of audio is lost during the swap. Called on main.
    private func scheduleReconnect(_ error: String?) {
        guard !stopped else { onStatus?(.closed(error)); return }
        reconnectAttempt += 1
        let delay = min(8.0, pow(2.0, Double(reconnectAttempt - 1))) // 1,2,4,8,8…
        currentOriginal = ""
        currentTranslated = ""
        onStatus?(.connecting)
        NSLog("LiveTranslator: reconnecting (#\(reconnectAttempt)) after close: \(error ?? "nil")")
        let code = targetCode
        let key = apiKey
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped else { return }
            self.queue.async { [weak self] in
                guard let self else { return }
                let fresh = GeminiLiveClient(apiKey: key)
                fresh.onEvent = { [weak self] e in self?.handle(e) }
                self.client = fresh
                fresh.start(targetCode: code)
            }
        }
    }

    /// Feed 16 kHz mono float samples (called from the capture thread).
    func feed(_ samples: [Float]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pending.append(contentsOf: samples)
            while self.pending.count >= Self.chunkFrames {
                let chunk = Array(self.pending.prefix(Self.chunkFrames))
                self.pending.removeFirst(Self.chunkFrames)
                self.client.sendAudio(base64: Self.encode(chunk))
            }
        }
    }

    /// Original-language lines recognized so far (finalized + in-progress).
    /// Read on the main queue (same as caption updates).
    func originalLines() -> [String] {
        var lines = captions.map(\.original).filter { !$0.isEmpty }
        let partial = currentOriginal.trimmingCharacters(in: .whitespacesAndNewlines)
        if !partial.isEmpty { lines.append(partial) }
        return lines
    }

    /// Translated lines so far (finalized + in-progress).
    func translatedLines() -> [String] {
        var lines = captions.map(\.translated).filter { !$0.isEmpty }
        let partial = currentTranslated.trimmingCharacters(in: .whitespacesAndNewlines)
        if !partial.isEmpty { lines.append(partial) }
        return lines
    }

    func finish() {
        stopped = true
        queue.async { [weak self] in
            guard let self else { return }
            if !self.pending.isEmpty {
                self.client.sendAudio(base64: Self.encode(self.pending))
                self.pending.removeAll()
            }
            self.client.close()
        }
    }

    // MARK: – Event handling (main queue)

    private func handle(_ event: LiveEvent) {
        switch event {
        case .ready:
            reconnectAttempt = 0
            onStatus?(.live)
        case .input(let text):
            currentOriginal += text
            publishInProgress()
        case .output(let text):
            currentTranslated += text
            publishInProgress()
        case .turnComplete:
            let original = currentOriginal.trimmingCharacters(in: .whitespacesAndNewlines)
            let translated = currentTranslated.trimmingCharacters(in: .whitespacesAndNewlines)
            currentOriginal = ""
            currentTranslated = ""
            // Subtitles show the original spoken text, so finalize a line as soon
            // as the source transcription is non-empty (translation is ignored).
            guard !original.isEmpty else { publishInProgress(); return }
            captions.append(LiveCaption(original: original, translated: translated))
            onUpdate?(captions, "")
        case .closed(let error):
            // Deliberate finish() → report closed; otherwise reconnect so the
            // Gemini session limit doesn't freeze subtitles mid-meeting.
            scheduleReconnect(error)
        }
    }

    private func publishInProgress() {
        // The in-progress line is the original source transcription (the subtitle).
        onUpdate?(captions, currentOriginal.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: – Float32 → little-endian Int16 PCM → base64

    private static func encode(_ samples: [Float]) -> String {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            let value = Int16(clamped * 32767)
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data.base64EncodedString()
    }
}
