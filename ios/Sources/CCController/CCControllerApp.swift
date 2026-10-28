import SwiftUI

@main
struct CCControllerApp: App {
    @State private var model: AppModel

    init() {
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            MockGate {
                RootView(model: model)
            }
            .preferredColorScheme(model.colorScheme)
            .environment(\.ccFreezeLiveIndicators, model.freezeLiveIndicators)
            #else
            RootView(model: model)
                .preferredColorScheme(model.colorScheme)
            #endif
        }
    }
}
