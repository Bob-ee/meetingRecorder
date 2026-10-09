import Foundation
import MeetingCore

/// The link between one device and its hub: whether it is up, and the loops that keep the device in step
/// while it is — sending local changes shortly after they're made, pulling when the hub says something
/// changed, and checking in once a minute in case it didn't get to say.
@MainActor
public final class HubConnection: ObservableObject {
    public enum State: Equatable {
        case off, connecting, connected, offline(String), rejected(String)

        public var label: String {
            switch self {
            case .off: return "Not connected"
            case .connecting: return "Connecting…"
            case .connected: return "Connected"
            case .offline(let why): return "Hub unreachable — \(why)"
            case .rejected(let why): return why
            }
        }
        public var isConnected: Bool { self == .connected }
    }

    @Published public private(set) var state: State = .off
    @Published public private(set) var whoAmI: WhoAmI?
    @Published public private(set) var lastSync: Date?
    public private(set) var client: HubClient?
    public let engine: SyncEngine

    /// Runs after the hub has answered and before the first sync — the place to line local data up with the
    /// hub's (see the Mac app's project reconciliation).
    public var prepare: ((HubClient) async -> Void)?
    /// Every event the hub sends, pings excluded, for whoever wants more than "something changed".
    public var onEvent: ((HubEvent) -> Void)?

    private var eventTask: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var pushTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?

    public init(replica: any SyncReplica, ledgerURL: URL) {
        engine = SyncEngine(replica: replica, ledgerURL: ledgerURL)
        engine.onUnsentWork = { [weak self] in self?.pushSoon() }
    }

    /// Point the connection at a hub and connect; an empty or unreadable code disconnects.
    public func use(pairingCode: String) {
        disconnect()
        client = HubClient(pairingCode: pairingCode)
        if client != nil { Task { await connect() } }
    }

    public func connect() async {
        guard let client else { state = .off; return }
        state = .connecting
        do {
            let me = try await client.me()
            guard me.hub.apiVersion >= HubAPI.version else {
                state = .rejected("This hub is older than the app — update it by running the installer on it again")
                return
            }
            whoAmI = me
            engine.use(workspace: me.workspace.id)
            state = .connected
            await prepare?(client)
            startEventLoop()
            startHeartbeat()
            await sync()
        } catch let error as HubClientError where error.isUnauthorized {
            state = .rejected("The hub rejected this pairing code — pair this device again")
        } catch {
            state = .offline(error.localizedDescription)
            startHeartbeat()   // keeps trying
        }
    }

    public func disconnect() {
        for task in [eventTask, heartbeat, pushTask, syncTask] { task?.cancel() }
        eventTask = nil; heartbeat = nil; pushTask = nil; syncTask = nil
        client = nil
        whoAmI = nil
        state = .off
    }

    /// Check a pairing code against its hub without adopting it.
    public static func validate(pairingCode: String) async throws -> WhoAmI {
        guard let candidate = HubClient(pairingCode: pairingCode) else { throw HubClientError.badURL }
        return try await candidate.me()
    }

    // MARK: - Syncing

    public func note(_ change: LocalChange) { engine.note(change) }

    /// Send, then receive, then fill in transcripts and summaries. Safe to call at any time.
    public func sync() async {
        guard let client, state.isConnected else { return }
        do {
            try await engine.push(with: client)
            try await engine.pull(with: client)
            lastSync = Date()
            try await engine.fetchContent(with: client)
        } catch {
            Log.hub.error("sync failed: \(error.localizedDescription)")
            if error.isConnectivityProblem { state = .offline(error.localizedDescription) }
        }
    }

    /// Send local changes now rather than after the usual pause; throws if the hub can't be reached.
    public func push() async throws {
        guard let client else { throw HubClientError.notPaired }
        try await engine.push(with: client)
    }

    /// A burst of edits (typing in a notes field) becomes one request.
    private func pushSoon() {
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self, let client = self.client, self.state.isConnected else { return }
            do { try await self.engine.push(with: client) }
            catch { if error.isConnectivityProblem { self.state = .offline(error.localizedDescription) } }
        }
    }

    /// A burst of events (a job reporting progress) becomes one sync.
    private func syncSoon() {
        guard syncTask == nil else { return }
        syncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.syncTask = nil
            await self.sync()
        }
    }

    private func startEventLoop() {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let client = self.client else { return }
                do {
                    for try await event in client.events() where event.kind != .ping {
                        self.onEvent?(event)
                        if event.kind != .jobUpdated && event.kind != .settingsUpdated { self.syncSoon() }
                    }
                } catch {}
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if self.state.isConnected {
                    await self.sync()
                } else {
                    await self.connect()
                    return   // connect() starts a fresh one
                }
            }
        }
    }
}
