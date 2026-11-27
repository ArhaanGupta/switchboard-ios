import SwiftUI

@main
struct SwitchboardApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Must run before AppModel loads its stores.
        DemoData.seedIfRequested()
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(model)
                .onOpenURL { model.handle(url: $0) }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.appBecameActive() }
                }
        }
    }
}
