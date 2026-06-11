import Foundation

/// Per-language prompt templates. Two passes per summarization (summary then
/// title) keep streaming UX simple and robust — no JSON parsing, each block
/// lands in its own UI card as it generates.
enum SummaryPrompts {

    // MARK: - System instructions (user-editable via Settings).

    static let defaultSystemEnglish =
        "You are a meeting-notes assistant. Be concise, factual, and faithful to the transcript. " +
        "Use the same language as the transcript. Preserve names, technical terms, and numbers exactly as they appear."

    /// Prompt asking the LLM to map placeholder speaker labels ("Remote",
    /// "Remote 1", …) to real names mentioned in the conversation. Strict
    /// output format so `parseInferredNames` can read it back deterministically.
    static func identifyInstruction(for language: TranscriptionLanguage,
                                    labels: [String],
                                    candidates: [String] = []) -> String {
        let intro: String
        let unknown: String
        switch language {
        case .english:
            intro = "Below is a meeting transcript with placeholder speaker labels. For each label, infer the speaker's real name only if the conversation clearly indicates it (e.g. they are addressed by name). Reply with one line per label in the exact format:"
            unknown = "If no name is clearly indicated for a label, write 'unknown'. Do not invent names. Do not add any other commentary."
        case .ukrainian:
            intro = "Нижче наведено транскрипт зустрічі з тимчасовими позначками спікерів. Для кожної позначки визнач справжнє ім'я спікера, лише якщо розмова це чітко вказує (наприклад, до нього звертаються на ім'я). Відповідай рівно одним рядком на позначку у форматі:"
            unknown = "Якщо ім'я для позначки чітко не вказане, напиши 'unknown'. Не вигадуй імен. Не додавай жодних коментарів."
        }
        let format = "<label>: <name or unknown>"
        let bullets = labels.map { "- \($0)" }.joined(separator: "\n")

        var candidateBlock = ""
        if !candidates.isEmpty {
            let list = candidates.joined(separator: ", ")
            switch language {
            case .english:
                candidateBlock = "\n\nThe meeting's known attendees are: \(list). The speakers are most likely among these people — prefer matching a label to one of these names when the conversation supports it, but still write 'unknown' if you cannot tell which one."
            case .ukrainian:
                candidateBlock = "\n\nВідомі учасники зустрічі: \(list). Спікери найімовірніше серед цих людей — за можливості співстав позначку саме з цими іменами, коли розмова це підтверджує; якщо однозначно визначити не вдається, все одно пиши 'unknown'."
            }
        }

        return "\(intro)\n\(format)\n\(unknown)\(candidateBlock)\n\nLabels to identify:\n\(bullets)"
    }

    /// Parses lines like "Remote 1: Romek" / "Remote 2: unknown" produced by
    /// the identification pass. Tolerates leading bullets, surrounding
    /// whitespace, and extra commentary lines (skipped).
    static func parseInferredNames(_ raw: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in raw.split(whereSeparator: \.isNewline) {
            let trimmed = String(line)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-*•"))
                .trimmingCharacters(in: .whitespaces)
            guard let colonIdx = trimmed.firstIndex(of: ":") else { continue }
            let label = String(trimmed[..<colonIdx])
                .trimmingCharacters(in: .whitespaces)
            let name = String(trimmed[trimmed.index(after: colonIdx)...])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !label.isEmpty, !name.isEmpty else { continue }
            out[label] = name
        }
        return out
    }

    /// Formats enabled glossary entries into a system-prompt appendix. Returns
    /// nil when nothing is enabled / both fields blank, so the caller can skip
    /// the appendix entirely. Header language matches the transcript.
    static func glossaryBlock(for language: TranscriptionLanguage,
                              terms: [GlossaryTerm]) -> String? {
        let enabled = terms.filter {
            $0.isEnabled
                && !$0.term.trimmingCharacters(in: .whitespaces).isEmpty
                && !$0.definition.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard !enabled.isEmpty else { return nil }
        let header = "Glossary of domain terms (use these definitions to interpret the transcript):"
        let lines = enabled
            .map { "- \($0.term): \($0.definition)" }
            .joined(separator: "\n")
        return header + "\n" + lines
    }

    // MARK: - Per-call user prompts.

    static func summaryInstruction(for language: TranscriptionLanguage) -> String {
        switch language {
        case .english:
            return "Write a concise summary of the meeting transcript below in 3–6 sentences. No bullets, no headers — one flowing paragraph."
        case .ukrainian:
            return "Напиши стислий підсумок транскрипту зустрічі нижче у 3–6 реченнях. Без списків, без заголовків — один суцільний абзац."
        }
    }

    static func titleInstruction(for language: TranscriptionLanguage) -> String {
        switch language {
        case .english:
            return """
                Generate a concise meeting title from the transcript below.

                Rules:
                • 3–8 words, Title Case.
                • No quotes, no trailing punctuation, no preamble.
                • Prefer concrete nouns from the meeting (project, topic, decision) over generic words like "Discussion" or "Meeting".
                • Output the title on a single line. Nothing else.
                """
        case .ukrainian:
            return """
                Згенеруй стислий заголовок зустрічі на основі транскрипту нижче.

                Правила:
                • 3–8 слів, з великої літери там, де це природно.
                • Без лапок, без крапки в кінці, без вступу.
                • Надавай перевагу конкретним іменникам зі зустрічі (проєкт, тема, рішення) замість загальних слів на кшталт «Обговорення» чи «Зустріч».
                • Виведи заголовок одним рядком. Нічого більше.
                """
        }
    }

    /// Clean up a model-generated title: strip quotes, markdown, trailing
    /// punctuation, and collapse to the first line (models sometimes leak
    /// explanations below the answer).
    static func sanitizeTitle(_ raw: String) -> String {
        var t = stripThinking(raw)
        if let nl = t.firstIndex(where: \.isNewline) {
            t = String(t[..<nl])
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip wrapping quotes / backticks / asterisks.
        while let first = t.first, "\"'`*".contains(first) { t.removeFirst() }
        while let last = t.last, "\"'`*".contains(last) { t.removeLast() }
        // Strip leading markdown headers.
        while t.hasPrefix("#") { t.removeFirst() }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop trailing period.
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }

    /// Strip any `<think>…</think>` blocks the model might still emit.
    /// Safe to call on streaming partials: if the opening tag was seen but the
    /// closing one hasn't arrived yet, everything from `<think>` onward is
    /// hidden until the matching close tag lands (or stream ends).
    static func stripThinking(_ raw: String) -> String {
        var out = raw
        // Remove complete <think>...</think> blocks first.
        while let open = out.range(of: "<think>"),
              let close = out.range(of: "</think>", range: open.upperBound..<out.endIndex) {
            out.removeSubrange(open.lowerBound..<close.upperBound)
        }
        // For a streaming partial: if <think> opened without a close yet,
        // hide everything from that point so the UI doesn't show reasoning.
        if let open = out.range(of: "<think>") {
            out.removeSubrange(open.lowerBound..<out.endIndex)
        }
        return out
    }
}
