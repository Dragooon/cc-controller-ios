import CCKit
import SwiftUI

@main
struct CCControllerApp: App {
    @State private var model: AppModel
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.initial

    init() {
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            MockGate {
                RootView(model: model)
                    .background(MotionTraceRootProbe())
            }
            .preferredColorScheme(model.colorScheme ?? appearance.colorScheme)
            .environment(\.ccFreezeLiveIndicators, model.freezeLiveIndicators)
            #else
            RootView(model: model)
                .preferredColorScheme(model.colorScheme ?? appearance.colorScheme)
            #endif
        }
    }
}
