import Foundation

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
    }

    var storageRootURL: URL {
        URL(fileURLWithPath: (storageRoot as NSString).expandingTildeInPath, isDirectory: true)
    }
}
