import Shared
import UIKit
import WidgetKit

struct RadarEntry: TimelineEntry {
    let date: Date
    let image: UIImage?
    let metadata: RadarMetadata?
    let failure: RadarFailure?
    let isPlaceholder: Bool

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
        let zoom = configuration.zoom.resolved(store: SharedStore())
        let snapshot = await MainActor.run { makePipeline() }.cachedSnapshot(zoom: zoom)
        return entry(from: snapshot, date: Date()) ?? .placeholder()
    }

    func timeline(for configuration: RadarConfigurationIntent, in context: Context) async -> Timeline<RadarEntry> {
        let store = SharedStore()
        let now = Date()
        let force = store.consumeForceRefreshRequest(now: now)
        let pipeline = await MainActor.run { makePipeline() }
        let snapshot = await pipeline.refresh(force: force, zoom: configuration.zoom.resolved(store: store))

        let current = entry(from: snapshot, date: now) ?? .placeholder(date: now)
        // Extra entries with the same image so the time label turns amber/red on schedule
        // even if the system delays the next reload.
        var entries = [current]
        if let time = current.metadata?.displayTime {
            for threshold in [RadarAge.amberAfter, RadarAge.redAfter] {
                let date = time.addingTimeInterval(threshold)
                if date > now {
                    entries.append(RadarEntry(date: date, image: current.image, metadata: current.metadata,
                                              failure: current.failure, isPlaceholder: false))
                }
            }
        }
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(Self.reloadInterval)))
    }

    @MainActor
    private func makePipeline() -> RadarPipeline {
        RadarPipeline.live(location: LocationService(), processName: "widget")
    }

    private func entry(from snapshot: RadarSnapshot, date: Date) -> RadarEntry? {
        let image = snapshot.imageURL.flatMap { UIImage(contentsOfFile: $0.path) }
        if image == nil && snapshot.failure == nil { return nil }
        return RadarEntry(date: date, image: image, metadata: snapshot.metadata,
                          failure: snapshot.failure, isPlaceholder: false)
    }
}
