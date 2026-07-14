import Foundation

/// Matches per-speaker voice embeddings against enrolled profiles so that a
/// remembered voice ("Andrii") is auto-assigned instead of a placeholder
/// ("Remote 1"). Embeddings are L2-normalized 256-dim vectors from FluidAudio.
enum SpeakerMatcher {

    /// Cosine similarity. Both vectors are already ~unit length, but we
    /// re-normalize defensively (averaged embeddings drift off the unit sphere).
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na  += a[i] * a[i]
            nb  += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    /// Average a set of embeddings into one representative vector.
    static func average(_ embeddings: [[Float]]) -> [Float]? {
        let valid = embeddings.filter { !$0.isEmpty }
        guard let dim = valid.first?.count, dim > 0 else { return nil }
        var acc = [Float](repeating: 0, count: dim)
        for e in valid where e.count == dim {
            for i in 0..<dim { acc[i] += e[i] }
        }
        let n = Float(valid.count)
        guard n > 0 else { return nil }
        return acc.map { $0 / n }
    }

    /// True for the default placeholder names ("Remote", "Remote 2", "You").
    /// We only auto-relabel these — never a name the user has already set.
    static func isPlaceholderName(_ name: String) -> Bool {
        if name == "You" { return true }
        if name == "Remote" { return true }
        if name.hasPrefix("Remote "), Int(name.dropFirst("Remote ".count)) != nil { return true }
        return false
    }

    /// Similarity above which two embeddings are considered the same speaker.
    /// Tunable via UserDefaults; WeSpeaker same-speaker cosine typically 0.5–0.8,
    /// cross-speaker < 0.3, so 0.55 is a safe default.
    static var threshold: Float {
        let stored = UserDefaults.standard.float(forKey: "VoiceEnrollment.Threshold")
        return stored > 0 ? stored : 0.55
    }

    /// Rename any placeholder-named speaker in `doc` to an enrolled profile whose
    /// voice matches (cosine ≥ threshold). Only touches speakers that (a) still
    /// have a placeholder name and (b) have a stored embedding. Mutates in place.
    static func autoLabel(_ doc: inout TranscriptDocument, enrolled: [EnrolledSpeaker]) {
        guard !enrolled.isEmpty, let embeddings = doc.speakerEmbeddings else { return }
        let th = threshold
        for i in doc.speakers.indices {
            let speaker = doc.speakers[i]
            guard isPlaceholderName(speaker.name),
                  let emb = embeddings[String(speaker.id)], !emb.isEmpty else { continue }

            var best: (name: String, score: Float)?
            for profile in enrolled {
                let score = cosine(emb, profile.embedding)
                if score >= th, score > (best?.score ?? 0) {
                    best = (profile.name, score)
                }
            }
            if let best { doc.speakers[i].name = best.name }
        }
    }
}
