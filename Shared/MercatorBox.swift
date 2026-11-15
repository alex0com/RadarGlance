import CoreGraphics
import CoreLocation
import MapKit

/// A square region in Web Mercator, in MapKit map points, convertible to an EPSG:3857 BBOX.
///
/// MapKit map points and EPSG:3857 are both Web Mercator, so the conversion is linear:
/// map point x runs 0…world west→east, y runs 0…world north→south; EPSG:3857 runs
/// -R…+R in both axes with y pointing north.
public struct MercatorBox: Sendable, Equatable, Codable {
    /// `MKMapSize.world.width`, checked in tests.
    public static let worldWidth: Double = 268_435_456
    /// EPSG:3857 half-extent in meters.
    public static let halfExtent: Double = 20_037_508.342789244
    public static let metersPerMile: Double = 1_609.344

    public let minX: Double
    public let minY: Double
    public let width: Double

    public init(minX: Double, minY: Double, width: Double) {
        self.minX = minX
        self.minY = minY
        self.width = width
    }

    public init(mapRect: MKMapRect) {
        self.init(minX: mapRect.minX, minY: mapRect.minY, width: mapRect.width)
    }

    /// A square centered on `center`, `widthMiles` across at that latitude.
    public init(center: CLLocationCoordinate2D, widthMiles: Double) {
        let point = MKMapPoint(center)
        let width = widthMiles * Self.metersPerMile * MKMapPointsPerMeterAtLatitude(center.latitude)
        self.init(minX: point.x - width / 2, minY: point.y - width / 2, width: width)
    }

    public var maxX: Double { minX + width }
    public var maxY: Double { minY + width }
    public var center: MKMapPoint { MKMapPoint(x: minX + width / 2, y: minY + width / 2) }
    public var mapRect: MKMapRect { MKMapRect(x: minX, y: minY, width: width, height: width) }

    public static func toMeters(_ p: MKMapPoint) -> (x: Double, y: Double) {
        (x: (p.x / worldWidth) * 2 * halfExtent - halfExtent,
         y: halfExtent - (p.y / worldWidth) * 2 * halfExtent)
    }

    public static func toMapPoint(x: Double, y: Double) -> MKMapPoint {
        MKMapPoint(x: (x + halfExtent) / (2 * halfExtent) * worldWidth,
                   y: (halfExtent - y) / (2 * halfExtent) * worldWidth)
    }

    /// minX, minY, maxX, maxY in EPSG:3857 meters. Map-point maxY is the southern edge,
    /// so it becomes the meters minY.
    public var bboxMeters: (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        let southWest = Self.toMeters(MKMapPoint(x: minX, y: maxY))
        let northEast = Self.toMeters(MKMapPoint(x: maxX, y: minY))
        return (southWest.x, southWest.y, northEast.x, northEast.y)
    }

    public var bboxString: String {
        let b = bboxMeters
        return String(format: "%.3f,%.3f,%.3f,%.3f", b.minX, b.minY, b.maxX, b.maxY)
    }

    /// Position of `point` in an image of `size`×`size` pixels covering this box (origin top-left).
    public func pixel(for point: MKMapPoint, size: Double) -> CGPoint {
        CGPoint(x: (point.x - minX) / width * size, y: (point.y - minY) / width * size)
    }

    /// Whether `other` lies entirely inside this box.
    public func contains(_ other: MercatorBox) -> Bool {
        other.minX >= minX && other.minY >= minY && other.maxX <= maxX && other.maxY <= maxY
    }

    /// Whether `point` is within `fraction` of the box width from the box center, on both axes.
    public func isNearCenter(_ point: MKMapPoint, fraction: Double) -> Bool {
        let c = center
        return abs(point.x - c.x) <= width * fraction && abs(point.y - c.y) <= width * fraction
    }
}
