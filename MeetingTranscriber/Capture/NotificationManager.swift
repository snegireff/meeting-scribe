import Foundation
import UserNotifications
import AppKit

/// Thin wrapper over `UNUserNotificationCenter` that posts OS-level reminders
/// when a meeting is about to start (from the calendar) or has been detected
/// in a browser. The "Record now" action re-broadcasts an in-app
/// `NotificationCenter` note that `AppState` listens for, so a tap can kick off
/// recording even when the app is in the background / menu bar.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationManager()

    /// In-app note posted when the user taps a reminder (or its Record action).
    /// `userInfo["url"]` carries the meeting URL when known.
    static let startRecordingNote = Notification.Name("MTStartRecordingRequested")

    private let center = UNUserNotificationCenter.current()
    private let categoryID = "MEETING_START"
    private let recordActionID = "RECORD_NOW"

    /// Call once at launch: register the category + action and request auth.
    func configure() {
        center.delegate = self
        let record = UNNotificationAction(
            identifier: recordActionID,
            title: "Почати запис",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: categoryID,
            actions: [record],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                NSLog("[NotificationManager] auth error: \(error.localizedDescription)")
            } else {
                NSLog("[NotificationManager] notifications granted=\(granted)")
            }
        }
    }

    /// Fire an immediate banner reminding the user a meeting is starting.
    func notifyMeetingStarting(title: String, body: String, meetingURL: String?, attendees: [String] = []) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = categoryID
        var info: [String: Any] = [:]
        if let meetingURL { info["url"] = meetingURL }
        if !attendees.isEmpty { info["attendees"] = attendees }
        if !info.isEmpty { content.userInfo = info }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // deliver now
        )
        center.add(request) { error in
            if let error {
                NSLog("[NotificationManager] add error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show the banner even when the app is frontmost.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Tapping the banner or its "Record now" action starts recording.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let url = info["url"] as? String
        let attendees = info["attendees"] as? [String] ?? []
        let isRecordTap = response.actionIdentifier == recordActionID
            || response.actionIdentifier == UNNotificationDefaultActionIdentifier

        if isRecordTap {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                var note: [String: Any] = [:]
                if let url { note["url"] = url }
                if !attendees.isEmpty { note["attendees"] = attendees }
                NotificationCenter.default.post(
                    name: Self.startRecordingNote,
                    object: nil,
                    userInfo: note.isEmpty ? nil : note
                )
            }
        }
        completionHandler()
    }
}
