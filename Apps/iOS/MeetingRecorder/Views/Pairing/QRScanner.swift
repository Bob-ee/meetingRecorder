import AVFoundation
import SwiftUI
import VisionKit

/// The camera, looking for a QR code. Reports the first one it reads.
struct QRScanner: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    /// False on devices without a suitable camera, and in the simulator.
    @MainActor
    static var isSupported: Bool { DataScannerViewController.isSupported }

    /// Ask for the camera if the user hasn't been asked yet; false if they said no.
    static func requestCamera() async -> Bool { await AVCaptureDevice.requestAccess(for: .video) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onScan: (String) -> Void
        private var reported = false
        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func dataScanner(_ scanner: DataScannerViewController, didAdd added: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !reported else { return }
            for case .barcode(let code) in added {
                guard let payload = code.payloadStringValue else { continue }
                reported = true
                scanner.stopScanning()
                onScan(payload)
                return
            }
        }
    }
}
