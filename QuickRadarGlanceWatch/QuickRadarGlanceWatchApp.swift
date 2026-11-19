import Shared
import SwiftUI

@main
struct QuickRadarGlanceWatchApp: App {
    /// The watch has no App Group with the phone; it keeps its own settings.
    @State private var radarLoop = RadarLoopModel(store: SharedStore(defaults: .standard))

    var body: some Scene {
        WindowGroup {
            WatchRadarView()
                .environment(radarLoop)
        }
    }
}
