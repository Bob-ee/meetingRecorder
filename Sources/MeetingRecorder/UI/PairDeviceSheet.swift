import CoreImage.CIFilterBuiltins
import MeetingCore
import SwiftUI

/// Pairs an iPhone or iPad: asks the hub for a pairing code for it and shows that code as a QR. Scanning it
/// with the device's camera opens the app there, already paired.
struct PairDeviceSheet: View {
    @EnvironmentObject var hub: HubSync
    @Environment(\.dismiss) private var dismiss
    @State private var name = "iPhone"
    @State private var code: PairingCode?
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pair iPhone or iPad").font(.headline)
            if let code {
                paired(code)
            } else {
                Text("Give the device a name — it's how you'll recognize it in `meetinghub tokens` if you ever need to revoke it.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Device name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(create)
                if let error { Text(error).font(.callout).foregroundStyle(.red) }
            }
            HStack {
                Spacer()
                if code == nil {
                    Button("Cancel", role: .cancel) { dismiss() }
                    Button(working ? "Creating…" : "Show QR Code", action: create)
                        .keyboardShortcut(.defaultAction)
                        .disabled(working || name.trimmingCharacters(in: .whitespaces).isEmpty)
                } else {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    @ViewBuilder
    private func paired(_ code: PairingCode) -> some View {
        Text("Open the Camera on “\(name)” and point it at this code. The device has to be on your tailnet to reach the hub.")
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if let image = code.url.flatMap({ QRCode.image(for: $0.absoluteString) }) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .frame(width: 240, height: 240)
                .frame(maxWidth: .infinity)
        }
        Text("Or paste this into the app on the device. It's shown once — the hub only keeps its hash.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Text(code.string)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .lineLimit(3)
    }

    private func create() {
        let device = name.trimmingCharacters(in: .whitespaces)
        guard !working, !device.isEmpty else { return }
        working = true
        error = nil
        Task {
            do { code = try await hub.pairDevice(named: device) }
            catch { self.error = error.localizedDescription }
            working = false
        }
    }
}

enum QRCode {
    static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
