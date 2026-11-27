import LocalSendCore
import SwiftUI
import SwitchboardCore
import UIKit
import UniformTypeIdentifiers

/// "Switchboard" in the system share sheet: send whatever you're sharing to a
/// nearby LocalSend device without opening the app.
final class ShareViewController: UIViewController {
    private var model: ShareExtensionModel!

    override func viewDidLoad() {
        super.viewDidLoad()
        model = ShareExtensionModel(context: extensionContext)
        let host = UIHostingController(rootView: ShareSheetView(model: model))
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)

        Task { @MainActor in
            await model.loadAttachments()
            await model.scan()
        }
    }
}

@MainActor
@Observable
final class ShareExtensionModel {
    enum Phase: Equatable {
        case browsing
        case sending(to: String, fraction: Double)
        case done(String)
        case failed(String)
    }

    private(set) var files: [URL] = []
    private(set) var isLoading = true
    private(set) var peers: [Peer] = []
    private(set) var isScanning = false
    private(set) var phase: Phase = .browsing
    let moduleEnabled = FeatureFlags().isEnabled(.shareAnywhere)

    @ObservationIgnored private weak var context: NSExtensionContext?
    @ObservationIgnored private let client: LocalSendClient

    init(context: NSExtensionContext?) {
        self.context = context
        let defaults = AppGroup.defaults
        let fingerprint = defaults.string(forKey: "share.fingerprint") ?? UUID().uuidString
        let alias = defaults.string(forKey: "share.alias") ?? "Switchboard"
        client = LocalSendClient(me: DeviceInfo(alias: alias, deviceModel: "iPhone", deviceType: .mobile,
                                                fingerprint: fingerprint, transport: "http"))
    }

    var totalSize: Int64 {
        files.reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0)
        }
    }

    // MARK: Attachments

    func loadAttachments() async {
        defer { isLoading = false }
        let items = context?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        var loaded: [URL] = []
        for provider in providers {
            if let url = await Self.file(from: provider) { loaded.append(url) }
        }
        files = loaded
    }

    /// Turns one shared item into a local file we can upload.
    private static func file(from provider: NSItemProvider) async -> URL? {
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
            return writeText(url.absoluteString, name: "Link.txt")
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           provider.registeredTypeIdentifiers.count == 1,
           let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
            return writeText(text, name: "Text.txt")
        }
        guard let type = provider.registeredTypeIdentifiers.first else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                // The provided file is deleted when this handler returns, so copy it now.
                guard let url else { return continuation.resume(returning: nil) }
                let name = provider.suggestedName.map { name in
                    url.pathExtension.isEmpty || name.hasSuffix(".\(url.pathExtension)") ? name : "\(name).\(url.pathExtension)"
                } ?? url.lastPathComponent
                continuation.resume(returning: copyToTemp(url, name: name))
            }
        }
    }

    private static func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func copyToTemp(_ url: URL, name: String) -> URL? {
        let dest = tempDirectory().appendingPathComponent(FileNaming.sanitized(name))
        return (try? FileManager.default.copyItem(at: url, to: dest)) != nil ? dest : nil
    }

    private static func writeText(_ text: String, name: String) -> URL? {
        let dest = tempDirectory().appendingPathComponent(name)
        return (try? text.write(to: dest, atomically: true, encoding: .utf8)) != nil ? dest : nil
    }

    // MARK: Discovery & sending

    func scan() async {
        guard moduleEnabled, !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        await client.scanSubnet { [weak self] peer in
            Task { @MainActor in
                guard let self, !self.peers.contains(where: { $0.id == peer.id }) else { return }
                self.peers.append(peer)
            }
        }
    }

    func send(to peer: Peer) async {
        guard !files.isEmpty else { return }
        phase = .sending(to: peer.info.alias, fraction: 0)
        let result = await client.send(files: files, to: peer) { [weak self] sent, total in
            Task { @MainActor in
                guard let self, case .sending = self.phase else { return }
                self.phase = .sending(to: peer.info.alias, fraction: total > 0 ? Double(sent) / Double(total) : 0)
            }
        }
        switch result {
        case .done:
            phase = .done("Sent to \(peer.info.alias)")
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            try? await Task.sleep(for: .seconds(1.2))
            finish()
        case .declined: phase = .failed("\(peer.info.alias) declined the files.")
        case .busy: phase = .failed("\(peer.info.alias) is busy with another transfer.")
        case .failed(let reason): phase = .failed(reason)
        }
    }

    func finish() {
        context?.completeRequest(returningItems: nil)
    }

    func cancel() {
        context?.cancelRequest(withError: CocoaError(.userCancelled))
    }
}
