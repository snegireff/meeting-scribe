import Foundation
import Observation
import SwiftUI
import AppKit

@MainActor
@Observable
final class AppState {

    /// Weak handle so the AppDelegate can start process-level background
    /// services at launch, independent of whether the main window appears
    /// (a menu-bar app can be relaunched windowless via state restoration).
    @ObservationIgnored static weak var shared: AppState?

    init() {
        Self.shared = self
    }

    // MARK: – Settings
    var selectedModel: WhisperModel = WhisperModel.preferred(for: .ukrainian)
    var defaultLanguage: TranscriptionLanguage = .ukrainian {
        didSet {
            // Keep the transcription model in step with the language default:
            // Ukrainian → large-v3 (more accurate), others → turbo (faster).
            // Fires only on an actual change, so a manual model pick survives
            // until the user switches language again.
            guard oldValue != defaultLanguage else { return }
            selectedModel = WhisperModel.preferred(for: defaultLanguage)
        }
    }
    var captureSystemAudio: Bool = true

    /// Speech-to-text engine preference. Persisted so the choice sticks across
    /// launches. Default `auto` = Parakeet for Ukrainian, Whisper for English.
    var transcriptionEnginePreference: TranscriptionEnginePreference = {
        if let raw = UserDefaults.standard.string(forKey: "transcriptionEnginePreference"),
           let p = TranscriptionEnginePreference(rawValue: raw) { return p }
        return .auto
    }() {
        didSet {
            UserDefaults.standard.set(transcriptionEnginePreference.rawValue,
                                      forKey: "transcriptionEnginePreference")
        }
    }

    // MARK: – Live translation (Gemini Live API)
    private static let kGeminiKey = "gemini-api-key"

    /// Gemini API key, persisted in the Keychain (not UserDefaults).
    ///
    /// IMPORTANT: this is NOT read from the Keychain in the property initializer.
    /// `SecItemCopyMatching` can block the calling thread indefinitely waiting on
    /// `securityd` (e.g. when the binary was re-signed and the Keychain ACL no
    /// longer matches, so macOS wants to show an authorization dialog that a
    /// just-launched menu-bar app can't present). Doing that in `AppState.init()`
    /// — which SwiftUI runs synchronously on the main thread before the first
    /// scene renders — would deadlock the entire launch: no menu bar, no window,
    /// no background services, no recovery. Instead we start empty and load the
    /// key asynchronously off the main thread via `loadGeminiKeyFromKeychain()`.
    var geminiAPIKey: String = "" {
        didSet {
            guard !isLoadingGeminiKey else { return }   // skip persist on async load-in
            KeychainStore.set(geminiAPIKey, for: Self.kGeminiKey)
        }
    }
    @ObservationIgnored private var isLoadingGeminiKey = false

    /// Read the Gemini key from the Keychain off the main thread and publish it.
    /// Fire-and-forget from `bootstrap()` — never awaited on the launch path, so a
    /// hanging `securityd` round-trip can't stall the app.
    func loadGeminiKeyFromKeychain() {
        Task { [weak self] in
            let key = await Task.detached(priority: .utility) {
                KeychainStore.string(for: AppState.kGeminiKey) ?? ""
            }.value
            guard let self, self.geminiAPIKey.isEmpty, !key.isEmpty else { return }
            self.isLoadingGeminiKey = true
            self.geminiAPIKey = key
            self.isLoadingGeminiKey = false
        }
    }
    var liveTranslateEnabled: Bool = UserDefaults.standard.bool(forKey: "liveTranslateEnabled") {
        didSet { UserDefaults.standard.set(liveTranslateEnabled, forKey: "liveTranslateEnabled") }
    }
    var liveTargetLanguage: TargetLanguage = {
        if let raw = UserDefaults.standard.string(forKey: "liveTargetLanguage"),
           let lang = TargetLanguage(rawValue: raw) { return lang }
        return .ukrainian
    }() {
        didSet { UserDefaults.standard.set(liveTargetLanguage.rawValue, forKey: "liveTargetLanguage") }
    }

    // MARK: – Summary export destinations (all opt-in; empty = disabled)
    static let kTelegramToken = "telegram-bot-token"
    var telegramBotToken: String = "" {
        didSet {
            guard !isLoadingTelegramToken else { return }   // skip persist on async load-in
            KeychainStore.set(telegramBotToken, for: Self.kTelegramToken)
        }
    }
    @ObservationIgnored private var isLoadingTelegramToken = false
    var telegramChatID: String = UserDefaults.standard.string(forKey: "telegramChatID") ?? "" {
        didSet { UserDefaults.standard.set(telegramChatID, forKey: "telegramChatID") }
    }
    var obsidianVaultPath: String = UserDefaults.standard.string(forKey: "obsidianVaultPath") ?? "" {
        didSet { UserDefaults.standard.set(obsidianVaultPath, forKey: "obsidianVaultPath") }
    }

    /// Load the Telegram bot token from the Keychain off-main, mirroring the
    /// Gemini key pattern so a hanging `securityd` round-trip can't stall launch.
    func loadTelegramTokenFromKeychain() {
        Task { [weak self] in
            let token = await Task.detached(priority: .utility) {
                KeychainStore.string(for: AppState.kTelegramToken) ?? ""
            }.value
            guard let self, self.telegramBotToken.isEmpty, !token.isEmpty else { return }
            self.isLoadingTelegramToken = true
            self.telegramBotToken = token
            self.isLoadingTelegramToken = false
        }
    }

    // MARK: – Voice enrollment (remembered voice profiles)
    var enrolledSpeakers: [EnrolledSpeaker] = EnrolledSpeakersStore.load()

    /// Live session state, updated while recording with translation on.
    var liveCaptions: [LiveCaption] = []
    var liveInProgress: String = ""
    var liveStatus: LiveTranslator.Status = .closed(nil)

    @ObservationIgnored private var translator: LiveTranslator?

