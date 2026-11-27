import ShieldCore
import SwiftUI
import SwitchboardCore

struct ShieldScreen: View {
    @Environment(AppModel.self) private var app
    @State private var newDomain = ""
    @State private var showLog = false

    private var shield: ShieldController { app.shield }

    var body: some View {
        List {
            Section {
                powerCard
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }

            Section {
                HStack(spacing: 12) {
                    StatTile(value: shield.stats.blockedQueries.formatted(), label: "Blocked", tint: .green)
                    StatTile(value: shield.stats.totalQueries.formatted(), label: "Lookups", tint: .primary)
                    StatTile(value: "\(Int(shield.stats.blockedPercent))%", label: "Blocked share", tint: .green)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                Button { showLog = true } label: {
                    Label("Recent Activity", systemImage: "list.bullet.rectangle")
                }
            } header: {
                Text("Since \(shield.stats.since.formatted(date: .abbreviated, time: .shortened))")
            }

            Section {
                ForEach(shield.config.sources) { source in
                    Toggle(isOn: Binding(get: { source.enabled },
                                         set: { shield.setSource(source.id, enabled: $0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.name)
                            Text(source.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tint(.green)
                }
                Button {
                    Task { await shield.updateBlocklists() }
                } label: {
                    HStack {
                        Label("Update Blocklists", systemImage: "arrow.down.circle")
                        Spacer()
                        if shield.isUpdatingLists { ProgressView() }
                    }
                }
                .disabled(shield.isUpdatingLists)
            } header: {
                Text("Blocklists")
            } footer: {
                Text("\(shield.config.domainCount.formatted()) domains active" +
                     (shield.config.lastUpdated.map { " · updated \($0.formatted(.relative(presentation: .named)))" } ?? " · built-in starter list"))
            }

            Section {
                HStack {
                    TextField("example.com", text: $newDomain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("Allow") { shield.allow(newDomain); newDomain = "" }
                        .disabled(!BlocklistParser.isValidDomain(newDomain.lowercased()))
                    Button("Block") { shield.block(newDomain); newDomain = "" }
                        .tint(.red)
                        .disabled(!BlocklistParser.isValidDomain(newDomain.lowercased()))
                }
                .buttonStyle(.borderless)
                ForEach(shield.config.allowlist, id: \.self) { d in
                    Label(d, systemImage: "checkmark.shield").foregroundStyle(.green)
                }
                .onDelete { shield.removeAllowed(at: $0) }
                ForEach(shield.config.customBlocked, id: \.self) { d in
                    Label(d, systemImage: "xmark.shield").foregroundStyle(.red)
                }
                .onDelete { shield.removeCustomBlocked(at: $0) }
            } header: {
                Text("Your Rules")
            } footer: {
                Text("If an app breaks, open Recent Activity and allow the domain it needs. Rules also cover subdomains.")
            }

            Section("Advanced") {
                Picker("Resolver", selection: Binding(get: { shield.upstream }, set: { shield.upstream = $0 })) {
                    ForEach(UpstreamDNS.allCases) { Text($0.name).tag($0) }
                }
                Picker("Blocked lookups get", selection: Binding(get: { shield.blockMode }, set: { shield.blockMode = $0 })) {
                    Text("0.0.0.0 (fastest)").tag(BlockMode.nullIP)
                    Text("No such domain").tag(BlockMode.nxdomain)
                }
                Button("Reset Statistics", role: .destructive) { shield.resetStats() }
            }

            Section {
                Text("""
                Shield works as a local VPN that only carries DNS lookups. Lookups for ad and tracker domains are answered on your iPhone and never leave it. Everything else goes straight to your chosen resolver. Your browsing traffic does not pass through the tunnel and never reaches Switchboard.

                You can't run another VPN at the same time. If blocking stops on a network, turn off Settings → Cellular → Connectivity Assist (iOS 27).
                """)
                .font(.footnote)
                .foregroundStyle(.secondary)
            } header: {
                Text("How it works")
            }
        }
        .scrollContentBackground(.hidden)
        .moduleBackground(ModuleID.shield.tint)
        .task {
            await shield.refresh()
            while !Task.isCancelled {
                await shield.reloadStats()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .refreshable { await shield.reloadStats() }
        .sheet(isPresented: $showLog) { ShieldLogView() }
        .alert("Shield", isPresented: Binding(get: { shield.errorMessage != nil },
                                              set: { if !$0 { shield.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(shield.errorMessage ?? "") }
    }

    private var powerCard: some View {
        VStack(spacing: 14) {
            Button {
                Haptics.tap()
                Task { await shield.toggle() }
            } label: {
                Image(systemName: shield.isOn ? "shield.lefthalf.filled" : "shield.slash")
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(shield.isOn ? .white : .secondary)
                    .frame(width: 120, height: 120)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.pulse, isActive: shield.status == .connecting)
            }
            .buttonStyle(.plain)
            .glassEffect(shield.isOn ? Glass.regular.tint(.green).interactive() : Glass.regular.interactive(), in: .circle)
            .accessibilityLabel(shield.isOn ? "Turn Shield off" : "Turn Shield on")

            Text(shield.statusText)
                .font(.headline)
                .contentTransition(.opacity)
            if !shield.isInstalled {
                Text("iOS will ask you to allow a VPN configuration the first time.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .animation(.smooth, value: shield.status)
    }
}

private struct ShieldLogView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable { case all = "All", blocked = "Blocked", allowed = "Allowed" }

    var body: some View {
        NavigationStack {
            List {
                Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                ForEach(entries) { entry in
                    HStack {
                        Image(systemName: entry.blocked ? "xmark.shield.fill" : "checkmark.circle")
                            .foregroundStyle(entry.blocked ? .red : .green)
                        VStack(alignment: .leading) {
                            Text(entry.domain).font(.subheadline.monospaced()).lineLimit(1)
                            Text(entry.date, style: .time).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        if entry.blocked {
                            Button("Allow") { app.shield.allow(entry.domain) }.tint(.green)
                        } else {
                            Button("Block") { app.shield.block(entry.domain) }.tint(.red)
                        }
                    }
                }
            }
            .navigationTitle("Recent Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView("No lookups yet", systemImage: "network",
                                           description: Text("Turn the Shield on and use your phone as normal."))
                }
            }
        }
    }

    private var entries: [ShieldStats.Entry] {
        switch filter {
        case .all: app.shield.stats.recent
        case .blocked: app.shield.stats.recent.filter(\.blocked)
        case .allowed: app.shield.stats.recent.filter { !$0.blocked }
        }
    }
}
