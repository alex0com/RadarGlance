import SwiftUI

@main
struct RadarGlanceApp: App {
    @State private var model = AppModel()

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
        }
    }
}
