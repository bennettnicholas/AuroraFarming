import SwiftUI

@main
struct AuroraApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        AppModel.registerBackgroundSync { model }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(model.connectors)
                .preferredColorScheme(.dark)
                .tint(Theme.mint)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                model.didBecomeActive()
            case .background:
                model.didEnterBackground()
                AppModel.scheduleBackgroundSync()
            default:
                break
            }
        }
    }
}
