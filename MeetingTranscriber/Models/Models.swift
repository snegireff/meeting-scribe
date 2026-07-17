import Foundation

enum TranscriptionLanguage: String, CaseIterable, Codable, Identifiable, Hashable {
    case english   = "en"
    case ukrainian = "uk"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .english:   return "English"
        case .ukrainian: return "Українська"
        }
    }
    var flag: String {
        switch self {
        case .english:   return "🇬🇧"
        case .ukrainian: return "🇺🇦"
        }
    }
}

enum WhisperModel: String, CaseIterable, Codable, Identifiable, Hashable {
    // WhisperKit prefixes these with "openai_whisper-" internally;
    // raw values must match folder suffixes in argmaxinc/whisperkit-coreml.
    // Using quantized 632MB/626MB variants for fast downloads (negligible WER diff).
    case largeV3Turbo = "large-v3-v20240930_turbo_632MB"
    case largeV3      = "large-v3-v20240930_626MB"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .largeV3Turbo: return "Whisper Large v3 Turbo (fast, ~632 MB)"
        case .largeV3:      return "Whisper Large v3 (best quality, ~626 MB)"
        }
    }
    var shortName: String {
        switch self {
        case .largeV3Turbo: return "large-v3-turbo"
        case .largeV3:      return "large-v3"
        }
    }

    /// Default transcription model per language. Ukrainian leans on the more
    /// accurate full large-v3; other languages use the much faster turbo
    /// variant. The user can still override via the Model picker.
    static func preferred(for language: TranscriptionLanguage) -> WhisperModel {
        switch language {
        case .ukrainian: return .largeV3
        case .english:   return .largeV3Turbo
        }
    }
}

/// Which speech-to-text engine transcribes a recording.
/// - `whisper`: WhisperKit / Whisper large-v3 (default; per-language model picker).
/// - `parakeet`: FluidAudio's Parakeet TDT v3 — multilingual CoreML, faster,
///   and stronger on Ukrainian. Ignores the WhisperModel picker.
enum TranscriptionEngine: String, CaseIterable, Codable, Identifiable, Hashable {
    case whisper
    case parakeet

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .whisper:  return "Whisper (large-v3)"
        case .parakeet: return "Parakeet v3 (multilingual, faster)"
        }
    }
}

/// User-facing engine choice. `auto` picks per language — Parakeet for Ukrainian
/// (lower WER, no silence hallucinations), Whisper for English (its blank-fix
/// `melChunkContext` helps long English). The other two force a specific engine.
enum TranscriptionEnginePreference: String, CaseIterable, Codable, Identifiable, Hashable {
    case auto
    case whisper
    case parakeet

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .auto:     return "Auto (Parakeet for Ukrainian, Whisper for English)"
        case .whisper:  return "Whisper (large-v3)"
        case .parakeet: return "Parakeet v3 (multilingual, faster)"
        }
    }

    /// Resolve to the concrete engine for a given language.
    func engine(for language: TranscriptionLanguage) -> TranscriptionEngine {
        switch self {
        case .whisper:  return .whisper
        case .parakeet: return .parakeet
        case .auto:     return language == .ukrainian ? .parakeet : .whisper
        }
    }
}

struct DetectedMeeting: Equatable, Hashable, Identifiable {
    let id: UUID = UUID()
    let title: String
    let platform: String
    let url: String
    let detectedAt: Date
    /// Display names of the calendar event's attendees (organizer first), used
    /// as candidate names when labelling speakers. Empty for browser-detected
    /// meetings or events without an attendee list.
    var attendees: [String] = []

    static func == (lhs: DetectedMeeting, rhs: DetectedMeeting) -> Bool {
        lhs.url == rhs.url
    }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

struct TranscriptSegment: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    let start: Double   // seconds
    let end: Double     // seconds
    var speakerId: Int  // 0-based; -1 for unknown
    let text: String
}

struct SpeakerLabel: Codable, Hashable, Identifiable {
    let id: Int
    var name: String
}

struct WordReplacement: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var original: String          // may be comma-separated variants, e.g. "Anthropic, Enthropic"
    var replacement: String
    var isEnabled: Bool = true
}

/// Domain-term glossary entry, injected into the summarization system prompt
/// so the LLM can interpret proper nouns / jargon it can't infer from context.
/// Independent of `WordReplacement` (which rewrites Whisper output post-decoding).
struct GlossaryTerm: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var term: String              // e.g. "Estyl", "n8n"
    var definition: String        // short explanation, one line preferred
    var isEnabled: Bool = true
}

struct TranscriptDocument: Codable, Identifiable, Hashable {
    let id: String                // filename stem
    var title: String
    let date: Date
    var duration: TimeInterval
    let language: TranscriptionLanguage
    let modelShortName: String
    var sourceURL: String?        // meeting URL or imported file path
    var sourceKind: SourceKind
    var speakers: [SpeakerLabel]
    var segments: [TranscriptSegment]
    let audioFileName: String?    // basename of wav in the same dir
    /// Calendar attendee names captured when recording started — candidate
    /// names for the speakers. Optional so transcripts saved before this field
    /// existed still decode.
    var attendees: [String]? = nil

    // Summarization (optional — only set once the user runs one).
    var summary: String?
    var summaryModelShortName: String?
    var summaryGeneratedAt: Date?
    // Per-meeting override for the summarization model. nil = use the
    // language default from Settings.
    var summaryModelOverride: LanguageModel?

    /// Averaged 256-dim voice embedding per speaker id (key = "\(speakerId)"),
    /// captured from diarization. Enables voice enrollment: match a speaker
    /// against remembered profiles, and enroll a speaker from a saved transcript
    /// after the fact. Optional so transcripts saved before this field decode.
    var speakerEmbeddings: [String: [Float]]? = nil

    enum SourceKind: String, Codable {
        case live
        case imported
    }
}
