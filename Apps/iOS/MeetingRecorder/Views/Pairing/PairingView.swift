import MeetingCore
import SwiftUI

/// The first screen: nothing works until the device knows which hub is its own.
struct PairingView: View {
    @EnvironmentObject var app: AppModel
    @State private var code = ""
    @State private var scanning = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "waveform.badge.mic")
                            .font(.system(size: 52))
                            .foregroundStyle(.tint)
                        Text("Pair with your hub")
                            .font(.title2.weight(.semibold))
                        Text("Your hub transcribes and summarizes your meetings and keeps every device in sync. This device needs a pairing code to talk to it.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }

                Section {
                    if QRScanner.isSupported {
                        Button(action: scan) { Label("Scan QR Code", systemImage: "qrcode.viewfinder") }
                    }
                    TextField("mh1:…", text: $code)
                        .font(.callout.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("pairing-code")
                    Button {
                        pair(code)
                    } label: {
                        HStack {
                            Text("Pair")
                            if working { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(PairingCode(parsing: code) == nil || working)
                } header: {
                    Text("Pairing code")
                } footer: {
                    Text("On your Mac, open Meeting Recorder → Settings → Hub and choose “Pair iPhone or iPad” to show a QR code. Or run `meetinghub pair` on the hub and paste the code it prints.")
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }

                Section {
                    Label("The hub is reached over Tailscale. Make sure this device is signed in to your tailnet and Tailscale is connected.",
                          systemImage: "network")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Meeting Recorder")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $scanning) {
                QRScanner { scanned in
                    scanning = false
                    // A pairing QR holds a meetingrecorder:// link; a bare code works too.
                    let found = URL(string: scanned).flatMap(PairingCode.init(url:)) ?? PairingCode(parsing: scanned)
                    if let found { pair(found.string) } else { error = "That QR code isn't a Meeting Recorder pairing code." }
                }
                .ignoresSafeArea()
            }
        }
    }

    private func scan() {
        Task {
            if await QRScanner.requestCamera() {
                scanning = true
            } else {
                error = "Meeting Recorder isn't allowed to use the camera. Turn it on in Settings, or paste the code instead."
            }
        }
    }

    private func pair(_ code: String) {
        working = true
        error = nil
        Task {
            defer { working = false }
            do { try await app.pair(code: code) }
            catch { self.error = "Couldn't pair: \(error.localizedDescription)" }
        }
    }
}
