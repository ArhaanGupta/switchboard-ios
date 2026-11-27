import PhotosUI
import QRCore
import SwiftUI
import SwitchboardCore

struct QRScreen: View {
    @Environment(AppModel.self) private var app
    @State private var tab: Tab = .scan
    @State private var photoItem: PhotosPickerItem?

    enum Tab: String, CaseIterable { case scan = "Scan", create = "Create", history = "History" }

    var body: some View {
        @Bindable var qr = app.qr
        VStack(spacing: 0) {
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            switch tab {
            case .scan: scanTab
            case .create: QRCreateView()
            case .history: QRHistoryList()
            }
        }
        .moduleBackground(ModuleID.qrCode.tint)
        .sheet(item: $qr.presented) { item in
            QRResultView(item: item)
                .presentationDetents([.medium, .large])
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    await qr.scan(image: image)
                }
            }
        }
        .alert("QR Codes", isPresented: Binding(get: { qr.message != nil }, set: { if !$0 { qr.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(qr.message ?? "") }
    }

    private var scanTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                Group {
                    if QRScannerView.isAvailable {
                        QRScannerView { app.qr.didScan($0) }
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "camera.metering.unknown")
                                .font(.system(size: 40, weight: .light))
                            Text("Camera scanning isn't available here")
                                .font(.headline)
                            Text("Check camera access in Settings → Apps → Switchboard, or scan a code from a photo below.")
                                .font(.footnote)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.regularMaterial)
                    }
                }
                .frame(height: 360)
                .clipShape(.rect(cornerRadius: 28, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(ModuleID.qrCode.tint.opacity(0.5), lineWidth: 2)
                }

                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Scan from Photo or Screenshot", systemImage: "photo.on.rectangle.angled")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glass)

                if let recent = app.qr.history.first {
                    SectionHeader(title: "Last scanned")
                    Button { app.qr.presented = recent } label: { QRHistoryRow(item: recent) }
                        .buttonStyle(.plain)
                        .padding(14)
                        .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
                }

                Text("Everything you scan is saved to History on this iPhone, so you can find that Wi-Fi password or menu link again later.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(16)
        }
    }
}

// MARK: - Create

private struct QRCreateView: View {
    @Environment(AppModel.self) private var app
    @State private var kind: Kind = .link
    @State private var text = ""
    @State private var link = "https://"
    @State private var ssid = ""
    @State private var password = ""
    @State private var security: QRPayload.WiFiNetwork.Security = .wpa
    @State private var hidden = false
    @State private var name = ""
    @State private var phone = ""
    @State private var email = ""
    @State private var saved = false

    enum Kind: String, CaseIterable { case link = "Link", wifi = "Wi-Fi", contact = "Contact", text = "Text" }

