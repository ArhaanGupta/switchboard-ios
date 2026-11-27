import FamilyControls
import ManagedSettings
import SwiftUI
import SwitchboardCore

struct AppLockScreen: View {
    @Environment(AppModel.self) private var app
    @State private var showPicker = false
    @State private var draftSelection = FamilyActivitySelection()

    private var lock: AppLockModel { app.appLock }

    var body: some View {
        List {
            Section {
                hero
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }

            if let token = lock.pendingToken {
                Section {
                    HStack(spacing: 12) {
                        Label(token).labelStyle(.iconOnly).scaleEffect(1.4).frame(width: 44)
                        VStack(alignment: .leading) {
                            Label(token).labelStyle(.titleOnly).font(.headline)
                            Text("Waiting for Face ID").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    Button {
                        Task { await lock.unlockPending() }
                    } label: {
                        Label("Unlock for \(lock.unlockMinutes) minutes", systemImage: "faceid")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.indigo)
                    Button("Not now", role: .cancel) { lock.cancelPending() }
                        .frame(maxWidth: .infinity)
                } header: {
                    Text("Unlock request")
                }
            }

            if !lock.isAuthorized || !lock.notificationsAllowed {
                Section("Setup") {
                    SetupStep(title: "Allow Screen Time access",
                              detail: "iOS enforces the lock itself. Switchboard never sees which apps you open or how long you use them.",
                              done: lock.isAuthorized,
                              actionTitle: "Allow") { Task { await lock.requestAuthorization() } }
                    SetupStep(title: "Allow notifications",
                              detail: "Tapping Unlock on a locked app sends a notification that brings you here for Face ID.",
                              done: lock.notificationsAllowed,
                              actionTitle: "Allow") { Task { await lock.requestNotifications() } }
                }
            }

            Section {
                Button {
                    Task {
                        guard await lock.authenticateToEdit() else { return }
                        draftSelection = lock.selection
                        showPicker = true
                    }
                } label: {
                    Label(lock.lockedCount == 0 ? "Choose Apps to Lock" : "Edit Locked Apps",
                          systemImage: "square.grid.3x3.square")
                }
                .disabled(!lock.isAuthorized)

                ForEach(Array(lock.selection.applicationTokens), id: \.self) { token in
                    Label(token)
                }
                ForEach(Array(lock.selection.categoryTokens), id: \.self) { token in
                    Label(token)
                }
                ForEach(Array(lock.selection.webDomainTokens), id: \.self) { token in
                    Label(token)
                }
            } header: {
                Text("Locked")
            } footer: {
                Text("Changing this list asks for Face ID, so nobody can quietly remove a lock.")
            }

            Section {
                Picker("Stay unlocked for", selection: Binding(get: { lock.unlockMinutes },
                                                               set: { lock.setUnlockMinutes($0) })) {
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                    Text("2 hours").tag(120)
                }
                if !lock.activeGrants.isEmpty {
                    ForEach(lock.activeGrants, id: \.self) { grant in
                        HStack {
                            Label(grant.token)
                            Spacer()
                            Text(grant.until, style: .timer)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("Lock Everything Now", systemImage: "lock.fill", role: .destructive) { lock.relockAll() }
                }
            } header: {
                Text("Unlocking")
            } footer: {
                Text("iOS re-locks apps automatically when the time is up. The shortest window iOS allows is 15 minutes.")
            }

            Section {
                Text("App Lock uses Apple's Screen Time frameworks. The lock screen, the timers and the re-locking are all run by iOS, so Switchboard does no background work and uses no battery while apps are locked.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("How it works")
            }
        }
        .scrollContentBackground(.hidden)
        .moduleBackground(ModuleID.appLock.tint)
        .familyActivityPicker(isPresented: $showPicker, selection: $draftSelection)
        .onChange(of: showPicker) { _, open in
            if !open { lock.setSelection(draftSelection) }
        }
        .onAppear { lock.reload() }
        .task(id: lock.pendingToken) {
            // Arriving from the unlock notification: go straight to Face ID.
            if lock.pendingToken != nil { await lock.unlockPending() }
        }
        .alert("App Lock", isPresented: Binding(get: { lock.errorMessage != nil },
                                                set: { if !$0 { lock.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(lock.errorMessage ?? "") }
    }

    private var hero: some View {
        VStack(spacing: 12) {
            Image(systemName: lock.lockedCount > 0 && lock.isAuthorized ? "lock.fill" : "lock.open")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(lock.lockedCount > 0 && lock.isAuthorized ? .white : .secondary)
                .frame(width: 104, height: 104)
                .contentTransition(.symbolEffect(.replace))
                .glassEffect(lock.lockedCount > 0 && lock.isAuthorized ? Glass.regular.tint(.indigo) : Glass.regular,
                             in: .circle)
            Text(lock.statusText).font(.headline)
            Text("Face ID on any app, like App Lock on Android.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}