    var hasGeminiKey: Bool {
        !geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: – Dictionary (persisted via DictionaryStore)
    var languagePrimes: [String: String] = DictionaryStore.loadPrimes()
    var wordReplacements: [WordReplacement] = DictionaryStore.loadReplacements()

    func setPrime(_ text: String, for language: TranscriptionLanguage) {
        languagePrimes[language.rawValue] = text
        DictionaryStore.savePrimes(languagePrimes)
    }

    func addReplacement(_ entry: WordReplacement) {
        wordReplacements.append(entry)
        DictionaryStore.saveReplacements(wordReplacements)
    }

    func updateReplacement(_ entry: WordReplacement) {
        guard let idx = wordReplacements.firstIndex(where: { $0.id == entry.id }) else { return }
        wordReplacements[idx] = entry
        DictionaryStore.saveReplacements(wordReplacements)
    }

    func removeReplacements(withIDs ids: Set<UUID>) {
        wordReplacements.removeAll { ids.contains($0.id) }
        DictionaryStore.saveReplacements(wordReplacements)
    }

    // MARK: – Summary glossary (persisted via DictionaryStore)
    var glossaryTerms: [GlossaryTerm] = DictionaryStore.loadGlossary()

    func addGlossaryTerm(_ entry: GlossaryTerm) {
        glossaryTerms.append(entry)
        DictionaryStore.saveGlossary(glossaryTerms)
    }

    func updateGlossaryTerm(_ entry: GlossaryTerm) {
        guard let idx = glossaryTerms.firstIndex(where: { $0.id == entry.id }) else { return }
        glossaryTerms[idx] = entry
        DictionaryStore.saveGlossary(glossaryTerms)
    }

    func removeGlossaryTerms(withIDs ids: Set<UUID>) {
        glossaryTerms.removeAll { ids.contains($0.id) }
        DictionaryStore.saveGlossary(glossaryTerms)
    }

    // MARK: – Summarization settings (persisted via SummaryStore)
    var defaultModelEnglish: LanguageModel = SummaryStore.loadDefaultModel(for: .english)
    var systemPromptEnglish: String        = SummaryStore.loadSystemPrompt(for: .english)
    var downloadedModelIDs:  Set<String>   = SummaryStore.loadDownloadedIDs()

    /// User's display name. When non-empty, the `summarize` identification
    /// phase replaces the mic-stem placeholder `"You"` with this value on every
    /// run. The LLM does not need to infer it.
    var userDisplayName: String = SummaryStore.loadUserDisplayName()

    func setUserDisplayName(_ value: String) {
        userDisplayName = value.trimmingCharacters(in: .whitespacesAndNewlines)
        SummaryStore.saveUserDisplayName(userDisplayName)
    }

    func setDefaultModel(_ model: LanguageModel, for language: TranscriptionLanguage) {
        switch language {
        case .english, .ukrainian: defaultModelEnglish = model
        }
        SummaryStore.saveDefaultModel(model, for: language)
    }

    /// Per-meeting summary model override. Pass `nil` to clear and fall back to
    /// the language default from Settings.
    func setSummaryModelOverride(_ model: LanguageModel?, for transcriptID: String) {
        guard let idx = transcripts.firstIndex(where: { $0.id == transcriptID }) else { return }
        var updated = transcripts[idx]
        updated.summaryModelOverride = model
        transcripts[idx] = updated
        try? TranscriptStore.shared.save(updated, audioSource: nil)
    }

    func setSystemPrompt(_ text: String, for language: TranscriptionLanguage) {
        switch language {
        case .english, .ukrainian: systemPromptEnglish = text
        }
        SummaryStore.saveSystemPrompt(text, for: language)
    }

    // MARK: – Summarization runtime state
    enum ModelDownloadState: Equatable {
        case notDownloaded
        case downloading(fraction: Double)
        case downloaded
    }
    var modelDownloadStates: [LanguageModel: ModelDownloadState] = [:]
    private var downloadTasks: [LanguageModel: Task<Void, Error>] = [:]

    enum SummarizationStage: Equatable {
        case idle
        case loadingModel(fraction: Double)
        // First pass — read transcript, propose names for placeholder speakers.
        case identifyingSpeakers
        case generatingSummary(text: String)
        // Summary is finalized at this point — carried forward so the UI keeps
        // it visible while the title pass runs.
        case generatingTitle(summary: String)
        case done
        case error(String)

        var isActive: Bool {
            switch self {
            case .idle, .done, .error: false
            default: true
            }
        }
    }
    var summarizationStage: SummarizationStage = .idle
    var summarizingTranscriptID: String?
    private let summaryEngine = SummarizationEngine()
    private var summarizeTask: Task<Void, Never>?
    private var idleUnloadTask: Task<Void, Never>?
    /// How long to keep the summarization model resident after the last use
    /// before dropping it. Keeps consecutive summaries fast while releasing
    /// 4–8 GB of unified memory when you walk away.
    private let idleUnloadAfterSeconds: UInt64 = 180

    func modelState(for model: LanguageModel) -> ModelDownloadState {
        if let state = modelDownloadStates[model] { return state }
        return downloadedModelIDs.contains(model.repoID) ? .downloaded : .notDownloaded
    }

    // MARK: – Model library actions

    func downloadModel(_ model: LanguageModel) {
        guard downloadTasks[model] == nil else {
            NSLog("Summary: downloadModel(%@) ignored — already in flight", model.shortName)
            return
        }
        NSLog("Summary: downloadModel(%@) started", model.shortName)
        modelDownloadStates[model] = .downloading(fraction: 0)

        downloadTasks[model] = Task { [weak self, summaryEngine] in
            defer {
                Task { @MainActor in
                    self?.downloadTasks[model] = nil
                }
            }
            do {
                try await summaryEngine.prefetch(model) { fraction in
                    NSLog("Summary: %@ progress %.3f", model.shortName, fraction)
                    Task { @MainActor in
                        self?.modelDownloadStates[model] = .downloading(fraction: fraction)
                    }
                }
                NSLog("Summary: prefetch(%@) returned ok", model.shortName)
                await MainActor.run {
                    self?.markDownloaded(model)
                }
            } catch is CancellationError {
                NSLog("Summary: prefetch(%@) cancelled", model.shortName)
                await MainActor.run {
                    self?.modelDownloadStates[model] = .notDownloaded
                }
            } catch {
                NSLog("Summary: prefetch(%@) error: %@", model.shortName, String(describing: error))
                await MainActor.run {
                    self?.modelDownloadStates[model] = .notDownloaded
                    self?.lastError = "Model download failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func cancelDownload(_ model: LanguageModel) {
        downloadTasks[model]?.cancel()
        downloadTasks[model] = nil
        modelDownloadStates[model] = .notDownloaded
    }

    func deleteModel(_ model: LanguageModel) {
        // Cancel active task first.
        downloadTasks[model]?.cancel()
        downloadTasks[model] = nil

        // Best-effort delete from the common HuggingFace cache locations.
        SummaryStore.deleteCachedFiles(for: model)

        downloadedModelIDs.remove(model.repoID)
        SummaryStore.saveDownloadedIDs(downloadedModelIDs)
        modelDownloadStates[model] = .notDownloaded
    }

    func unloadSummaryModel() async {
        await summaryEngine.unload()
    }

    private func markDownloaded(_ model: LanguageModel) {
        NSLog("Summary: markDownloaded(%@)", model.shortName)
        downloadedModelIDs.insert(model.repoID)
        SummaryStore.saveDownloadedIDs(downloadedModelIDs)
        modelDownloadStates[model] = .downloaded
    }

    // MARK: – Summarize a transcript

    /// Summarize a transcript.
    ///
    /// `customSummaryInstruction`, if non-empty, replaces the built-in
    /// "write 3–6 sentences…" user prompt for *just the summary pass*. The
    /// title pass always uses its default. This is the per-invocation override
    /// surfaced via the popover next to the Summarize/Regenerate button; the
    /// persistent system prompt in Settings is still applied on top as the
    /// `instructions:` for the ChatSession.
    func summarize(
        transcriptID: String,
        customSummaryInstruction: String? = nil,
        model: LanguageModel? = nil,
        useGlossary: Bool = true,
        inferSpeakerNames: Bool = true
    ) {
        guard let doc = transcripts.first(where: { $0.id == transcriptID }) else { return }
        guard summarizeTask == nil else { return }
        cancelIdleUnload()

        let language = doc.language
        let candidateNames = doc.attendees ?? []
        let resolvedModel: LanguageModel = model
            ?? doc.summaryModelOverride
            ?? defaultModelEnglish
        let basePrompt = systemPromptEnglish
        let glossaryAppendix: String? = useGlossary
            ? SummaryPrompts.glossaryBlock(for: language, terms: glossaryTerms)
            : nil
        let systemPrompt: String = glossaryAppendix.map { basePrompt + "\n\n" + $0 } ?? basePrompt
        let initialFeed = TranscriptFormatter.renderPlainForLLM(doc)
        let disableThinking = resolvedModel.usesThinkingMode
        let configuredUserName = userDisplayName
        let currentTitle = doc.title
        // For imported files, sourceURL holds the original filename (see
        // `TranscriptionPipeline.importedFileName`). Expose it so the title
        // guard recognises an untouched "Filename.m4a" as auto-generated.
        let sourceFilename = (doc.sourceKind == .imported) ? doc.sourceURL : nil

        summarizingTranscriptID = transcriptID
        summarizationStage = .loadingModel(fraction: 0)

        summarizeTask = Task { [weak self, summaryEngine] in
            defer {
                Task { @MainActor in self?.summarizeTask = nil }
            }
            do {
                try await summaryEngine.ensureLoaded(resolvedModel) { fraction in
                    Task { @MainActor in
                        self?.summarizationStage = .loadingModel(fraction: fraction)
                    }
                }
                await MainActor.run { self?.markDownloaded(resolvedModel) }

                // --- Identification phase (runs before the summary pass so
                //     downstream prompts see real names instead of "Remote N") ---
                await MainActor.run {
                    self?.summarizationStage = .identifyingSpeakers
                }
                let defaultRemoteRegex = try! Regex<Substring>("^Remote(?: \\d+)?$")
                var workingSpeakers = doc.speakers

                // 1) Deterministic: rename "You" → configured user display name.
                if !configuredUserName.isEmpty {
                    for i in workingSpeakers.indices where workingSpeakers[i].name == "You" {
                        workingSpeakers[i].name = configuredUserName
                    }
                }

                // 2) LLM inference for remote defaults (only when requested
                //    and there's actually something with a default name).
                let remoteToInfer = inferSpeakerNames
                    ? workingSpeakers.filter {
                        (try? defaultRemoteRegex.wholeMatch(in: $0.name)) != nil
                    }
                    : []
                if !remoteToInfer.isEmpty {
                    let identifyPrompt = SummaryPrompts.identifyInstruction(
                        for: language,
                        labels: remoteToInfer.map(\.name),
                        candidates: candidateNames
                    ) + "\n\nTranscript:\n" + initialFeed
                    let identifyStream = try await summaryEngine.stream(
                        prompt: identifyPrompt,
                        instructions: systemPrompt,
                        maxTokens: 200,
                        temperature: 0.1,
                        disableThinking: disableThinking
                    )
                    var identifyRaw = ""
                    for try await chunk in identifyStream {
                        if Task.isCancelled { throw SummarizationError.cancelled }
                        identifyRaw += chunk
                    }
                    let cleaned = SummaryPrompts.stripThinking(identifyRaw)
                    let inferred = SummaryPrompts.parseInferredNames(cleaned)
                    for i in workingSpeakers.indices {
                        let currentName = workingSpeakers[i].name
                        guard (try? defaultRemoteRegex.wholeMatch(in: currentName)) != nil,
                              let proposed = inferred[currentName],
                              !proposed.isEmpty,
                              proposed.lowercased() != "unknown"
                        else { continue }
                        workingSpeakers[i].name = proposed
                    }
                }

                // 3) Persist relabeled speakers immediately so the UI updates
                //    even if a later pass fails, then re-render the LLM feed.
                let feed: String = await MainActor.run {
                    guard let self,
                          let idx = self.transcripts.firstIndex(where: { $0.id == transcriptID })
                    else { return initialFeed }
                    if self.transcripts[idx].speakers != workingSpeakers {
                        var updated = self.transcripts[idx]
                        updated.speakers = workingSpeakers
                        self.transcripts[idx] = updated
                        try? TranscriptStore.shared.save(updated, audioSource: nil)
                        return TranscriptFormatter.renderPlainForLLM(updated)
                    }
                    return initialFeed
                }

                // --- Summary pass ---
                await MainActor.run {
                    self?.summarizationStage = .generatingSummary(text: "")
                }
                var summaryText = ""
                let summaryInstruction = customSummaryInstruction?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let effectiveSummaryInstruction: String =
                    (summaryInstruction?.isEmpty == false ? summaryInstruction! :
                        SummaryPrompts.summaryInstruction(for: language))
                let summaryPrompt =
                    effectiveSummaryInstruction
                    + "\n\nTranscript:\n" + feed
                let summaryStream = try await summaryEngine.stream(
                    prompt: summaryPrompt,
                    instructions: systemPrompt,
                    maxTokens: 600,
                    temperature: 0.3,
                    disableThinking: disableThinking
                )
                for try await chunk in summaryStream {
                    if Task.isCancelled { throw SummarizationError.cancelled }
                    summaryText += chunk
                    let visible = SummaryPrompts.stripThinking(summaryText)
                    await MainActor.run {
                        self?.summarizationStage = .generatingSummary(text: visible)
                    }
                }

                // Freeze the finalized summary so the UI keeps it visible
                // during the next streaming passes.
                let finalizedSummary = SummaryPrompts
                    .stripThinking(summaryText)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                // --- Title pass (short, one-line) ---
                await MainActor.run {
                    self?.summarizationStage = .generatingTitle(
                        summary: finalizedSummary)
                }
                var titleText = ""
                let titlePrompt =
                    SummaryPrompts.titleInstruction(for: language)
                    + "\n\nTranscript:\n" + feed
                let titleStream = try await summaryEngine.stream(
                    prompt: titlePrompt,
                    instructions: systemPrompt,
                    maxTokens: 40,
                    temperature: 0.2,
                    disableThinking: disableThinking
                )
                for try await chunk in titleStream {
                    if Task.isCancelled { throw SummarizationError.cancelled }
                    titleText += chunk
                }

                let finalTitle = SummaryPrompts.sanitizeTitle(titleText)
                let modelShort = resolvedModel.shortName

                await MainActor.run {
                    guard let self else { return }
                    guard let idx = self.transcripts.firstIndex(where: { $0.id == transcriptID })
                    else { return }
                    var updated = self.transcripts[idx]
                    updated.summary = finalizedSummary
                    updated.summaryModelShortName = modelShort
                    updated.summaryGeneratedAt = Date()
                    // Replace the placeholder "Recording — <date>" / "Google Meet — <slug>"
                    // style titles but preserve anything the user has edited.
                    if !finalTitle.isEmpty,
                       self.shouldReplaceTitle(currentTitle, sourceFilename: sourceFilename) {
                        updated.title = finalTitle
                    }
                    self.transcripts[idx] = updated
                    try? TranscriptStore.shared.save(updated, audioSource: nil)
                    self.summarizationStage = .done
                    self.summarizingTranscriptID = nil
                    self.scheduleIdleUnload()
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.summarizationStage = .idle
                    self?.summarizingTranscriptID = nil
                }
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run {
                    self?.summarizationStage = .error(msg)
                    self?.summarizingTranscriptID = nil
                }
            }
        }
    }

    func cancelSummarization() {
        summarizeTask?.cancel()
    }

    /// Arm a one-shot timer that drops the resident model if the user doesn't
    /// kick off another summary within `idleUnloadAfterSeconds`. Also releases
    /// MLX's allocator cache immediately so we're not sitting on multi-GB of
    /// reusable buffers between runs.
    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        let delay = idleUnloadAfterSeconds
        idleUnloadTask = Task { [weak self, summaryEngine] in
            await summaryEngine.releaseCaches()
            do {
                try await Task.sleep(nanoseconds: delay * 1_000_000_000)
            } catch {
                return // cancelled by a new summarize call
            }
            await summaryEngine.unload()
            await MainActor.run {
                self?.idleUnloadTask = nil
            }
        }
    }

    private func cancelIdleUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
    }

    /// Decide whether we're allowed to overwrite the transcript title with
    /// an LLM-generated one. User-edited titles are preserved; the auto-
    /// generated fallbacks are not.
    ///
    /// The fallbacks we recognise:
    /// • `"Recording — <date>"` for unnamed live recordings
    /// • `"Google Meet — <slug>"` / Zoom / Teams / Whereby for meeting drops
    /// • The raw imported filename (from `sourceURL`) — or anything ending in
    ///   a common audio/video extension, as a belt-and-suspenders catch
    private func shouldReplaceTitle(_ current: String, sourceFilename: String?) -> Bool {
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if trimmed.hasPrefix("Recording — ") { return true }
        let meetingPrefixes = ["Google Meet — ", "Zoom — ", "Teams — ", "Whereby — "]
        if meetingPrefixes.contains(where: trimmed.hasPrefix) { return true }
        if let sourceFilename, trimmed == sourceFilename { return true }
        let audioVideoExts = [".m4a", ".mp3", ".mp4", ".mov", ".wav",
                              ".mpeg", ".mpeg4", ".aif", ".aiff", ".flac", ".webm"]
        let lower = trimmed.lowercased()
        if audioVideoExts.contains(where: lower.hasSuffix) { return true }
        return false
    }

    // MARK: – Recording state
    /// Recording lifecycle only — transcription runs off on `processingJobs`
    /// so a new recording can start while a previous one is still being
    /// transcribed.
    enum RecordingState: Equatable {
        case idle
        case preparing
        case recording(startedAt: Date, meeting: DetectedMeeting?, language: TranscriptionLanguage)
        case stopping

        var isRecording: Bool { if case .recording = self { return true } else { return false } }
        /// True whenever the recorder itself is doing something (start, mid-record, stop).
        /// Does NOT reflect background transcription — see `isProcessing`.
        var isBusy: Bool { if case .idle = self { return false } else { return true } }
    }
    var recordingState: RecordingState = .idle
    var elapsedSeconds: Int = 0
    /// RMS of the mic stream (0–1ish).
    var currentMicRMS: Float = 0
    /// RMS of the system-audio stream (0–1ish). Stays 0 when system capture
    /// is disabled or no audio is playing through the captured display.
    var currentSystemRMS: Float = 0
    var isMicMuted: Bool = false
    /// Human-readable name of the default input device while recording
    /// (e.g. "MacBook Pro Microphone", "AirPods Pro"). Nil when not recording
    /// or when CoreAudio can't resolve the device.
    var currentInputDeviceName: String? = nil

    // MARK: – Background processing queue
    /// One transcription job — either a freshly captured recording or an
    /// imported media file. Jobs run serially on a single background drain
    /// task so a new recording can begin as soon as the previous one stops.
    struct ProcessingJob: Identifiable, Equatable {
        enum Input: Equatable {
            /// Stems already on disk (from RecordingCoordinator).
            case liveStems(voiceURL: URL, systemURL: URL?, duration: TimeInterval)
            /// User-imported media; needs decode → mono 16kHz WAV first.
            case importFile(sourceURL: URL)
        }
        enum Stage: Equatable {
            case queued
            case running(progress: Double, stage: String)
            case failed(String)

            var isQueued: Bool { if case .queued = self { return true } else { return false } }
            var isRunning: Bool { if case .running = self { return true } else { return false } }
        }
        let id: UUID
        /// Short human label for the queue panel (meeting title, "Recording — hh:mm", or filename).
        let title: String
        let input: Input
        let language: TranscriptionLanguage
        let meeting: DetectedMeeting?
        let sourceKind: TranscriptDocument.SourceKind
        let importedName: String?
        /// When set, this job re-transcribes an existing document's stems and
        /// overwrites that document in place (preserving the id + title,
        /// clearing any now-stale summary).
        let replacingDocumentID: String?
        /// Forces a specific Whisper model for this job regardless of the
        /// user's global `selectedModel`. Used by Re-transcribe.
        let modelOverride: WhisperModel?
        var stage: Stage
        let createdAt: Date
    }

    var processingJobs: [ProcessingJob] = []
    private var processingTask: Task<Void, Never>?
    private var didRecoverOrphans = false

    /// True when at least one job is queued or running.
    var isProcessing: Bool { !processingJobs.isEmpty }

    /// The job currently running (if any) — used by the UI to show a single
    /// progress line and the "+N queued" badge.
    var activeJob: ProcessingJob? {
        processingJobs.first(where: { $0.stage.isRunning })
    }

    var queuedJobCount: Int {
        processingJobs.filter { $0.stage.isQueued }.count
    }

    // MARK: – Meeting detection (sheet is item-driven off this)
    var detectedMeeting: DetectedMeeting? = nil
    var dismissedMeetingURLs: Set<String> = []

    // MARK: – Library
    var transcripts: [TranscriptDocument] = []
    var selectedTranscriptID: String? = nil

    // MARK: – UI triggers
    var importPanelRequested: Bool = false
    var lastError: String? = nil

    // Collaborators
    private var detector: MeetingDetector?
    private var recorder: RecordingCoordinator?
    private var elapsedTimer: Timer?
    private var didStartServices = false
    private var didBootstrap = false

    // MARK: – Bootstrap
    /// Window-level startup: load transcripts for the UI and make sure the
    /// process-level services are up (in case the window appeared before
    /// `applicationDidFinishLaunching` wired them).
    ///
    /// Fired from several triggers for launch reliability AND from
    /// `applicationDidBecomeActive` on every app activation. The heavy work
    /// (off-main Keychain read + parsing ~20 MB of transcripts) must run ONCE,
    /// not on every focus change — re-parsing on each activation froze the UI
    /// ("постійно вісить"). The guard runs synchronously before the first
    /// `await`, so concurrent calls on the main actor can't double-enter.
    /// In-app changes refresh transcripts via their own `loadTranscripts()`
    /// calls (e.g. after a recording saves), so no per-activation reload is lost.
    func bootstrap() async {
        if didBootstrap { return }
        didBootstrap = true
        NSLog("MT: bootstrap() entered")
        loadGeminiKeyFromKeychain()
        loadTelegramTokenFromKeychain()
        startBackgroundServices()
        await loadTranscripts()
        recoverOrphanedRecordings()
    }

    /// Re-enqueue recording stems on disk that have no matching transcript —
    /// e.g. a transcription that never finished because the app was quit mid-job.
    /// Idempotent: once a recovered transcript saves, its stem is referenced by
    /// `audioFileName` and skipped on the next launch.
    private func recoverOrphanedRecordings() {
        guard !didRecoverOrphans else { NSLog("MT: recover skipped (already ran)"); return }
        didRecoverOrphans = true
        let fm = FileManager.default
        let dir = TranscriptStore.shared.recordingsDir
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let referenced = Set(transcripts.compactMap { $0.audioFileName })
        let voiceStems = files
            .filter { $0.lastPathComponent.hasSuffix(".voice.wav") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        NSLog("MT: recover — \(voiceStems.count) voice stems, \(referenced.count) referenced")
        for voice in voiceStems {
            let name = voice.lastPathComponent
            guard !referenced.contains(name) else { continue }
            NSLog("MT: recover — enqueue orphan \(name)")
            let base = String(name.dropLast(".voice.wav".count))
            let systemURL = dir.appendingPathComponent("\(base).system.wav")
            let system = fm.fileExists(atPath: systemURL.path) ? systemURL : nil
            // Prefer the language chosen when the recording was made (written to
            // a `.lang` sidecar by RecordingCoordinator); fall back to the app
            // default only for older recordings that predate the sidecar.
            let langURL = dir.appendingPathComponent("\(base).lang")
            let recoveredLanguage = (try? String(contentsOf: langURL, encoding: .utf8))
                .flatMap { TranscriptionLanguage(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                ?? defaultLanguage
            NSLog("MT: recover — \(name) language=\(recoveredLanguage.rawValue)")
            let job = ProcessingJob(
                id: UUID(),
                title: Self.recoveredTitle(base: base),
                input: .liveStems(voiceURL: voice, systemURL: system,
                                  duration: Self.wavDurationSeconds(voice)),
                language: recoveredLanguage,
                meeting: nil,
                sourceKind: .live,
                importedName: nil,
                replacingDocumentID: nil,
                modelOverride: nil,
                stage: .queued,
                createdAt: Date()
            )
            enqueueJob(job)
        }
    }

    /// Approximate seconds from a 16 kHz mono 16-bit PCM WAV (≈32000 B/s).
    private static func wavDurationSeconds(_ url: URL) -> TimeInterval {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? 0
        return max(0, Double(size - 44) / 32_000.0)
    }

    private static func recoveredTitle(base: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd_HHmmss"
        guard let date = parser.date(from: base) else { return "Recording — \(base)" }
        let out = DateFormatter()
        out.dateFormat = "d MMM HH:mm"
        return "Recording — \(out.string(from: date))"
    }

    /// Process-level services that must run regardless of whether the main
    /// window is visible: browser meeting detection, the "record now"
    /// notification observer, and resuming calendar polling when access was
    /// already granted. Idempotent. Does NOT request calendar access — that
    /// needs an active window (see `bootstrap`).
    func startBackgroundServices() {
        guard !didStartServices else { NSLog("MT: startBackgroundServices skipped (already ran)"); return }
        didStartServices = true
        NSLog("MT: startBackgroundServices() running")
        startMeetingDetection()
        observeStartRecordingNotifications()
        CalendarMonitor.shared.resumeIfAuthorized()
        // Recover interrupted recordings at launch — a menu-bar app may run
        // windowless, so this can't wait for the main window's bootstrap.
        Task { @MainActor in
            await loadTranscripts()
            recoverOrphanedRecordings()
        }
    }

    func loadTranscripts() async {
        do {
            let loaded = try TranscriptStore.shared.loadAll()
            self.transcripts = loaded.sorted { $0.date > $1.date }
        } catch {
            self.lastError = "Could not load transcripts: \(error.localizedDescription)"
        }
    }

    // MARK: – Meeting detection
    private func startMeetingDetection() {
        let det = MeetingDetector()
        det.onMeetingDetected = { [weak self] meeting in
            Task { @MainActor in
                guard let self else { return }
                if self.dismissedMeetingURLs.contains(meeting.url) { return }
                if self.recordingState.isBusy { return }
                self.detectedMeeting = meeting
                // OS-level reminder so it surfaces even when the app is in the
                // background / menu bar, not just the in-app sheet.
                NotificationManager.shared.notifyMeetingStarting(
                    title: "🎙 Виявлено зустріч",
                    body: "«\(meeting.title)» — натисни «Почати запис»",
                    meetingURL: meeting.url
                )
            }
        }
        det.start()
        self.detector = det
    }

    /// Listens for the "Record now" action fired from a notification (calendar
    /// reminder or browser detection) and starts recording in the default
    /// language.
    private func observeStartRecordingNotifications() {
        NotificationCenter.default.addObserver(
            forName: NotificationManager.startRecordingNote,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let url = note.userInfo?["url"] as? String
            let attendees = note.userInfo?["attendees"] as? [String] ?? []
            Task { @MainActor in
                guard let self else { return }
                if self.recordingState.isBusy { return }
                let meeting = url.map {
                    DetectedMeeting(title: "Calendar meeting", platform: "Calendar",
                                    url: $0, detectedAt: Date(), attendees: attendees)
                }
                await self.startRecording(language: self.defaultLanguage, meeting: meeting)
            }
        }
    }

    func dismissDetectedMeeting() {
        if let url = detectedMeeting?.url {
            dismissedMeetingURLs.insert(url)
        }
        detectedMeeting = nil
    }

    // MARK: – Recording lifecycle
    func startRecording(language: TranscriptionLanguage, meeting: DetectedMeeting?) async {
        guard case .idle = recordingState else { return }
        // Manual recordings carry no meeting — if a calendar event is happening
        // right now, attach it so we still get attendee names for the speakers.
        let meeting = meeting ?? CalendarMonitor.shared.currentMeeting()
        recordingState = .preparing
        currentMicRMS = 0
        currentSystemRMS = 0
        let coord = RecordingCoordinator()
        self.recorder = coord
        let liveFeeds = startLiveTranslationIfEnabled()
        do {
            try await coord.start(
                captureSystemAudio: captureSystemAudio,
                language: language,
                onMicLevel: { [weak self] rms in
                    Task { @MainActor in self?.currentMicRMS = rms }
                },
                onSystemLevel: { [weak self] rms in
                    Task { @MainActor in self?.currentSystemRMS = rms }
                },
                onInputDeviceChange: { [weak self] in
                    Task { @MainActor in
                        self?.currentInputDeviceName = AudioRecorder.currentInputDeviceName()
                    }
                },
                onMicSamples: liveFeeds.mic,
                onSystemSamples: liveFeeds.system
            )
            currentInputDeviceName = AudioRecorder.currentInputDeviceName()
            let start = Date()
            recordingState = .recording(startedAt: start, meeting: meeting, language: language)
            // Warm the Whisper model in the background now, while the call is
            // still running. The shared engine keeps it loaded, so by the time
            // the user stops, transcription starts instantly instead of paying
            // a multi-minute cold load + ANE compile after every recording.
            let warmModel = selectedModel
            Task.detached(priority: .utility) { await WhisperEngine.shared.prewarm(model: warmModel) }
            elapsedSeconds = 0
            startElapsedTimer(from: start)
            if let url = meeting?.url { dismissedMeetingURLs.insert(url) }
            detectedMeeting = nil
        } catch {
            stopLiveTranslation()
            recordingState = .idle
            lastError = "Could not start recording: \(error.localizedDescription)"
        }
    }

    /// Spins up a LiveTranslator when translation is enabled and a key is set.
    /// Returns the per-source sample feeds to hand to the RecordingCoordinator:
    /// the call audio (system) is translated when captured, otherwise the mic.
    private func startLiveTranslationIfEnabled() -> (mic: (([Float]) -> Void)?, system: (([Float]) -> Void)?) {
        liveCaptions = []
        liveInProgress = ""
        guard liveTranslateEnabled else {
            translator = nil
            liveStatus = .closed(nil)
            return (nil, nil)
        }
        // Show the caption bar as soon as translation is on, so there's always
        // visible feedback — even before any audio, or if the key is missing.
        CaptionsOverlayController.shared.show(appState: self)
        guard hasGeminiKey else {
            translator = nil
            liveStatus = .closed("Set a Gemini API key in Settings")
            return (nil, nil)
        }
        let t = LiveTranslator(apiKey: geminiAPIKey)
        t.onUpdate = { [weak self] captions, inProgress in
            Task { @MainActor in
                self?.liveCaptions = captions
                self?.liveInProgress = inProgress
            }
        }
        t.onStatus = { [weak self] status in
            Task { @MainActor in self?.liveStatus = status }
        }
        liveStatus = .connecting
        t.start(targetCode: liveTargetLanguage.code)
        translator = t
        let feed: ([Float]) -> Void = { [weak t] samples in t?.feed(samples) }
        return captureSystemAudio ? (nil, feed) : (feed, nil)
    }

    private func stopLiveTranslation() {
        CaptionsOverlayController.shared.hide()
        translator?.finish()
        translator = nil
    }

    /// Lines from the current live-translation session for an instant transcript:
    /// the recognized original if present, otherwise the translated captions.
    private func capturedLiveLines() -> [String] {
        guard let translator else { return [] }
        let original = translator.originalLines()
        return original.isEmpty ? translator.translatedLines() : original
    }

    /// Build a transcript from live-translation text. Its `id` is the recording
    /// stem base so the follow-up Whisper job (replacingDocumentID == base) can
    /// overlay diarized segments in place.
    private static func makeInstantDoc(base: String,
                                       title: String,
                                       date: Date,
                                       duration: TimeInterval,
                                       language: TranscriptionLanguage,
                                       meeting: DetectedMeeting?,
                                       lines: [String]) -> TranscriptDocument {
        let segments = lines.enumerated().map { index, text in
            TranscriptSegment(start: Double(index), end: Double(index) + 1,
                              speakerId: 0, text: text)
        }
        return TranscriptDocument(
            id: base,
            title: title,
            date: date,
            duration: duration,
            language: language,
            modelShortName: "Gemini Live",
            sourceURL: meeting?.url,
            sourceKind: .live,
            speakers: [SpeakerLabel(id: 0, name: "Speaker")],
            segments: segments,
            audioFileName: "\(base).voice.wav",
            attendees: nil,
            summary: nil,
            summaryModelShortName: nil,
            summaryGeneratedAt: nil,
            summaryModelOverride: nil
        )
    }

    func setMicMuted(_ muted: Bool) {
        isMicMuted = muted
        recorder?.setMicMuted(muted)
    }

    func stopRecording() async {
        guard case .recording(let startedAt, let meeting, let language) = recordingState else { return }
        recordingState = .stopping
        // Capture the live-translation text BEFORE finishing the session — it's
        // used for an instant transcript so the user doesn't wait for Whisper.
        let liveLines = capturedLiveLines()
        stopLiveTranslation()
        stopElapsedTimer()
        currentInputDeviceName = nil
        guard let recorder = recorder else { recordingState = .idle; return }
        defer { self.recorder = nil }
        do {
            let stems = try await recorder.stop()
            let duration = Date().timeIntervalSince(startedAt)

            // Perf: if live translation produced text, save it as an instant
            // transcript now (no waiting for Whisper) and have the Whisper job
            // replace it in the background once it has diarization + timestamps.
            var replacingID: String? = nil
            if !liveLines.isEmpty {
                let base = String(stems.voiceURL.lastPathComponent.dropLast(".voice.wav".count))
                let instant = Self.makeInstantDoc(
                    base: base,
                    title: jobTitle(for: meeting, startedAt: startedAt),
                    date: startedAt,
                    duration: duration,
                    language: language,
                    meeting: meeting,
                    lines: liveLines)
                do {
                    try TranscriptStore.shared.save(instant, audioSource: nil)
                    await loadTranscripts()
                    selectedTranscriptID = instant.id
                    replacingID = instant.id
                } catch {
                    NSLog("Instant transcript save failed: \(error)")
                }
            }

            let job = ProcessingJob(
                id: UUID(),
                title: jobTitle(for: meeting, startedAt: startedAt),
                input: .liveStems(voiceURL: stems.voiceURL,
                                  systemURL: stems.systemURL,
                                  duration: duration),
                language: language,
                meeting: meeting,
                sourceKind: .live,
                importedName: nil,
                replacingDocumentID: replacingID,
                modelOverride: nil,
                stage: .queued,
                createdAt: Date()
            )
            enqueueJob(job)
            recordingState = .idle
        } catch {
            recordingState = .idle
            lastError = "Stop failed: \(error.localizedDescription)"
        }
    }

    private func startElapsedTimer(from start: Date) {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.recordingState.isRecording {
                    self.elapsedSeconds = Int(Date().timeIntervalSince(start))
                }
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    // MARK: – Import path
    /// Enqueues an import job. Unlike recording, imports don't touch
    /// `recordingState` — they can be added to the queue while a recording is
    /// in progress or other jobs are processing.
    func importFile(url sourceURL: URL, language: TranscriptionLanguage) async {
        let job = ProcessingJob(
            id: UUID(),
            title: sourceURL.lastPathComponent,
            input: .importFile(sourceURL: sourceURL),
            language: language,
            meeting: nil,
            sourceKind: .imported,
            importedName: sourceURL.lastPathComponent,
            replacingDocumentID: nil,
            modelOverride: nil,
            stage: .queued,
            createdAt: Date()
        )
        enqueueJob(job)
    }

    // MARK: – Re-transcribe an existing document

    /// Enqueue a re-transcription of an existing document's stems with the
    /// given model. Preserves the title, clears the stale summary, and runs
    /// diarization fresh (speaker renames will be lost). No-op if the document
    /// has no voice stem on disk, or if a re-transcription is already in
    /// flight for this document.
    func retranscribe(documentID: String, with model: WhisperModel) {
        guard let doc = transcripts.first(where: { $0.id == documentID }) else { return }
        guard let voiceURL = TranscriptStore.shared.audioURL(for: doc) else {
            lastError = "Can't re-transcribe: audio file is missing."
            return
        }
        // Already queued or running? Leave it alone.
        if processingJobs.contains(where: { $0.replacingDocumentID == documentID }) { return }

        let systemURL = TranscriptStore.shared.systemAudioURL(for: doc)
        let job = ProcessingJob(
            id: UUID(),
            title: "\(doc.title) · \(model.shortName)",
            input: .liveStems(voiceURL: voiceURL,
                              systemURL: systemURL,
                              duration: doc.duration),
            language: doc.language,
            meeting: nil,
            sourceKind: doc.sourceKind,
            importedName: doc.sourceKind == .imported ? doc.sourceURL : nil,
            replacingDocumentID: documentID,
            modelOverride: model,
            stage: .queued,
            createdAt: Date()
        )
        enqueueJob(job)
    }

    // MARK: – Processing queue

    private func enqueueJob(_ job: ProcessingJob) {
        processingJobs.append(job)
        startProcessingDrainIfNeeded()
    }

    private func startProcessingDrainIfNeeded() {
        guard processingTask == nil else { return }
        processingTask = Task { @MainActor [weak self] in
            while let self, let job = self.nextQueuedJob() {
                await self.processJob(job)
            }
            self?.processingTask = nil
        }
    }

    private func nextQueuedJob() -> ProcessingJob? {
        processingJobs.first(where: { $0.stage.isQueued })
    }

    private func updateJobStage(_ id: UUID, _ stage: ProcessingJob.Stage) {
        guard let idx = processingJobs.firstIndex(where: { $0.id == id }) else { return }
        processingJobs[idx].stage = stage
    }

    /// Run one job through decode (if needed) + WhisperKit + diarization.
    /// Runs on the main actor; the heavy work is performed inside
    /// `TranscriptionPipeline`, which uses its own actor-isolated engines, so
    /// the UI stays responsive.
    private func processJob(_ job: ProcessingJob) async {
        NSLog("MT: processJob START \(job.title)")
        let jobID = job.id
        let language = job.language
        let meeting = job.meeting
        let sourceKind = job.sourceKind
        let importedName = job.importedName

        let voiceURL: URL
        let systemURL: URL?
        let duration: TimeInterval
        let progressOffset: Double

        do {
            switch job.input {
            case .liveStems(let v, let s, let d):
                voiceURL = v
                systemURL = s
                duration = d
                progressOffset = 0.0
            case .importFile(let src):
                updateJobStage(jobID, .running(progress: 0.0, stage: "Decoding audio"))
                let wavURL = try await MediaImporter.convertToMono16kWav(source: src) { [weak self] fraction in
                    Task { @MainActor in
                        self?.updateJobStage(jobID, .running(progress: fraction * 0.2,
                                                             stage: "Decoding audio"))
                    }
                }
                let dur = try await MediaImporter.duration(of: src)
                voiceURL = wavURL
                systemURL = nil
                duration = dur
                progressOffset = 0.2
            }

            updateJobStage(jobID, .running(progress: progressOffset + 0.05, stage: "Loading Whisper"))
            let pipeline = TranscriptionPipeline()
            let progress: (Double, String) -> Void = { [weak self] p, s in
                Task { @MainActor in
                    self?.updateJobStage(jobID, .running(
                        progress: progressOffset + (1.0 - progressOffset) * p,
                        stage: s))
                }
            }
            let prime = languagePrimes[language.rawValue] ?? ""
            let model = job.modelOverride ?? selectedModel
            var freshDoc = try await pipeline.run(voiceURL: voiceURL,
                                                  systemURL: systemURL,
                                                  duration: duration,
                                                  language: language,
                                                  model: model,
                                                  engine: transcriptionEnginePreference.engine(for: language),
                                                  meeting: meeting,
                                                  sourceKind: sourceKind,
                                                  importedFileName: importedName,
                                                  initialPrompt: prime.isEmpty ? nil : prime,
                                                  wordReplacements: wordReplacements,
                                                  progress: progress)

            // Auto-label placeholder "Remote N" speakers with remembered voices.
            SpeakerMatcher.autoLabel(&freshDoc, enrolled: enrolledSpeakers)

            // For re-transcription, preserve the existing document's identity
            // (id, title, date, audio filename, source) and overlay the fresh
            // transcription output (new model, segments, speakers, duration).
            // The stale summary is dropped — it was built against the old
            // segments and no longer matches.
            let docToSave: TranscriptDocument
            if let replaceID = job.replacingDocumentID,
               let existing = transcripts.first(where: { $0.id == replaceID }) {
                docToSave = Self.applyRetranscription(to: existing, from: freshDoc)
            } else {
                docToSave = freshDoc
            }
            try TranscriptStore.shared.save(docToSave, audioSource: voiceURL)
            await loadTranscripts()
            selectedTranscriptID = docToSave.id
            processingJobs.removeAll { $0.id == jobID }
        } catch {
            NSLog("MT: processJob FAILED \(job.title): \(error.localizedDescription)")
            lastError = "Transcription failed: \(error.localizedDescription)"
            // Drop the failed job from the queue so the drain continues.
            processingJobs.removeAll { $0.id == jobID }
        }
    }

    /// Build the document we'll save after re-transcribing `existing`. Keeps
    /// every "identity" field (id, title, date, stored audio, source) and
    /// everything the user may have edited, while adopting the fresh Whisper
    /// output (model, duration, speakers, segments). A handful of fields are
    /// `let`, so this has to be a field-by-field init rather than a mutation.
    private static func applyRetranscription(to existing: TranscriptDocument,
                                             from fresh: TranscriptDocument) -> TranscriptDocument {
        TranscriptDocument(
            id: existing.id,
            title: existing.title,
            date: existing.date,
            duration: fresh.duration,
            language: fresh.language,
            modelShortName: fresh.modelShortName,
            sourceURL: existing.sourceURL,
            sourceKind: existing.sourceKind,
            speakers: fresh.speakers,
            segments: fresh.segments,
            audioFileName: existing.audioFileName,
            summary: nil,
            summaryModelShortName: nil,
            summaryGeneratedAt: nil,
            speakerEmbeddings: fresh.speakerEmbeddings
        )
    }

    private func jobTitle(for meeting: DetectedMeeting?, startedAt: Date) -> String {
        if let meeting { return meeting.title }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return "Recording — \(fmt.string(from: startedAt))"
    }

    // MARK: – Transcript deletion
    /// Remove the transcript from the library and delete all on-disk files
    /// (markdown, JSON, and paired WAV stems). If the deleted transcript was
    /// selected, clears the selection so the detail view returns to Record.
    func deleteTranscript(id: String) {
        guard let idx = transcripts.firstIndex(where: { $0.id == id }) else { return }
        let doc = transcripts[idx]
        TranscriptStore.shared.delete(doc)
        transcripts.remove(at: idx)
        if selectedTranscriptID == id {
            selectedTranscriptID = nil
        }
    }

    // MARK: – Transcript edits
    func renameTranscript(id: String, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = transcripts.firstIndex(where: { $0.id == id }) else { return }
        transcripts[idx].title = trimmed
        try? TranscriptStore.shared.save(transcripts[idx], audioSource: nil)
    }

    func renameSpeaker(transcriptID: String, speakerID: Int, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let tIdx = transcripts.firstIndex(where: { $0.id == transcriptID }),
              let sIdx = transcripts[tIdx].speakers.firstIndex(where: { $0.id == speakerID }) else { return }
        transcripts[tIdx].speakers[sIdx].name = trimmed
        try? TranscriptStore.shared.save(transcripts[tIdx], audioSource: nil)
    }

    // MARK: – Voice enrollment actions

    /// Whether a speaker in the given transcript has a stored voice embedding
    /// (i.e. can be enrolled as a remembered profile).
    func canEnrollSpeaker(transcriptID: String, speakerID: Int) -> Bool {
        guard let doc = transcripts.first(where: { $0.id == transcriptID }) else { return false }
        return doc.speakerEmbeddings?[String(speakerID)]?.isEmpty == false
    }

    /// Remember a speaker's voice as a named profile so future meetings auto-label
    /// the same voice. Reuses the averaged embedding stored on the transcript and
    /// also renames the speaker here. A same-name profile is replaced.
    func enrollSpeaker(transcriptID: String, speakerID: Int, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let doc = transcripts.first(where: { $0.id == transcriptID }),
              let emb = doc.speakerEmbeddings?[String(speakerID)], !emb.isEmpty else { return }
        let profile = EnrolledSpeaker(name: trimmed, embedding: emb)
        if let i = enrolledSpeakers.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            enrolledSpeakers[i] = profile
        } else {
            enrolledSpeakers.append(profile)
        }
        EnrolledSpeakersStore.save(enrolledSpeakers)
        renameSpeaker(transcriptID: transcriptID, speakerID: speakerID, to: trimmed)
    }

    func removeEnrolledSpeaker(id: UUID) {
        enrolledSpeakers.removeAll { $0.id == id }
        EnrolledSpeakersStore.save(enrolledSpeakers)
    }
}
