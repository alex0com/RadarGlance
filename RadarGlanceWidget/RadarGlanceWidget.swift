import SwiftUI
import WidgetKit

@main
struct RadarGlanceWidgetBundle: WidgetBundle {
    var body: some Widget {
        RadarWidget()
    }
}

struct RadarWidget: Widget {
    static let kind = "RadarWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: RadarConfigurationIntent.self,
                               provider: RadarTimelineProvider()) { entry in
            RadarWidgetView(entry: entry)
        }
        .configurationDisplayName("Radar")
        .description("Live NOAA weather radar centered on you.")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
        // CarPlay hides removable backgrounds, which would hide the radar.
        .containerBackgroundRemovable(false)
    }
}
