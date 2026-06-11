import Foundation
import EventKit
import AppKit

/// Watches the user's calendar and fires an OS notification when a meeting
/// that carries a video-conference link (Meet / Zoom / Teams / Whereby / …) is
/// about to start. This complements `MeetingDetector` (which only sees
/// browser tabs) so reminders also work for native Teams/Zoom apps and for
/// meetings you haven't opened yet.
final class CalendarMonitor {

    static let shared = CalendarMonitor()

    private let store = EKEventStore()
    private var timer: Timer?
    private var notifiedEventIDs = Set<String>()
    private var didStart = false

    /// Hosts that mark an event as a video meeting worth recording.
    private let meetingHosts = [
        "meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com",
        "whereby.com", "meet.jit.si", "gather.town", "app.gather.town",
        "around.co", "webex.com", "meet.around.co"
    ]

    /// Begin polling only if calendar access was already granted. Safe to call
    /// at process launch (no window / not frontmost) — it never shows a prompt,
    /// so a windowless relaunch resumes reminders without a doomed TCC request.
    func resumeIfAuthorized() {
        guard !didStart else { return }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        didStart = true
        beginPolling()
    }

    /// Request calendar access (showing the one-time TCC prompt when needed),
    /// then poll on a timer. Must be called while the app is active / frontmost
    /// — i.e. from the main window's task — or macOS silently refuses to present
    /// the prompt and returns notDetermined.
    func start() {
        guard !didStart else { return }
        didStart = true

        // Activate the app so TCC has a foreground session to attach the prompt
        // to (LaunchServices may have opened us behind another app).
        NSApplication.shared.activate(ignoringOtherApps: true)

        let onGrant: (Bool, Error?) -> Void = { [weak self] granted, error in
            if let error {
                NSLog("[CalendarMonitor] calendar access error: \(error.localizedDescription)")
            }
            guard granted else { return }
            DispatchQueue.main.async { self?.beginPolling() }
        }

        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents(completion: onGrant)
        } else {
            store.requestAccess(to: .event, completion: onGrant)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func beginPolling() {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll()
    }

    private func poll() {
        let now = Date()
        let calendars = store.calendars(for: .event)
        guard !calendars.isEmpty else { return }

        // Look at events from 1 min ago to 15 min ahead, fire ~90s before start.
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-60),
            end: now.addingTimeInterval(15 * 60),
            calendars: calendars
        )
        let fireWindowEnd = now.addingTimeInterval(90)

        for event in store.events(matching: predicate) {
            guard let id = event.eventIdentifier, !notifiedEventIDs.contains(id) else { continue }
            let start: Date = event.startDate
            // Only notify around the start moment: [now-60s, now+90s].
            guard start >= now.addingTimeInterval(-60), start <= fireWindowEnd else { continue }
            guard let link = meetingLink(in: event) else { continue }

            notifiedEventIDs.insert(id)
            let title = event.title ?? "Зустріч"
            NotificationManager.shared.notifyMeetingStarting(
                title: "🎙 Кол починається",
                body: "«\(title)» — натисни «Почати запис»",
                meetingURL: link,
                attendees: attendeeNames(of: event)
            )
        }

        // Keep the dedupe set from growing unbounded across a long session.
        if notifiedEventIDs.count > 500 { notifiedEventIDs.removeAll() }
    }

    /// The video meeting happening right now (started in the last 30 min and
    /// not yet ended), with its attendees — used to tag a manually-started
    /// recording with candidate speaker names. Returns nil without calendar
    /// access or when no live video meeting is found.
    func currentMeeting() -> DetectedMeeting? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let now = Date()
        let calendars = store.calendars(for: .event)
        guard !calendars.isEmpty else { return nil }
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-30 * 60),
            end: now.addingTimeInterval(5 * 60),
            calendars: calendars
        )
        for event in store.events(matching: predicate) {
            let start: Date = event.startDate
            let end: Date = event.endDate
            guard start <= now.addingTimeInterval(5 * 60), end >= now else { continue }
            guard let link = meetingLink(in: event) else { continue }
            return DetectedMeeting(
                title: event.title ?? "Зустріч",
                platform: "Calendar",
                url: link,
                detectedAt: now,
                attendees: attendeeNames(of: event)
            )
        }
        return nil
    }

    /// Organizer + attendee display names (deduped, organizer first).
    private func attendeeNames(of event: EKEvent) -> [String] {
        var names: [String] = []
        if let organizer = event.organizer, let n = participantName(organizer) {
            names.append(n)
        }
        for participant in event.attendees ?? [] {
            guard let n = participantName(participant), !names.contains(n) else { continue }
            names.append(n)
        }
        return names
    }

    /// A participant's display name, falling back to the email local-part from
    /// its `mailto:` URL when no name is provided.
    private func participantName(_ participant: EKParticipant) -> String? {
        if let name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty, name.lowercased() != "unknown" {
            return name
        }
        let s = participant.url.absoluteString
        if let range = s.range(of: "mailto:", options: [.caseInsensitive]) {
            let email = String(s[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            return email.isEmpty ? nil : email
        }
        return nil
    }

    /// Returns the first video-meeting URL found in the event's url/location/notes.
    private func meetingLink(in event: EKEvent) -> String? {
        let fields = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }
        for field in fields {
            let lower = field.lowercased()
            guard meetingHosts.contains(where: { lower.contains($0) }) else { continue }
            if let extracted = firstURL(in: field, matchingHosts: meetingHosts) {
                return extracted
            }
            return field
        }
        return nil
    }

    /// Scan a blob of text for the first http(s) token whose host is a known meeting host.
    private func firstURL(in text: String, matchingHosts hosts: [String]) -> String? {
        let tokens = text.split { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "<" || $0 == ">" || $0 == "\"" }
        for token in tokens {
            let s = String(token)
            let lower = s.lowercased()
            guard lower.hasPrefix("http"), hosts.contains(where: { lower.contains($0) }) else { continue }
            return s
        }
        return nil
    }
}
