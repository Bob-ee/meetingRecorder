import Foundation
import MeetingCore

final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var storageRoot: String { didSet { defaults.set(storageRoot, forKey: "storageRoot") } }
    @Published var userName: String { didSet { defaults.set(userName, forKey: "userName") } }
    @Published var claudePath: String { didSet { defaults.set(claudePath, forKey: "claudePath") } }
    @Published var claudeModel: String { didSet { defaults.set(claudeModel, forKey: "claudeModel") } }
    @Published var asrVersion: String { didSet { defaults.set(asrVersion, forKey: "asrVersion") } }
    @Published var echoCancellation: Bool { didSet { defaults.set(echoCancellation, forKey: "echoCancellation") } }
    @Published var autoDetect: Bool { didSet { defaults.set(autoDetect, forKey: "autoDetect") } }
    @Published var lastProjectID: String { didSet { defaults.set(lastProjectID, forKey: "lastProjectID") } }
    /// "local" (this Mac does the work) or "hub".
    @Published var processingMode: String { didSet { defaults.set(processingMode, forKey: "processingMode") } }
    /// `mh1:<host>:<port>:<token>` from `meetinghub setup` / `meetinghub pair`.
    @Published var hubPairingCode: String { didSet { defaults.set(hubPairingCode, forKey: "hubPairingCode") } }
    @Published var hubLastSync: Double { didSet { defaults.set(hubLastSync, forKey: "hubLastSync") } }
    /// The calendar events were last added to (EventKit identifier); empty = the system default.
    @Published var calendarID: String { didSet { defaults.set(calendarID, forKey: "calendarID") } }

    init() {
        AppSettings.migrate(UserDefaults.standard)
        storageRoot = defaults.string(forKey: "storageRoot") ?? "~/Meetings"
        let accountName = NSFullUserName().trimmingCharacters(in: .whitespaces)
        let firstName = accountName.split(separator: " ").first.map(String.init) ?? ""
        userName = defaults.string(forKey: "userName") ?? (firstName.isEmpty ? "Me" : firstName)
        claudePath = defaults.string(forKey: "claudePath") ?? ""
        claudeModel = defaults.string(forKey: "claudeModel") ?? "sonnet"
        asrVersion = defaults.string(forKey: "asrVersion") ?? "v3"
        echoCancellation = defaults.object(forKey: "echoCancellation") as? Bool ?? false
        autoDetect = defaults.object(forKey: "autoDetect") as? Bool ?? true
        lastProjectID = defaults.string(forKey: "lastProjectID") ?? ""
        processingMode = defaults.string(forKey: "processingMode") ?? ProcessingMode.local.rawValue
        hubPairingCode = defaults.string(forKey: "hubPairingCode") ?? ""
        hubLastSync = defaults.double(forKey: "hubLastSync")
        calendarID = defaults.string(forKey: "calendarID") ?? ""
    }

    /// Fixes up settings written by older builds. Runs before anything is read.
    private static func migrate(_ defaults: UserDefaults) {
        guard defaults.integer(forKey: "settingsVersion") < 1 else { return }
        // Builds shipped between 2026-08-31 and 2026-09-01 switched realtime echo cancellation on for
        // everyone as a stop-gap. Leaving that value behind breaks recording outright: putting the mic
        // into voice processing makes CoreAudio re-enable the tap stream on the output device, which
        // stops the IO thread the system-audio tap runs on, and the restart comes back EAGAIN. Both
        // tracks then go silent a couple of seconds in. The offline canceller replaced it anyway.
        if defaults.object(forKey: "echoCancellation") as? Bool == true {
            defaults.set(false, forKey: "echoCancellation")
        }
        defaults.set(1, forKey: "settingsVersion")
    }

    var mode: ProcessingMode { ProcessingMode(rawValue: processingMode) ?? .local }

    /// Local-mode summarizer (claude -p on this Mac). Hub mode keeps its own settings on the hub.
    var summarizerSettings: SummarizerSettings {
        SummarizerSettings(provider: .claudeCLI, model: claudeModel, claudePath: claudePath)
    }

    var storageRootURL: URL {
        URL(fileURLWithPath: (storageRoot as NSString).expandingTildeInPath, isDirectory: true)
    }
}
