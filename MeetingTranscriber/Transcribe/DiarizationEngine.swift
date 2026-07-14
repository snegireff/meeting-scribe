import Foundation
import AVFoundation
import FluidAudio

/// Wraps FluidAudio's offline pyannote-based diarizer.
actor DiarizationEngine {
    private var manager: DiarizerManager?
    private var models: DiarizerModels?

    func diarize(wavURL: URL,
                 progress: @escaping (Double, String) -> Void) async throws -> [DiarizedSegment] {
        progress(0.05, "Loading diarization models")
        if manager == nil {
            let models = try await DiarizerModels.downloadIfNeeded()
            let mgr = DiarizerManager()
            mgr.initialize(models: models)
            self.manager = mgr
            self.models = models
        }
        progress(0.3, "Analyzing speakers")
        let samples = try AudioSamples.load16kMono(from: wavURL)
        guard let manager else { return [] }
        let result = try manager.performCompleteDiarization(samples, sampleRate: 16000)
        return result.segments.map {
            DiarizedSegment(start: Double($0.startTimeSeconds),
                            end: Double($0.endTimeSeconds),
                            speakerId: Self.intSpeakerID(from: $0.speakerId),
                            embedding: $0.embedding)
        }
    }

    private static func intSpeakerID(from raw: String) -> Int {
        // FluidAudio returns strings like "Speaker 1" or "speaker_0" depending on version.
        let digits = raw.filter { $0.isNumber }
        return Int(digits) ?? abs(raw.hashValue % 32)
    }
}

struct DiarizedSegment: Hashable {
    let start: Double
    let end: Double
    let speakerId: Int
    let embedding: [Float]
}
