import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static let detectedCategory = "MEETING_DETECTED"
    static let recordAction = "RECORD"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        guard Notifier.available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let record = UNNotificationAction(identifier: Self.recordAction, title: "Record", options: [.foreground])
        let category = UNNotificationCategory(identifier: Self.detectedCategory, actions: [record], intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Finder "Open With", dropping files on the Dock icon, `open -a "Meeting Recorder" file.m4a`.
    func application(_ application: NSApplication, open urls: [URL]) {
        let audio = urls.filter { AudioImporter.isAudioFile($0) }
        guard !audio.isEmpty else { return }
        Task { @MainActor in
            AppState.shared.importAudio(urls: audio, into: nil, move: false)
            AppState.shared.openMainWindow()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let app = AppState.shared
        if app.recorder.isRecording { app.recorder.stop() }
        return .terminateNow
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.actionIdentifier
        if id == Self.recordAction || id == UNNotificationDefaultActionIdentifier {
            Task { @MainActor in AppState.shared.recordFromDetection() }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

enum Notifier {
    /// UNUserNotificationCenter crashes when the process isn't a real .app bundle.
    static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    static func meetingDetected(app: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(app) is using the microphone"
        content.body = "Looks like a meeting started. Record it?"
        content.categoryIdentifier = AppDelegate.detectedCategory
        content.sound = .default
        let request = UNNotificationRequest(identifier: "meeting-detected", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func clearDetected() {
        guard available else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["meeting-detected"])
    }
}
