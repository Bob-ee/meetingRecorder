import Foundation
import MeetingCore
import AppKit

/// Watches the default input device. When another app starts using the microphone
/// (the orange dot), that's almost certainly a call starting.
@MainActor
final class MeetingDetector: ObservableObject {
    @Published private(set) var micInUse = false
    var isRecordingProvider: () -> Bool = { false }
    var onDetected: ((String) -> Void)?

    private var timer: Timer?
    private var armed = true

    static let knownApps: [(bundleID: String, name: String)] = [
        ("us.zoom.xos", "Zoom"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.google.Chrome", "Google Meet (Chrome)"),
        ("com.apple.Safari", "Google Meet (Safari)"),
        ("company.thebrowser.Browser", "Google Meet (Arc)"),
        ("org.mozilla.firefox", "Google Meet (Firefox)"),
        ("com.microsoft.teams2", "Microsoft Teams"),
        ("com.microsoft.teams", "Microsoft Teams"),
        ("com.apple.FaceTime", "FaceTime"),
    ]

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
    }

    private func poll() {
        let recording = isRecordingProvider()
        let inUse = CoreAudioUtil.defaultInputIsInUse()
        micInUse = inUse && !recording
        if recording { return }
        if inUse {
            if armed {
                armed = false
                onDetected?(Self.likelyMeetingApp())
            }
        } else {
            armed = true
        }
    }

    static func likelyMeetingApp() -> String {
        let running = NSWorkspace.shared.runningApplications
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           let match = knownApps.first(where: { $0.bundleID == front }) {
            return match.name
        }
        for app in knownApps where running.contains(where: { $0.bundleIdentifier == app.bundleID }) {
            return app.name
        }
        return "An app"
    }
}
