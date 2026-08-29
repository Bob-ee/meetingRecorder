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

    init() {
        storageRoot = defaults.string(forKey: "storageRoot") ?? "~/Meetings"
        let accountName = NSFullUserName().trimmingCharacters(in: .whitespaces)
        let firstName = accountName.split(separator: " ").first.map(String.init) ?? ""
        userName = defaults.string(forKey: "userName") ?? (firstName.isEmpty ? "Me" : firstName)
        claudePath = defaults.string(forKey: "claudePath") ?? ""
        claudeModel = defaults.string(forKey: "claudeModel") ?? "sonnet"
        asrVersion = defaults.string(forKey: "asrVersion") ?? "v3"
        echoCancellation = defaults.object(forKey: "echoCancellation") as? Bool ?? true
        autoDetect = defaults.object(forKey: "autoDetect") as? Bool ?? true
        lastProjectID = defaults.string(forKey: "lastProjectID") ?? ""
        processingMode = defaults.string(forKey: "processingMode") ?? ProcessingMode.local.rawValue
        hubPairingCode = defaults.string(forKey: "hubPairingCode") ?? ""
        hubLastSync = defaults.double(forKey: "hubLastSync")
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
