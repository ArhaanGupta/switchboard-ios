import CoreImage
import CoreImage.CIFilterBuiltins
import QRCore
import SwiftUI
import SwitchboardCore
import UIKit
import Vision

@MainActor
@Observable
final class QRModel {
    private let file = JSONFile<QRHistory>(name: "qr-history.json")

    private(set) var history: [QRHistoryItem] = []
    /// The item shown in the result sheet.
    var presented: QRHistoryItem?
    var message: String?

    init() { reload() }

    func reload() {
        history = file.load()?.items ?? []
    }

    // MARK: History

    @discardableResult
    func record(_ raw: String, source: QRHistoryItem.Source) -> QRHistoryItem? {
        let updated = file.mutate(default: QRHistory()) { $0.record(raw, source: source) }
        history = updated.items
        return history.first
    }

    func didScan(_ raw: String) {
        // Ignore the camera re-reporting the code that's already open.
        guard presented?.raw != raw else { return }
        Haptics.success()
        presented = record(raw, source: .scanned)
    }

    func toggleFavorite(_ item: QRHistoryItem) {
        let updated = file.mutate(default: QRHistory()) { history in
            if let i = history.items.firstIndex(where: { $0.id == item.id }) { history.items[i].isFavorite.toggle() }
        }
        history = updated.items
    }

    func delete(_ item: QRHistoryItem) {
        history = file.mutate(default: QRHistory()) { $0.items.removeAll { $0.id == item.id } }.items
    }

    func clearAll() {
        history = file.mutate(default: QRHistory()) { $0.items.removeAll { !$0.isFavorite } }.items
    }

    // MARK: Photo scanning

    func scan(image: UIImage) async {
        guard let cgImage = image.cgImage else { return }
        let codes = await Task.detached(priority: .userInitiated) { Self.detectCodes(in: cgImage) }.value
        if let first = codes.first {
            for extra in codes.dropFirst() { record(extra, source: .scanned) }
            didScan(first)
        } else {
            Haptics.warning()
            message = "No QR code found in that image."
        }
    }

    nonisolated static func detectCodes(in image: CGImage) -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr, .microQR, .aztec, .dataMatrix]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        return (request.results ?? []).compactMap(\.payloadStringValue)
    }

    // MARK: Generation

    private static let context = CIContext()

    /// Renders a crisp QR code image for the given string.
    static func image(for string: String, scale: CGFloat = 12) -> UIImage? {
        guard !string.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
              let cgImage = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
