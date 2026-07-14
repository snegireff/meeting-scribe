import Foundation
import AppKit

/// Sends a finished meeting summary to external destinations. Everything is
/// best-effort and surfaces a readable error; no destination is configured by
/// default, so the app stays fully local unless the user opts in.
enum ExportCoordinator {

    enum ExportError: LocalizedError {
        case noSummary
        case missingConfig(String)
        case telegram(String)
        case fileWrite(String)

        var errorDescription: String? {
            switch self {
            case .noSummary:            return "This transcript has no summary yet — run one first."
            case .missingConfig(let s): return s
            case .telegram(let s):      return "Telegram: \(s)"
            case .fileWrite(let s):     return "Obsidian: \(s)"
            }
        }
    }

    /// Markdown body shared by all destinations. Prefers the summary; falls back
    /// to the full transcript markdown when no summary exists.
    private static func body(for doc: TranscriptDocument) -> String {
        TranscriptFormatter.renderSummaryMarkdown(doc) ?? TranscriptFormatter.renderMarkdown(doc)
    }

    // MARK: - Telegram

    /// POST the summary to a chat via the Bot API. Long summaries are split into
    /// ≤4000-char messages (Telegram caps at 4096). Sent as plain text to dodge
    /// Markdown-entity parse errors.
    static func sendToTelegram(_ doc: TranscriptDocument, token: String, chatID: String) async throws {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let chatID = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ExportError.missingConfig("Add a Telegram bot token in Settings.") }
        guard !chatID.isEmpty else { throw ExportError.missingConfig("Add a Telegram chat ID in Settings.") }
        guard doc.summary?.isEmpty == false else { throw ExportError.noSummary }

        let url = URL(string: "https://api.telegram.org/bot\(token)/sendMessage")!
        for chunk in chunked(body(for: doc), max: 4000) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "chat_id": chatID,
                "text": chunk,
                "disable_web_page_preview": true
            ])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ExportError.telegram("no response")
            }
            guard http.statusCode == 200 else {
                let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["description"] as? String
                throw ExportError.telegram(detail ?? "HTTP \(http.statusCode)")
            }
        }
    }

    // MARK: - Obsidian

    /// Write the summary as a note inside the vault under "Meeting Summaries/".
    /// Returns the written file URL. The app is not sandboxed, so it can write to
    /// a user-chosen vault path directly.
    @discardableResult
    static func writeToObsidian(_ doc: TranscriptDocument, vaultPath: String) throws -> URL {
        let path = vaultPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { throw ExportError.missingConfig("Set your Obsidian vault path in Settings.") }
        guard doc.summary?.isEmpty == false else { throw ExportError.noSummary }

        let expanded = (path as NSString).expandingTildeInPath
        let folder = URL(fileURLWithPath: expanded, isDirectory: true)
            .appendingPathComponent("Meeting Summaries", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw ExportError.fileWrite("couldn't create folder — \(error.localizedDescription)")
        }
        let datePrefix = ISO8601DateFormatter.dateOnly.string(from: doc.date)
        let fileURL = folder.appendingPathComponent("\(datePrefix) \(safeName(doc.title)).md")
        do {
            try body(for: doc).data(using: .utf8)?.write(to: fileURL)
        } catch {
            throw ExportError.fileWrite(error.localizedDescription)
        }
        return fileURL
    }

    // MARK: - Email draft

    /// Open the default mail client with a pre-filled draft (subject + summary).
    /// Recipients are left blank — we only have attendee names, not addresses —
    /// so the user fills them in. Full summary is also placed on the pasteboard
    /// as a fallback for clients that truncate long mailto bodies.
    @MainActor
    static func openEmailDraft(_ doc: TranscriptDocument) throws {
        guard doc.summary?.isEmpty == false else { throw ExportError.noSummary }
        let text = body(for: doc)

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        let subject = "Notes: \(doc.title)"
        // mailto bodies get flaky past ~1.8k chars across clients; keep it short
        // and rely on the pasteboard for the full text.
        let shortBody = text.count > 1500
            ? String(text.prefix(1500)) + "\n\n…(full summary copied to clipboard)"
            : text
        var comps = URLComponents()
        comps.scheme = "mailto"
        comps.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: shortBody)
        ]
        guard let url = comps.url else {
            throw ExportError.missingConfig("Couldn't build the email draft.")
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Helpers

    private static func chunked(_ s: String, max: Int) -> [String] {
        guard s.count > max else { return [s] }
        var out: [String] = []
        var current = ""
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            if current.count + line.count + 1 > max, !current.isEmpty {
                out.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
            // A single line longer than max — hard-split it.
            while current.count > max {
                out.append(String(current.prefix(max)))
                current = String(current.dropFirst(max))
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private static func safeName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = trimmed.components(separatedBy: illegal).joined(separator: "-")
        return cleaned.isEmpty ? "Meeting" : cleaned
    }
}

private extension ISO8601DateFormatter {
    static let dateOnly: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withYear, .withMonth, .withDay, .withDashSeparatorInDate]
        return f
    }()
}
