import AppIntents
import Shared
import WidgetKit

enum ZoomOption: String, AppEnum {
    case appSetting
    case miles40
    case miles80
    case miles160

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Zoom"
    static let caseDisplayRepresentations: [ZoomOption: DisplayRepresentation] = [
        .appSetting: "Same as app",
        .miles40: "40 miles",
        .miles80: "80 miles",
        .miles160: "160 miles",
    ]

    /// The tile width to use; "Same as app" reads the app's zoom picker.
    func resolved(store: SharedStore) -> ZoomLevel {
        switch self {
        case .appSetting: store.zoom
        case .miles40: .miles40
        case .miles80: .miles80
        case .miles160: .miles160
        }
    }
}

struct RadarConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Radar"
    static let description = IntentDescription("Live weather radar around your location.")

    @Parameter(title: "Zoom", default: .appSetting)
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
