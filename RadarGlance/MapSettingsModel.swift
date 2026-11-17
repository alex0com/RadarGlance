import Observation
import Shared
import WidgetKit

/// The radar map's look, saved to the App Group as it changes.
@MainActor
@Observable
final class MapSettingsModel {
    var settings: MapSettings {
        didSet {
            guard settings != oldValue else { return }
            store.mapSettings = settings
            // The widget uses the radar source; everything else is the app's map only.
            if settings.radarSource != oldValue.radarSource {
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }

    private let store: SharedStore

    init(store: SharedStore = SharedStore()) {
        self.store = store
        settings = store.mapSettings
    }
}
