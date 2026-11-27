import CoreTransferable
import LocalSendCore
import PhotosUI
import QuickLook
import SwiftUI
import SwitchboardCore
import UniformTypeIdentifiers

struct ShareScreen: View {
    @Environment(AppModel.self) private var app
    @State private var selectedPeer: Peer?
    @State private var showFileImporter = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var previewURL: URL?
    @State private var editingName = false

    private var share: LocalSendService { app.share }

    var body: some View {
        @Bindable var share = app.share
        List {
            Section {
                visibilityCard
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }

            if share.isRunning {
                Section {
                    if share.peers.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(share.isScanning ? "Looking for devices…" : "No devices found yet")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(share.peers) { peer in
                        PeerRow(peer: peer)
                            .contentShape(.rect)
                            .onTapGesture { selectedPeer = peer }
                    }
                } header: {
                    HStack {
                        Text("Nearby Devices")
                        Spacer()
                        Button {
                            Task { await share.refreshPeers() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(share.isScanning)
                    }
                } footer: {
                    Text("Devices need the free LocalSend app (Windows, macOS, Linux, Android) on the same Wi-Fi. Tap a device to send files.")
                }
            }

            if !share.transfers.isEmpty {
                Section {
                    ForEach(share.transfers) { TransferRow(transfer: $0) }
                } header: {
                    HStack {
                        Text("Transfers")
                        Spacer()
                        Button("Clear") { share.clearFinishedTransfers() }.font(.caption.weight(.semibold))
                    }
                }
            }

            Section {
                if share.receivedFiles.isEmpty {
                    Text("Files you receive appear here and in the Files app under On My iPhone → Switchboard.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(share.receivedFiles, id: \.self) { url in
                    Button { previewURL = url } label: {
                        Label(url.lastPathComponent, systemImage: Self.symbol(for: url))
                            .lineLimit(1)
                    }
                    .swipeActions {
                        Button(role: .destructive) { share.deleteReceived(url) } label: { Label("Delete", systemImage: "trash") }
                        ShareLink(item: url)
                    }
                }
            } header: {
                Text("Received")
            }

            Section {
                Toggle("Accept files automatically", isOn: $share.autoAccept)
                Button { editingName = true } label: {
                    LabeledContent("Device name", value: share.alias)
                }
                if share.multicastAvailable == false {
                    Label("Using network scan for discovery. Devices may take a few seconds to appear.",
                          systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Settings")
            } footer: {
                Text("Receiving works while Switchboard is open. iOS pauses it in the background. Files you receive are not encrypted on the way. Send private files only on networks you trust.")
            }
        }
        .scrollContentBackground(.hidden)
        .moduleBackground(ModuleID.shareAnywhere.tint)
        .onDisappear { if share.transfers.allSatisfy({ $0.state != .running }) { share.stop() } }
        .confirmationDialog("Send to \(selectedPeer?.info.alias ?? "")", isPresented: Binding(
            get: { selectedPeer != nil && !showFileImporter && !showPhotoPicker },
            set: { if !$0, !showFileImporter, !showPhotoPicker { selectedPeer = nil } }
        ), titleVisibility: .visible) {
            Button("Photos & Videos") { showPhotoPicker = true }
            Button("Files") { showFileImporter = true }
            Button("Cancel", role: .cancel) { selectedPeer = nil }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard let peer = selectedPeer, case let .success(urls) = result else { selectedPeer = nil; return }
            let copies = urls.compactMap(Self.copyToTemp)
            selectedPeer = nil
            Task { await share.send(copies, to: peer) }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems, maxSelectionCount: 50, matching: .any(of: [.images, .videos]))
        .onChange(of: photoItems) { _, items in
            guard let peer = selectedPeer, !items.isEmpty else { return }
            selectedPeer = nil
            photoItems = []
            Task {
                var urls: [URL] = []
                for item in items {
                    if let media = try? await item.loadTransferable(type: PickedMedia.self) { urls.append(media.url) }
                }
                await share.send(urls, to: peer)
            }
        }
        .sheet(item: Binding(get: { share.incoming }, set: { if $0 == nil { share.incoming?.respond(false) } })) { request in
            IncomingSheet(request: request)
                .presentationDetents([.medium])
                .interactiveDismissDisabled()
        }
        .quickLookPreview($previewURL, in: share.receivedFiles)
        .alert("Device name", isPresented: $editingName) {
            TextField("Name", text: $share.alias)
            Button("Done") {}
        }
        .alert("Share Anywhere", isPresented: Binding(get: { share.errorMessage != nil },
                                                      set: { if !$0 { share.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(share.errorMessage ?? "") }
    }

    private var visibilityCard: some View {
        VStack(spacing: 14) {
            ZStack {
                if share.isRunning {
                    ForEach(0..<3) { i in
                        Circle()
                            .stroke(Color.blue.opacity(0.35), lineWidth: 2)
                            .frame(width: 120, height: 120)
                            .phaseAnimator([0.6, 1.6]) { view, scale in
                                view.scaleEffect(scale).opacity(2 - scale)
                            } animation: { _ in .easeOut(duration: 2.4).delay(Double(i) * 0.8) }
                    }
                }
                Button {
                    Haptics.tap()
                    share.isRunning ? share.stop() : share.start()
                } label: {
                    Image(systemName: share.isRunning ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(share.isRunning ? .white : .secondary)
                        .frame(width: 110, height: 110)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .glassEffect(share.isRunning ? Glass.regular.tint(.blue).interactive() : Glass.regular.interactive(), in: .circle)
            }
            .frame(height: 150)
            Text(share.isRunning ? "Visible as \(share.alias)" : "Tap to share with nearby devices")
                .font(.headline)
            Text("Works with LocalSend on Windows, Mac, Linux and Android, including phones without AirDrop support.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    static func symbol(for url: URL) -> String {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        return "doc"
    }

    /// Copies a security-scoped file into our temp directory so it can be uploaded later.
    static func copyToTemp(_ url: URL) -> URL? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            return dest
        } catch {
            return nil
        }
    }
}

/// Photo/video from the picker, exported to a temp file.
struct PickedMedia: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            PickedMedia(url: try copy(received.file))
        }
        FileRepresentation(importedContentType: .image) { received in
            PickedMedia(url: try copy(received.file))
        }
    }

    private static func copy(_ file: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: dest)
        return dest
    }
}

private struct PeerRow: View {
    let peer: Peer

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color.blue.gradient, in: .rect(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.info.alias).font(.body.weight(.medium))
                Text([peer.info.deviceModel, peer.host].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "paperplane.fill").foregroundStyle(.blue)
        }
    }

    private var symbol: String {
        switch peer.info.deviceType {
        case .mobile: "iphone.gen3"
        case .desktop: "desktopcomputer"
        case .web: "globe"
        case .headless, .server: "server.rack"
        case nil: "questionmark.square.dashed"
        }
    }
}

private struct TransferRow: View {
    let transfer: LocalSendService.Transfer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: transfer.direction == .incoming ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                    .foregroundStyle(.blue)
                Text("\(transfer.direction == .incoming ? "From" : "To") \(transfer.peerName)")
                    .font(.subheadline.weight(.medium))
                Spacer()
                status
            }
            if transfer.state == .running {
                ProgressView(value: transfer.fraction)
                    .tint(.blue)
            }
            Text("\(transfer.fileCount) file\(transfer.fileCount == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: transfer.totalBytes, countStyle: .file))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var status: some View {
        switch transfer.state {
        case .running:
            Text(transfer.fraction, format: .percent.precision(.fractionLength(0)))
                .font(.caption.monospacedDigit())
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
        }
    }
}

private struct IncomingSheet: View {
    let request: LocalSendService.IncomingRequest

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 44))
                .foregroundStyle(.blue)
                .padding(.top, 24)
            Text("\(request.sender.alias) wants to send you")
                .font(.headline)
            Text("\(request.files.count) file\(request.files.count == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: request.totalSize, countStyle: .file))")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(request.files, id: \.id) { file in
                        Label(file.fileName, systemImage: "doc").font(.footnote).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
            HStack(spacing: 12) {
                Button(role: .cancel) { request.respond(false) } label: {
                    Text("Decline").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.glass)
                Button { request.respond(true) } label: {
                    Text("Accept").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .tint(.blue)
            }
        }
        .padding(.horizontal, 24)
    }
}
