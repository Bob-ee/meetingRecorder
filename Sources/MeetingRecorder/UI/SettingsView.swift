import MeetingCore
import MeetingEngine
import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: Store
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var hub: HubSync
    @State private var claudeFound: String?

    var body: some View {
        Form {
            Section("Processing") {
                Picker("Where meetings are processed", selection: Binding(
                    get: { settings.mode },
                    set: { mode in
                        settings.processingMode = mode.rawValue
                        hub.configure()
                    })) {
                    Text("On this Mac").tag(ProcessingMode.local)
                    Text("On a hub").tag(ProcessingMode.hub)
                }
                .pickerStyle(.segmented)
                Text(settings.mode == .hub
                     ? "Recordings are uploaded to your hub, which transcribes and summarizes them even when this Mac is asleep or offline. Other devices see the same meetings."
                     : "Everything runs locally: free, private, and this Mac has to stay awake until a meeting is processed.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if settings.mode == .hub {
                HubSection()
            }

            Section("Storage") {
                LabeledContent("Meetings folder") {
                    HStack {
                        Text(settings.storageRoot).truncationMode(.middle).lineLimit(1)
                        Button("Choose…", action: chooseFolder)
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([store.rootURL]) }
                    }
                }
                Text("Plain Markdown + JSON, one folder per project, one per meeting. Point Claude Code at it directly.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("You") {
                TextField("Your name (label for your mic track)", text: $settings.userName)
            }

            Section(settings.mode == .hub ? "Recording" : "Transcription (on-device, free)") {
                if settings.mode == .local {
                    Picker("Speech model", selection: $settings.asrVersion) {
                        Text("Parakeet v3 — 25 languages").tag("v3")
                        Text("Parakeet v2 — English only, slightly better recall").tag("v2")
                    }
                }
                Toggle("Echo cancellation on the mic track", isOn: $settings.echoCancellation)
                Text("Keeps other people's voices (from your speakers) out of your mic track. Turn off if your mic sounds odd.")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.mode == .local {
                    HStack {
                        Button("Download models now") { app.downloadModels() }
                            .disabled(app.modelStatus != nil)
                        if let s = app.modelStatus { Text(s).font(.callout).foregroundStyle(.secondary) }
                    }
                    Text("Models cache in \(TranscriptionService.modelsDirectory.path)")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }

            if settings.mode == .local {
                Section("Summaries (Claude Code, your subscription)") {
                    Picker("Model", selection: $settings.claudeModel) {
                        Text("Sonnet (recommended)").tag("sonnet")
                        Text("Opus (slower, deeper)").tag("opus")
                        Text("Haiku (fastest)").tag("haiku")
                    }
                    TextField("Path to `claude` (blank = auto-detect)", text: $settings.claudePath)
                    HStack {
                        Button("Test") { claudeFound = ClaudeCLISummarizer.locateClaude(override: settings.claudePath) ?? "not found" }
                        if let f = claudeFound { Text(f).font(.callout).foregroundStyle(f == "not found" ? .red : .secondary) }
                    }
                }
            }

            Section("Meeting detection") {
                Toggle("Prompt me when another app starts using the microphone", isOn: Binding(
                    get: { settings.autoDetect }, set: { app.setAutoDetect($0) }))
                Text("Works for Zoom, Google Meet, Slack huddles, Teams, FaceTime — anything that opens the mic.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 600)
        .frame(minHeight: 520, maxHeight: 820)
        .padding(.vertical, 8)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use this folder"
        if panel.runModal() == .OK, let url = panel.url {
            settings.storageRoot = url.path
            store.setRoot(url)
        }
    }
}

/// Pairing, connection state, and the hub-side summarizer settings (rendered from what the hub says it supports).
private struct HubSection: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var hub: HubSync
    @State private var code = ""
    @State private var pairing = false
    @State private var pairError: String?
    @State private var draft: HubSettings?
    @State private var saving = false
    @State private var testing = false
    @State private var testResult: TestResult?
    @State private var saveMessage: String?

    var body: some View {
        Section("Hub") {
            if hub.client == nil {
                Text("On the always-on machine, run the installer from the README, then paste the pairing code it prints (`meetinghub pair` prints another one any time).")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("mh1:host:port:token", text: $code)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(pair)
                HStack {
                    Button(pairing ? "Connecting…" : "Connect") { pair() }
                        .disabled(pairing || PairingCode(parsing: code) == nil)
                    if let pairError { Text(pairError).font(.callout).foregroundStyle(.red) }
                }
            } else {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 8, height: 8)
                        Text(statusText)
                    }
                }
                if let me = hub.whoAmI {
                    LabeledContent("Hub") { Text("\(me.hub.name) \(me.hub.version) · \(me.hub.platform) · \(hub.client?.baseURL.host ?? "")").foregroundStyle(.secondary) }
                    LabeledContent("Signed in as") { Text("\(me.user.name) · \(me.workspace.name) · this device is “\(me.device)”").foregroundStyle(.secondary) }
                }
                HStack {
                    Button("Reconnect") { Task { await hub.connect() } }
                    Button("Upload existing meetings") { hub.uploadExistingMeetings() }
                        .disabled(!hub.state.isConnected || hub.migration != nil)
                        .help("Copies the meetings already on this Mac to the hub so other devices can see them")
                    Spacer()
                    Button("Forget hub", role: .destructive) { hub.forget() }
                }
                if let migration = hub.migration {
                    Text(migration).font(.callout).foregroundStyle(.secondary)
                }
                if let lastPull = hub.lastPull {
                    Text("Last sync \(lastPull.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }

        if hub.client != nil, hub.state.isConnected, let caps = hub.capabilities {
            Section("Summaries (on the hub)") {
                if draft == nil {
                    ProgressView().controlSize(.small)
                } else {
                    providerForm(caps)
                }
            }
            .onAppear { if draft == nil { draft = hub.hubSettings } }
            .onChange(of: hub.hubSettings) { _, new in if draft == nil || saving { draft = new } }
        }
    }

    @ViewBuilder
    private func providerForm(_ caps: Capabilities) -> some View {
        let providerBinding = Binding<SummarizerProvider>(
            get: { draft?.summarizer.provider ?? .claudeCLI },
            set: { p in
                draft?.summarizer.provider = p
                if let d = draft, d.summarizer.model.isEmpty || !suggestedModels(caps, for: d.summarizer.provider).contains(d.summarizer.model) {
                    draft?.summarizer.model = p.defaultModel
                }
                testResult = nil
            })
        Picker("Provider", selection: providerBinding) {
            ForEach(caps.providers) { p in Text(p.name).tag(p.id) }
        }
        if let desc = caps.providers.first(where: { $0.id == draft?.summarizer.provider }) {
            ForEach(desc.fields) { field in
                VStack(alignment: .leading, spacing: 2) {
                    if field.secret {
                        SecureField(field.label, text: fieldBinding(field.key), prompt: Text(field.placeholder))
                    } else {
                        TextField(field.label, text: fieldBinding(field.key), prompt: Text(field.placeholder))
                    }
                    if !field.help.isEmpty {
                        Text(field.help).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                TextField("Model", text: Binding(get: { draft?.summarizer.model ?? "" }, set: { draft?.summarizer.model = $0 }))
                Menu("Suggestions") {
                    ForEach(desc.suggestedModels, id: \.self) { m in Button(m) { draft?.summarizer.model = m } }
                }
                .fixedSize()
            }
        }
        if settings.mode == .hub {
            Picker("Speech model (on the hub)", selection: $settings.asrVersion) {
                Text("Parakeet v3 — 25 languages").tag("v3")
                Text("Parakeet v2 — English only").tag("v2")
            }
        }
        HStack {
            Button(saving ? "Saving…" : "Save") { save() }.disabled(saving || draft == nil)
            Button(testing ? "Testing…" : "Test") { test() }.disabled(testing || draft == nil)
            if let r = testResult {
                Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(r.ok ? .green : .red)
                Text(r.message).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            } else if let saveMessage {
                Text(saveMessage).font(.callout).foregroundStyle(.secondary)
            }
        }
        Text("Keys are stored encrypted on the hub and never on this Mac. Secrets show as •••••••• once saved; leave them as-is to keep them.")
            .font(.caption).foregroundStyle(.tertiary)
    }

    private func suggestedModels(_ caps: Capabilities, for p: SummarizerProvider) -> [String] {
        caps.providers.first { $0.id == p }?.suggestedModels ?? []
    }

    private func fieldBinding(_ key: String) -> Binding<String> {
        Binding(
            get: {
                guard let s = draft?.summarizer else { return "" }
                switch key {
                case "claudeOAuthToken": return s.claudeOAuthToken
                case "claudePath": return s.claudePath
                case "anthropicAPIKey": return s.anthropicAPIKey
                case "openAIBaseURL": return s.openAIBaseURL
                case "openAIAPIKey": return s.openAIAPIKey
                default: return ""
                }
            },
            set: { v in
                switch key {
                case "claudeOAuthToken": draft?.summarizer.claudeOAuthToken = v
                case "claudePath": draft?.summarizer.claudePath = v
                case "anthropicAPIKey": draft?.summarizer.anthropicAPIKey = v
                case "openAIBaseURL": draft?.summarizer.openAIBaseURL = v
                case "openAIAPIKey": draft?.summarizer.openAIAPIKey = v
                default: break
                }
            })
    }

    private var statusColor: Color {
        switch hub.state {
        case .connected: return .green
        case .connecting: return .yellow
        case .off: return .gray
        case .offline, .rejected: return .red
        }
    }

    private var statusText: String { hub.state.label }

    private func pair() {
        guard !pairing else { return }
        pairing = true
        pairError = nil
        Task {
            do {
                _ = try await hub.pair(code: code)
                code = ""
            } catch {
                pairError = error.localizedDescription
            }
            pairing = false
        }
    }

    private func save() {
        guard let draft else { return }
        saving = true
        saveMessage = nil
        testResult = nil
        Task {
            do {
                try await hub.saveHubSettings(draft)
                self.draft = hub.hubSettings
                saveMessage = "Saved"
            } catch {
                saveMessage = "Couldn't save: \(error.localizedDescription)"
            }
            saving = false
        }
    }

    private func test() {
        guard let draft else { return }
        testing = true
        testResult = nil
        Task {
            do {
                testResult = try await hub.testHubSettings(draft)
            } catch {
                testResult = TestResult(ok: false, message: error.localizedDescription, elapsedSeconds: 0)
            }
            testing = false
        }
    }
}
