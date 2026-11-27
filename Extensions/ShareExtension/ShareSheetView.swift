import LocalSendCore
import SwiftUI
import SwitchboardCore

struct ShareSheetView: View {
    let model: ShareExtensionModel

    var body: some View {
        NavigationStack {
            Group {
                if !model.moduleEnabled {
                    ContentUnavailableView {
                        Label("Share Anywhere is off", systemImage: "power")
                    } description: {
                        Text("Turn on the Share Anywhere module in the Switchboard app to send files from here.")
                    }
                } else {
                    content
                }
            }
            .navigationTitle("Send with Switchboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancel() }
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .browsing:
            browsing
        case let .sending(name, fraction):
            status(symbol: "paperplane.fill", tint: .blue, title: "Sending to \(name)…") {
                ProgressView(value: fraction).tint(.blue).frame(maxWidth: 240)
            }
        case .done(let message):
            status(symbol: "checkmark.circle.fill", tint: .green, title: message) { EmptyView() }
        case .failed(let message):
            status(symbol: "exclamationmark.triangle.fill", tint: .orange, title: message) {
                HStack {
                    Button("Close") { model.cancel() }.buttonStyle(.glass)
                }
            }
        }
    }

    private var browsing: some View {
        List {
            Section {
                if model.isLoading {
                    ProgressView()
                } else {
                    Label("\(model.files.count) item\(model.files.count == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: model.totalSize, countStyle: .file))",
                          systemImage: "doc.on.doc")
                    ForEach(model.files.prefix(5), id: \.self) { url in
                        Text(url.lastPathComponent).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }

            Section {
                ForEach(model.peers) { peer in
                    Button {
                        Task { await model.send(to: peer) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: peer.info.deviceType == .mobile ? "iphone.gen3" : "desktopcomputer")
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .background(Color.blue.gradient, in: .rect(cornerRadius: 10, style: .continuous))
                            VStack(alignment: .leading) {
                                Text(peer.info.alias).foregroundStyle(.primary)
                                Text(peer.host).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "paperplane").foregroundStyle(.blue)
                        }
                    }
                    .disabled(model.files.isEmpty)
                }
                if model.isScanning {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Looking for devices…").foregroundStyle(.secondary)
                    }
                } else if model.peers.isEmpty {
                    Button("Scan Again") { Task { await model.scan() } }
                }
            } header: {
                Text("Nearby Devices")
            } footer: {
                Text("Devices need LocalSend open on the same Wi-Fi network.")
            }
        }
    }

    private func status<Accessory: View>(symbol: String, tint: Color, title: String,
                                         @ViewBuilder accessory: () -> Accessory) -> some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 52))
                .foregroundStyle(tint)
                .symbolEffect(.bounce, value: title)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            accessory()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
