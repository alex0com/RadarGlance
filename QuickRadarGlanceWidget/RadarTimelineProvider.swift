import Shared
import UIKit
import WidgetKit

struct RadarEntry: TimelineEntry {
    let date: Date
    let image: UIImage?
    let metadata: RadarMetadata?
    let failure: RadarFailure?
    let isPlaceholder: Bool
    /// Temperature and humidity, when the setting is on and NWS had data.
    var conditions: WeatherConditions?

    static func placeholder(date: Date = Date()) -> RadarEntry {
        RadarEntry(date: date, image: nil, metadata: nil, failure: nil, isPlaceholder: true)
    }
}

struct RadarTimelineProvider: AppIntentTimelineProvider {
    static let reloadInterval: TimeInterval = 5 * 60

    func placeholder(in context: Context) -> RadarEntry {
        .placeholder()
    }

    func snapshot(for configuration: RadarConfigurationIntent, in context: Context) async -> RadarEntry {
        let zoom = configuration.zoom.resolved(store: SharedStore(), family: context.family)
        let snapshot = await MainActor.run { makePipeline() }
            .cachedSnapshot(zoom: zoom, resolution: Self.resolution(for: context.family))
        guard var entry = entry(from: snapshot, date: Date(), context: context) else { return .placeholder() }
        let store = SharedStore()
        if store.showsWidgetWeather, let cached = store.weatherConditions, !cached.isStale(now: Date()) {
            entry.conditions = cached
        }
        return entry
    }

    func timeline(for configuration: RadarConfigurationIntent, in context: Context) async -> Timeline<RadarEntry> {
        let store = SharedStore()
        let now = Date()
        let force = store.consumeForceRefreshRequest(now: now)
        let pipeline = await MainActor.run { makePipeline() }
        let snapshot = await pipeline.refresh(force: force, zoom: configuration.zoom.resolved(store: store, family: context.family),
                                              resolution: Self.resolution(for: context.family))

        var current = entry(from: snapshot, date: now, context: context) ?? .placeholder(date: now)
        if store.showsWidgetWeather, let metadata = snapshot.metadata {
            current.conditions = await WeatherService(store: store)
                .conditions(latitude: metadata.latitude, longitude: metadata.longitude, force: force)
        }
        // Extra entries with the same image so the time label turns amber/red on schedule
        // even if the system delays the next reload.
        var entries = [current]
        if let time = current.metadata?.displayTime {
            for threshold in [RadarAge.amberAfter, RadarAge.redAfter] {
                let date = time.addingTimeInterval(threshold)
                if date > now {
                    entries.append(RadarEntry(date: date, image: current.image, metadata: current.metadata,
                                              failure: current.failure, isPlaceholder: false,
                                              conditions: current.conditions))
                }
            }
        }
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(Self.reloadInterval)))
    }

    /// The small widget (the only size CarPlay shows) stays at 512 px for memory.
    static func resolution(for family: WidgetFamily) -> TileResolution {
        family == .systemSmall ? .standard : .high
    }

    @MainActor
    private func makePipeline() -> RadarPipeline {
        RadarPipeline.live(location: LocationService(), processName: "widget")
    }

    private func entry(from snapshot: RadarSnapshot, date: Date, context: Context) -> RadarEntry? {
        let image = snapshot.imageURL.flatMap {
            WidgetImage.load(contentsOf: $0, displaySize: context.displaySize, scale: Self.displayScale)
        }
        if image == nil && snapshot.failure == nil { return nil }
        return RadarEntry(date: date, image: image, metadata: snapshot.metadata,
                          failure: snapshot.failure, isPlaceholder: false)
    }

    /// Pixels per point. Extensions get no screen object; the trait collection reports the
    /// device's scale, and 3 (every current iPhone) covers the case where it doesn't.
    private static var displayScale: CGFloat {
        let scale = UITraitCollection.current.displayScale
        return scale >= 1 ? scale : 3
    }
}
