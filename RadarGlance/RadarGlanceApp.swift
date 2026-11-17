import SwiftUI

@main
struct RadarGlanceApp: App {
    @State private var model = AppModel()
    @State private var radarLoop = RadarLoopModel()
    @State private var mapSettings = MapSettingsModel()

    var body: some Scene {
        WindowGroup {
            Group {
                if model.needsOnboarding {
                    OnboardingView()
                } else {
                    MainView()
                }
            }
            .environment(model)
            .environment(radarLoop)
            .environment(mapSettings)
        }
    }
}
