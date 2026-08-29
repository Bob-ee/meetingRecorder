import Fluent
import Foundation
import MeetingCore
import Vapor

/// `meetinghub setup` — the one command a new user runs.
struct SetupCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "name", help: "Your name (how your own voice is labeled in transcripts)") var name: String?
        @Option(name: "port", help: "Port to listen on (default 8787)") var port: Int?
        @Option(name: "device", help: "Name for the first paired device (default: Setup)") var device: String?
        @Flag(name: "no-service", help: "Don't install/start the background service") var noService: Bool
        init() {}
    }

    var help: String { "First-run setup: your account, a pairing code for your devices, and the background service" }

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        let console = context.console
        let db = app.db
        let paths = app.hubPaths

        console.print("")
        console.output("Meeting Hub \(HubVersion.string)".consoleText(.info))
        console.print("Data directory: \(paths.root.path)")

        var config = app.hubConfig
        if let port = signature.port { config.port = port }
        try config.save(to: paths.configFile)
        app.hubConfig = config

        let user: UserModel
        if let existing = try await UserModel.query(on: db).sort(\.$createdAt).first() {
            user = existing
            console.print("Account: \(user.name)")
        } else {
            var name = signature.name?.trimmingCharacters(in: .whitespaces) ?? ""
            while name.isEmpty {
                name = console.ask("Your name (this is how your own voice is labeled in transcripts):").trimmingCharacters(in: .whitespaces)
            }
            let u = UserModel(name: name)
            try await u.save(on: db)
            let ws = WorkspaceModel(name: "\(name)'s meetings", ownerID: u.id!)
            try await ws.save(on: db)
            try await WorkspaceMemberModel(workspaceID: ws.id!, userID: u.id!, role: "owner").save(on: db)
            let inbox = ProjectModel(workspaceID: ws.id!, name: "Inbox")
            try await inbox.save(on: db)
            ExportMirror(root: paths.export).writeProject(workspace: ws.name, project: inbox)
            user = u
            console.output("Created your account and workspace.".consoleText(.success))
        }
        guard let workspace = try await WorkspaceModel.query(on: db).filter(\.$owner.$id == user.id!).first() else {
            throw Abort(.internalServerError, reason: "no workspace for \(user.name)")
        }

        // Pairing code
        let code = try await Pairing.create(deviceName: signature.device ?? "Setup", user: user, workspace: workspace, app: app)

        // Service
        #if os(macOS)
        if !signature.noService {
            do {
                try LaunchAgent.install(paths: paths)
                try await Task.sleep(nanoseconds: 1_500_000_000)
                if LaunchAgent.isRunning() {
                    console.output("Background service installed and running (starts at login, restarts if it stops).".consoleText(.success))
                } else {
                    console.output("Service installed but not running yet — check \(paths.logs.appendingPathComponent("hub.log").path)".consoleText(.warning))
                }
            } catch {
                console.output("Couldn't install the background service: \(error.localizedDescription)".consoleText(.error))
                console.print("You can run the hub in the foreground with: meetinghub serve")
            }
        } else {
            console.print("Skipped the background service. Run the hub with: meetinghub serve")
        }
        #else
        console.print("Run the hub with: meetinghub serve   (a systemd unit is on the roadmap)")
        #endif

        console.print("")
        console.output("Pair a device — paste this into the app's Settings → Hub:".consoleText(.info))
        console.output("  \(code)".consoleText(.success))
        console.print("")
        console.print("Then pick how summaries get written (Settings → Hub → Summarizer):")
        console.print("  • Claude subscription: run `claude setup-token` on any computer where Claude Code is logged in and paste the token")
        console.print("  • Anthropic API key, or any OpenAI-compatible server (OpenAI, Ollama, LM Studio…)")
        console.print("")
        console.print("Health check: curl http://\(NetworkInfo.pairingHost()):\(config.port)/api/v1/health")
    }
}

/// `meetinghub pair [--name "Bobby's iPhone"]` — a fresh pairing code for another device.
struct PairCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "name", help: "Device name shown in the token list") var name: String?
        init() {}
    }

    var help: String { "Print a new pairing code for another device" }

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        guard let user = try await UserModel.query(on: app.db).sort(\.$createdAt).first(),
              let workspace = try await WorkspaceModel.query(on: app.db).filter(\.$owner.$id == user.id!).first() else {
            context.console.output("Run `meetinghub setup` first.".consoleText(.error))
            return
        }
        let code = try await Pairing.create(deviceName: signature.name ?? ProcessInfo.processInfo.hostName, user: user, workspace: workspace, app: app)
        context.console.output(code.consoleText(.success))
    }
}

/// `meetinghub tokens [--revoke NAME]`
struct TokensCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "revoke", help: "Revoke the token with this device name (or id prefix)") var revoke: String?
        init() {}
    }

    var help: String { "List paired devices, or revoke one" }

    func run(using context: CommandContext, signature: Signature) async throws {
        let db = context.application.db
        let tokens = try await DeviceTokenModel.query(on: db).sort(\.$createdAt).all()
        if let target = signature.revoke {
            let matches = tokens.filter { $0.revokedAt == nil && ($0.name == target || $0.id!.uuidString.lowercased().hasPrefix(target.lowercased())) }
            guard !matches.isEmpty else { context.console.output("No active token named \(target)".consoleText(.error)); return }
            for t in matches { t.revokedAt = Date(); try await t.save(on: db) }
            context.console.output("Revoked \(matches.count) token(s).".consoleText(.success))
            return
        }
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short
        for t in tokens {
            let state = t.revokedAt != nil ? "revoked" : (t.lastUsedAt.map { "last used \(f.string(from: $0))" } ?? "never used")
            context.console.print("\(t.id!.uuidString.prefix(8))  \(t.name.padding(toLength: 24, withPad: " ", startingAt: 0))  \(state)")
        }
        if tokens.isEmpty { context.console.print("No devices paired yet — run `meetinghub pair`.") }
    }
}

/// `meetinghub service install|uninstall|restart|status`
struct ServiceCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Argument(name: "action", help: "install, uninstall, restart or status") var action: String
        init() {}
    }

    var help: String { "Manage the background service (macOS launchd)" }

    func run(using context: CommandContext, signature: Signature) async throws {
        #if os(macOS)
        let console = context.console
        switch signature.action {
        case "install":
            try LaunchAgent.install(paths: context.application.hubPaths)
            console.output("Installed and started.".consoleText(.success))
        case "uninstall":
            LaunchAgent.uninstall()
            console.output("Stopped and removed.".consoleText(.success))
        case "restart":
            console.output((LaunchAgent.restart() ? "Restarted." : "Couldn't restart — is it installed?").consoleText(.info))
        case "status":
            let installed = LaunchAgent.isInstalled, running = LaunchAgent.isRunning()
            console.print("service: \(installed ? "installed" : "not installed"), \(running ? "running" : "not running")")
            console.print("log: \(context.application.hubPaths.logs.appendingPathComponent("hub.log").path)")
        default:
            console.output("Usage: meetinghub service install|uninstall|restart|status".consoleText(.error))
        }
        #else
        context.console.print("Service management is macOS-only for now; use systemd on Linux.")
        #endif
    }
}

enum Pairing {
    static func create(deviceName: String, user: UserModel, workspace: WorkspaceModel, app: Application) async throws -> String {
        let raw = Tokens.generate()
        try await DeviceTokenModel(userID: user.id!, workspaceID: workspace.id!, name: deviceName, tokenHash: Tokens.hash(raw)).save(on: app.db)
        return PairingCode(host: NetworkInfo.pairingHost(), port: app.hubConfig.port, token: raw).string
    }
}
