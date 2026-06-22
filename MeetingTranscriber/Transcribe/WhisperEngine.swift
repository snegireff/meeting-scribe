import Foundation
import AVFoundation
import OSLog
import WhisperKit

/// Thin wrapper around WhisperKit.
actor WhisperEngine {
    /// Shared engine for the whole app session. A loaded WhisperKit pipeline
    /// (the ~600 MB model + its ANE-compiled artifacts) is cached here and
    /// survives across jobs. Creating a fresh engine per transcription discards
    /// this cache and forces a full reload + ANE compile every time (≈ minutes).
    static let shared = WhisperEngine()

    private var pipelines: [WhisperModel: WhisperKit] = [:]

    /// Load (and warm) a model ahead of time. Call when a recording starts so
    /// the model is hot by the time the user stops and transcription begins,
    /// turning the multi-minute cold load into an invisible background step.
    func prewarm(model: WhisperModel) async {
        _ = try? await pipeline(for: model)
    }

    func transcribe(url: URL,
                    language: TranscriptionLanguage,
                    model: WhisperModel,
                    initialPrompt: String?,
                    progress: @escaping (Double, String) -> Void) async throws -> [WhisperSegment] {
        progress(0.05, "Loading \(model.shortName)")
        let pipeline = try await pipeline(for: model)
        progress(0.25, "Transcribing (\(language.displayName))…")

        // Load audio ourselves as 16 kHz mono fp32, then pass to WhisperKit's
        // audioArray overload. Bypasses WhisperKit's internal AVAudioFile path
        // which can silently yield zero samples on some WAV variants, and
        // recovers recordings whose header wasn't finalized (see AudioSamples).
        let samples = try AudioSamples.load16kMono(from: url)
        Log.whisper.notice("loaded \(samples.count, privacy: .public) samples (\(Double(samples.count) / 16_000, privacy: .public)s)")
        guard !samples.isEmpty else {
            Log.whisper.error("audio file produced no samples — aborting")
            return []
        }

        // Whisper "prime" via `DecodingOptions.promptTokens` is disabled —
        // feeding tokenized text produced an empty decode (Whisper returned
        // segments with 0-char text regardless of filtering). Revisit once
        // we have a verified path to inject a conditioning prompt that
        // doesn't clobber the prefill. Dictionary replacements still work as
        // a post-processing pass.
        let promptTokens: [Int]? = nil
        if let text = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            Log.whisper.notice("prime present but currently ignored (priming disabled): \(text, privacy: .public)")
        }

        let decodeOptions = DecodingOptions(
            verbose: true,
            task: .transcribe,
            language: language.rawValue,
            temperature: 0.0,
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: true,
            promptTokens: promptTokens
        )

        let results = try await pipeline.transcribe(audioArray: samples,
                                                    decodeOptions: decodeOptions)
        progress(0.85, "Aligning segments…")
        Log.whisper.notice("got \(results.count, privacy: .public) result chunks")

        var out: [WhisperSegment] = []
        for (i, r) in results.enumerated() {
            Log.whisper.notice("chunk \(i, privacy: .public) — text=\(r.text.count, privacy: .public) chars, segments=\(r.segments.count, privacy: .public), language=\(r.language, privacy: .public)")
            for seg in r.segments {
                let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { continue }
                out.append(WhisperSegment(start: Double(seg.start),
                                          end: Double(seg.end),
                                          text: text))
            }
        }

        // Fallback: if segments are empty but the top-level text isn't.
        if out.isEmpty {
            let joined = results.map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                Log.whisper.notice("no segments; using joined text as single segment")
                let duration = Double(samples.count) / 16_000
                out.append(WhisperSegment(start: 0, end: duration, text: joined))
            } else {
                Log.whisper.error("empty output")
            }
        }

        return out
    }

    private func pipeline(for model: WhisperModel) async throws -> WhisperKit {
        if let p = pipelines[model] { return p }
        NSLog("Whisper: loading pipeline \"%@\"", model.rawValue)
        let config = WhisperKitConfig(
            model: model.rawValue,
            modelRepo: "argmaxinc/whisperkit-coreml",
            verbose: true,
            prewarm: true,
            load: true,
            download: true
        )
        let pipe = try await WhisperKit(config)
        pipelines[model] = pipe
        NSLog("Whisper: pipeline ready")
        return pipe
    }
}

struct WhisperSegment: Hashable {
    let start: Double
    let end: Double
    let text: String
}
