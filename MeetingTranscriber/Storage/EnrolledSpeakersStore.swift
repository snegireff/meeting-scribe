import Foundation

/// A remembered voice: a human name paired with the 256-dim speaker embedding
/// FluidAudio produced for them. Persisted so future meetings can auto-label
/// the same voice instead of showing a generic "Remote N".
struct EnrolledSpeaker: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    /// L2-normalized 256-dim WeSpeaker embedding (averaged over the enrolled
    /// speaker's segments).
    var embedding: [Float]
    var createdAt: Date = Date()
}

/// Persists enrolled voice profiles in UserDefaults (same lightweight pattern
/// as `DictionaryStore`). Embeddings are ~1 KB each, so a handful of profiles
/// is negligible.
enum EnrolledSpeakersStore {
    private static let key = "VoiceEnrollment.Profiles"

    static func load() -> [EnrolledSpeaker] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([EnrolledSpeaker].self, from: data)
        else { return [] }
        return decoded
    }

    static func save(_ profiles: [EnrolledSpeaker]) {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
