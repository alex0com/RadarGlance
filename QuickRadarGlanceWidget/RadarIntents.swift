import AppIntents
import Shared
import WidgetKit

enum ZoomOption: String, AppEnum {
    case automatic
    case miles40
    case miles80
    case miles160

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Zoom"
    static let caseDisplayRepresentations: [ZoomOption: DisplayRepresentation] = [
        .automatic: DisplayRepresentation(title: "Automatic",
                                          subtitle: "Small: CarPlay zoom. Larger: iPhone zoom."),
        .miles40: "40 miles",
        .miles80: "80 miles",
        .miles160: "160 miles",
    ]

    /// Automatic uses the app's CarPlay zoom for small widgets (the only size CarPlay shows;
    /// WidgetKit doesn't say whether a widget is in CarPlay) and the iPhone zoom otherwise.
    func resolved(store: SharedStore, family: WidgetFamily) -> ZoomLevel {
        switch self {
        case .automatic: family == .systemSmall ? store.carZoom : store.phoneZoom
        case .miles40: .miles40
        case .miles80: .miles80
        case .miles160: .miles160
        }
    }
}

struct RadarConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Radar"
    static let description = IntentDescription("Live weather radar around your location.")

    @Parameter(title: "Zoom", default: .automatic)
    var zoom: ZoomOption
}

/// Records a refresh request; the system then reloads the widget, and the timeline provider
/// does the actual fetch.
struct RefreshRadarIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh Radar"
    static let isDiscoverable = false
    static let openAppWhenRun = false

    /// Taps this soon after a successful refresh are ignored.
    static let minimumInterval: TimeInterval = 30

    func perform() async throws -> some IntentResult {
        let store = SharedStore()
        let now = Date()
        if let last = store.lastSuccessfulRefresh, now.timeIntervalSince(last) < Self.minimumInterval {
            return .result()
        }
        store.forceRefreshRequestedAt = now
        return .result()
    }
}
