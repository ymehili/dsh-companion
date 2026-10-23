import SwiftUI
import VisionKit
import AVFoundation

struct QRScanner: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced, recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false, isPinchToZoomEnabled: true,
            isGuidanceEnabled: true, isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        do { try controller.startScanning() }
        catch { DispatchQueue.main.async { onError("Camera could not start. You can paste the pairing link instead.") } }
        return controller
    }
    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let parent: QRScanner
        var delivered = false
        init(_ parent: QRScanner) { self.parent = parent }
        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            deliver(addedItems, scanner)
        }
        func dataScanner(_ scanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            deliver([item], scanner)
        }
        func dataScanner(_ scanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            parent.onError("Camera scanning is unavailable. Paste the pairing link instead.")
        }
        private func deliver(_ items: [RecognizedItem], _ scanner: DataScannerViewController) {
            guard !delivered else { return }
            for case .barcode(let barcode) in items {
                guard let value = barcode.payloadStringValue else { continue }
                delivered = true
                scanner.stopScanning()
                parent.onScan(value)
                return
            }
        }
    }
}