    private var payload: QRPayload? {
        switch kind {
        case .text:
            return text.isEmpty ? nil : .text(text)
        case .link:
            guard let url = URL(string: link.trimmingCharacters(in: .whitespaces)), url.host != nil else { return nil }
            return .url(url)
        case .wifi:
            return ssid.isEmpty ? nil : .wifi(.init(ssid: ssid, password: password, security: security, hidden: hidden))
        case .contact:
            return name.isEmpty && phone.isEmpty && email.isEmpty ? nil : .contact(.init(name: name, phone: phone, email: email))
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Type", selection: $kind) {
                    ForEach(Kind.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section {
                switch kind {
                case .text:
                    TextField("Any text", text: $text, axis: .vertical).lineLimit(2...6)
                case .link:
                    TextField("https://example.com", text: $link)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                case .wifi:
                    TextField("Network name", text: $ssid).autocorrectionDisabled()
                    Picker("Security", selection: $security) {
                        Text("WPA/WPA2/WPA3").tag(QRPayload.WiFiNetwork.Security.wpa)
                        Text("WEP").tag(QRPayload.WiFiNetwork.Security.wep)
                        Text("None").tag(QRPayload.WiFiNetwork.Security.open)
                    }
                    if security != .open {
                        SecureField("Password", text: $password)
                    }
                    Toggle("Hidden network", isOn: $hidden)
                case .contact:
                    TextField("Name", text: $name).textContentType(.name)
                    TextField("Phone", text: $phone).keyboardType(.phonePad).textContentType(.telephoneNumber)
                    TextField("Email", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                }
            } footer: {
                if kind == .wifi {
                    Text("Guests point their camera at this code to join. No typing needed, and it works on iPhone and Android.")
                }
            }

            Section {
                QRCodeImage(string: payload?.encoded)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)

                if let payload, let image = QRModel.image(for: payload.encoded) {
                    ShareLink(item: Image(uiImage: image), preview: SharePreview(payload.summary, image: Image(uiImage: image))) {
                        Label("Share QR Code", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        app.qr.record(payload.encoded, source: .created)
                        saved = true
                        Haptics.success()
                    } label: {
                        Label(saved ? "Saved to History" : "Save to History",
                              systemImage: saved ? "checkmark.circle.fill" : "clock.arrow.circlepath")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .onChange(of: payload) { _, _ in saved = false }
    }
}

/// White rounded tile with a QR code (or a placeholder).
struct QRCodeImage: View {
    let string: String?
    var size: CGFloat = 220

    var body: some View {
        Group {
            if let string, let image = QRModel.image(for: string) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(16)
                    .accessibilityLabel("QR code")
            } else {
                Image(systemName: "qrcode")
                    .font(.system(size: size * 0.45, weight: .ultraLight))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .background(.white, in: .rect(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 6)
        .animation(.smooth, value: string)
    }
}

// MARK: - History

private struct QRHistoryList: View {
    @Environment(AppModel.self) private var app
    @State private var confirmClear = false

    var body: some View {
        List {
            if app.qr.history.isEmpty {
                EmptyStateView(symbol: "qrcode.viewfinder", title: "No codes yet",
                               message: "Codes you scan or create show up here.")
                    .listRowBackground(Color.clear)
            }
            ForEach(app.qr.history) { item in
                Button { app.qr.presented = item } label: { QRHistoryRow(item: item) }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .leading) {
                        Button { app.qr.toggleFavorite(item) } label: {
                            Label("Favorite", systemImage: item.isFavorite ? "star.slash" : "star")
                        }
                        .tint(.yellow)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { app.qr.delete(item) } label: { Label("Delete", systemImage: "trash") }
                    }
            }
            if !app.qr.history.isEmpty {
                Button("Clear History", role: .destructive) { confirmClear = true }
            }
        }
        .scrollContentBackground(.hidden)
        .confirmationDialog("Clear history? Favorites are kept.", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { app.qr.clearAll() }
        }
    }
}

struct QRHistoryRow: View {
    let item: QRHistoryItem

    var body: some View {
        let payload = item.payload
        HStack(spacing: 12) {
            Image(systemName: payload.symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(ModuleID.qrCode.tint)
                .frame(width: 32, height: 32)
                .background(ModuleID.qrCode.tint.opacity(0.15), in: .circle)
            VStack(alignment: .leading, spacing: 3) {
                Text(payload.summary).font(.subheadline).lineLimit(2)
                Text("\(payload.kindName) · \(item.source == .scanned ? "Scanned" : "Created") \(item.date.formatted(.relative(presentation: .named)))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if item.isFavorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
        }
        .contentShape(.rect)
    }
}

// MARK: - Result

private struct QRResultView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    let item: QRHistoryItem

    var body: some View {
        let payload = item.payload
        NavigationStack {
            List {
                Section {
                    QRCodeImage(string: item.raw, size: 180)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
                Section(payload.kindName) {
                    details(payload)
                }
                Section {
                    actions(payload)
                    Button("Copy Raw Text", systemImage: "doc.on.doc") { copy(item.raw) }
                    ShareLink(item: item.raw)
                }
            }
            .navigationTitle(payload.summary)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { app.qr.toggleFavorite(item) } label: {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                    }
                    .accessibilityLabel(isFavorite ? "Remove favorite" : "Add favorite")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { app.qr.presented = nil }
                }
            }
        }
    }

    private var isFavorite: Bool { app.qr.history.first { $0.id == item.id }?.isFavorite ?? false }

    @ViewBuilder private func details(_ payload: QRPayload) -> some View {
        switch payload {
        case .text(let text):
            Text(text).textSelection(.enabled)
        case .url(let url):
            Text(url.absoluteString).textSelection(.enabled).foregroundStyle(.blue)
        case .wifi(let wifi):
            LabeledContent("Network", value: wifi.ssid)
            if wifi.security != .open {
                LabeledContent("Password", value: wifi.password).textSelection(.enabled)
            }
            LabeledContent("Security", value: wifi.security == .open ? "None" : wifi.security.rawValue)
        case .contact(let c):
            if !c.name.isEmpty { LabeledContent("Name", value: c.name) }
            if !c.phone.isEmpty { LabeledContent("Phone", value: c.phone) }
            if !c.email.isEmpty { LabeledContent("Email", value: c.email) }
            if !c.organization.isEmpty { LabeledContent("Company", value: c.organization) }
        case .email(let e):
            Text(e).textSelection(.enabled)
        case .phone(let p):
            Text(p).textSelection(.enabled)
        }
    }

    @ViewBuilder private func actions(_ payload: QRPayload) -> some View {
        switch payload {
        case .url(let url):
            Button("Open Link", systemImage: "safari") { openURL(url) }
        case .wifi(let wifi):
            if wifi.security != .open {
                Button("Copy Password", systemImage: "key") { copy(wifi.password) }
            }
            Button("Open Wi-Fi Settings", systemImage: "wifi") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        case .email(let e):
            if let url = URL(string: "mailto:\(e)") { Button("Write Email", systemImage: "envelope") { openURL(url) } }
        case .phone(let p):
            if let url = URL(string: "tel:\(p.filter { $0.isNumber || $0 == "+" })") {
                Button("Call", systemImage: "phone") { openURL(url) }
            }
        case .contact(let c):
            if !c.phone.isEmpty { Button("Copy Phone", systemImage: "phone") { copy(c.phone) } }
            if !c.email.isEmpty { Button("Copy Email", systemImage: "envelope") { copy(c.email) } }
        case .text(let t):
            Button("Copy Text", systemImage: "doc.on.doc") { copy(t) }
        }
    }

    private func copy(_ string: String) {
        UIPasteboard.general.string = string
        Haptics.success()
    }
}
