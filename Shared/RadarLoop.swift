import CoreGraphics
import CoreLocation
import Foundation
import MapKit

/// How far back the app's radar animation goes.
public enum LoopLength: Int, CaseIterable, Codable, Sendable, Identifiable {
    case minutes30 = 30
    case hour1 = 60
    case hours2 = 120

    public static let defaultValue = LoopLength.hour1

    public var id: Int { rawValue }
    public var duration: TimeInterval { TimeInterval(rawValue) * 60 }

    /// Spacing between frames. NOAA publishes about every 2 min; these keep the loop at
    /// 8–13 frames so each map move costs about a dozen requests.
    public var step: TimeInterval {
        switch self {
        case .minutes30: 4 * 60
        case .hour1: 6 * 60
        case .hours2: 10 * 60
        }
    }

    public var label: String {
        switch self {
        case .minutes30: "30 min"
        case .hour1: "1 hr"
        case .hours2: "2 hr"
        }
    }
}

/// The app's animated radar viewer: which frames to show, and what area to request.
/// One GetMap per frame covers the visible area plus a margin, so every frame lines up.
public enum RadarLoop {
    /// Extra area requested on each side, as a fraction of the visible width/height, so small
    /// pans don't need new frames.
    public static let padding = 0.25
    /// Longest side of a frame image, in pixels.
    public static let maxPixels = 1536
    /// Zooming in or out by more than this factor since the last load needs new frames.
    public static let maxZoomChange = 1.5

    /// Frames for `length`, oldest first: the newest listed time, then the listed time nearest
    /// each `step` before it. Only listed times are returned; a made-up TIME gives a blank PNG.
    public static func selectFrames(from times: [RadarTime], length: LoopLength) -> [RadarTime] {
        guard let newest = times.max(by: { $0.date < $1.date }) else { return [] }
        let count = Int(length.duration / length.step)
        var picked: [RadarTime] = []
        for index in 0...count {
            let target = newest.date.addingTimeInterval(-Double(index) * length.step)
            guard let nearest = times.min(by: {
                abs($0.date.timeIntervalSince(target)) < abs($1.date.timeIntervalSince(target))
            }), abs(nearest.date.timeIntervalSince(target)) <= length.step / 2,
                !picked.contains(nearest)
            else { continue }
            picked.append(nearest)
        }
        return picked.sorted { $0.date < $1.date }
    }

    /// The part of `visible` that has radar coverage, or nil if none of it does.
    public static func coveredRect(visible: MKMapRect, region: RadarRegion) -> MKMapRect? {
        let rect = visible.intersection(region.mapRect)
        return rect.isNull || rect.isEmpty ? nil : rect
    }

    /// The area to request: `visible` with `padding` on each side, clipped to the region.
    public static func requestRect(visible: MKMapRect, region: RadarRegion) -> MKMapRect? {
        coveredRect(visible: visible.insetBy(dx: -visible.width * padding, dy: -visible.height * padding),
                    region: region)
    }

    /// Image size for `rect` at the screen's resolution (`visible` spans `viewPixels`),
    /// scaled down so the longest side is at most `maxPixels`.
    public static func pixelSize(for rect: MKMapRect, visible: MKMapRect, viewPixels: CGSize) -> (width: Int, height: Int) {
        let perPoint = viewPixels.width / visible.width
        var width = rect.width * perPoint
        var height = rect.height * perPoint
        let longest = max(width, height)
        if longest > Double(maxPixels) {
            width *= Double(maxPixels) / longest
            height *= Double(maxPixels) / longest
        }
        return (max(1, Int(width.rounded())), max(1, Int(height.rounded())))
    }

    /// Whether frames loaded for `loaded` still serve the map showing `visible`: they cover
    /// its radar area and the zoom hasn't changed much (or they'd look blurry or wasteful).
    public static func needsReload(loaded: MKMapRect, loadedVisibleWidth: Double,
                                   visible: MKMapRect, region: RadarRegion) -> Bool {
        guard let covered = coveredRect(visible: visible, region: region) else { return false }
        let zoomChange = max(visible.width / loadedVisibleWidth, loadedVisibleWidth / visible.width)
        return !loaded.contains(covered) || zoomChange > maxZoomChange
    }
}

extension RadarRegion {
    /// The coverage box in MapKit map points.
    public var mapRect: MKMapRect {
        let northWest = MKMapPoint(CLLocationCoordinate2D(latitude: north, longitude: west))
        let southEast = MKMapPoint(CLLocationCoordinate2D(latitude: south, longitude: east))
        return MKMapRect(x: northWest.x, y: northWest.y,
                         width: southEast.x - northWest.x, height: southEast.y - northWest.y)
    }
}
