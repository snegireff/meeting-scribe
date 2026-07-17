import Foundation
import FluidAudio

/// Wraps FluidAudio's Parakeet TDT v3 batch ASR — an on-device (CoreML/ANE)
/// multilingual speech-to-text model. Same role as `WhisperEngine`: audio → text
/// segments. Chosen over Whisper for Ukrainian (lower WER, ~100× realtime).
/// Diarization and summarization are untouched — this only swaps transcription.
actor ParakeetEngine {
    /// Shared engine so the loaded CoreML models (encoder/decoder/joint) survive
    /// across jobs. A fresh engine per transcription re-downloads/re-compiles.
    static let shared = ParakeetEngine()

    private var manager: AsrManager?

    /// Load + warm the model ahead of time so the first transcription isn't a
    /// cold download + CoreML compile.
    func prewarm() async {
        _ = try? await ensureManager()
    }

    func transcribe(url: URL,
                    language: TranscriptionLanguage,
                    progress: @escaping (Double, String) -> Void) async throws -> [WhisperSegment] {
        progress(0.05, "Loading Parakeet v3")
        let manager = try await ensureManager()
        progress(0.25, "Transcribing (\(language.displayName))…")

        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(url,
                                                  decoderState: &decoderState,
                                                  language: Self.fluidLanguage(for: language))
        progress(0.85, "Aligning segments…")
        NSLog("Parakeet: %d chars, %d token timings", result.text.count, result.tokenTimings?.count ?? 0)
        return Self.buildSegments(from: result)
    }

    // MARK: - Model lifecycle

    private func ensureManager() async throws -> AsrManager {
        if let manager { return manager }
        NSLog("Parakeet: downloading/loading v3 models")
        let version: AsrModelVersion = .v3
        let models = try await AsrModels.downloadAndLoad(version: version)
        // v3 multilingual: melChunkContext=false. The 80ms mel prepend (a fix
        // for blank predictions on long *English*) shifts the encoder's
        // first-frame distribution enough that the decoder drifts back to its
        // English-biased prior on non-English audio — exactly what we're here
        // to avoid for Ukrainian.
        let config = ASRConfig(
            tdtConfig: TdtConfig(blankId: version.blankId),
            encoderHiddenSize: version.encoderHiddenSize,
            melChunkContext: false
        )
        let mgr = AsrManager(config: config)
        try await mgr.loadModels(models)
        self.manager = mgr
        NSLog("Parakeet: models ready")
        return mgr
    }

    private static func fluidLanguage(for language: TranscriptionLanguage) -> Language {
        switch language {
        case .ukrainian: return .ukrainian
        case .english:   return .english
        }
    }

    // MARK: - Segment reconstruction

    /// Parakeet returns one transcript plus per-token timings — not Whisper-style
    /// segments. Rebuild sentence-ish segments by cutting on a natural pause or
    /// sentence-ending punctuation, so downstream merge + diarization overlap
    /// keep working.
    private static func buildSegments(from result: ASRResult) -> [WhisperSegment] {
        guard let timings = result.tokenTimings, !timings.isEmpty else {
            return wholeTextSegment(result)
        }

        let pauseCut = 0.8   // seconds of silence that ends a segment
        var out: [WhisperSegment] = []
        var group: [TokenTiming] = []

        func flush() {
            guard let first = group.first, let last = group.last else { return }
            let text = detokenize(group)
            if !text.isEmpty {
                out.append(WhisperSegment(start: first.startTime, end: last.endTime, text: text))
            }
            group.removeAll(keepingCapacity: true)
        }

        for t in timings {
            if let prev = group.last, t.startTime - prev.endTime > pauseCut {
                flush()
            }
            group.append(t)
            if t.token.contains(where: { ".?!…".contains($0) }) {
                flush()
            }
        }
        flush()

        return out.isEmpty ? wholeTextSegment(result) : out
    }

    private static func wholeTextSegment(_ result: ASRResult) -> [WhisperSegment] {
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return [WhisperSegment(start: 0, end: result.duration, text: text)]
    }

    /// SentencePiece tokens use ▁ (U+2581) for word boundaries — the same
    /// detokenize rule FluidAudio applies internally.
    private static func detokenize(_ tokens: [TokenTiming]) -> String {
        tokens.map(\.token).joined()
            .replacingOccurrences(of: "\u{2581}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
