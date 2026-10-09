import MeetingCore
import MeetingSync
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var connection: HubConnection
    @EnvironmentObject var uploader: Uploader
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingUnpair = false

    var body: some View {
        NavigationStack {
            Form {
                hub
                if !uploader.outbox.isEmpty { uploads }
                Section {
                    Button("Unpair This Device", role: .destructive) { confirmingUnpair = true }
                } footer: {
                    Text("Removes everything Meeting Recorder keeps on this device. Your meetings stay on the hub and on your other devices.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Unpair this device?", isPresented: $confirmingUnpair, titleVisibility: .visible) {
                Button("Unpair", role: .destructive) {
                    app.unpair()
                    dismiss()
                }
            } message: {
                Text(uploader.outbox.isEmpty
                     ? "You'll need a new pairing code to connect again."
                     : "\(uploader.outbox.count) recording(s) haven't reached the hub yet and will be deleted.")
            }
        }
    }

    private var hub: some View {
        Section("Hub") {
            if let me = connection.whoAmI {
                LabeledContent("Hub", value: "\(me.hub.name) \(me.hub.version)")
                LabeledContent("Account", value: me.user.name)
                LabeledContent("This device", value: me.device)
            }
            LabeledContent("Status") {
                Text(connection.state.label)
                    .foregroundStyle(connection.state.isConnected ? Color.green : Color.orange)
                    .multilineTextAlignment(.trailing)
            }
            if let last = connection.lastSync {
                LabeledContent("Last synced") { Text(last, style: .relative) + Text(" ago") }
            }
            Button("Sync Now") {
                if connection.state.isConnected { app.syncNow() } else { Task { await connection.connect() } }
            }
            .disabled(connection.state == .connecting)
        }
    }

    private var uploads: some View {
        Section {
            ForEach(uploader.outbox) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.meeting.title)
                    Text(Fmt.dateTime.string(from: entry.meeting.startedAt)).font(.caption).foregroundStyle(.secondary)
                    switch uploader.state(for: entry.id) {
                    case .uploading(let sent)?:
                        ProgressView(value: sent)
                    case .failed(let why)?:
                        Label(why, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    default:
                        Text("Waiting for the hub").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Button("Retry Now") { uploader.resume() }
        } header: {
            Text("Recordings waiting to upload")
        } footer: {
            Text("Uploads carry on in the background and resume by themselves when the hub is reachable.")
        }
    }
}
