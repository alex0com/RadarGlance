import MapKit
import Shared
import SwiftUI

/// Where map points land in the map view. The map is flat and doesn't rotate, so this is a scale
/// and an offset, taken from where the map puts the corners of the visible area.
struct MapTransform: Equatable {
    /// The map point at the view's top-left corner.
    let origin: MKMapPoint
    let pointsPerMapPoint: Double

    init?(proxy: MapProxy, visible: MKMapRect) {
        guard let topLeft = proxy.convert(MKMapPoint(x: visible.minX, y: visible.minY).coordinate, to: .local),
              let bottomRight = proxy.convert(MKMapPoint(x: visible.maxX, y: visible.maxY).coordinate, to: .local),
              bottomRight.x > topLeft.x
        else { return nil }
        pointsPerMapPoint = (bottomRight.x - topLeft.x) / visible.width
        origin = MKMapPoint(x: visible.minX - topLeft.x / pointsPerMapPoint,
                            y: visible.minY - topLeft.y / pointsPerMapPoint)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.origin.x == rhs.origin.x && lhs.origin.y == rhs.origin.y && lhs.pointsPerMapPoint == rhs.pointsPerMapPoint
    }

    func point(_ mapPoint: MKMapPoint) -> CGPoint {
        CGPoint(x: (mapPoint.x - origin.x) * pointsPerMapPoint, y: (mapPoint.y - origin.y) * pointsPerMapPoint)
    }

    func rect(_ mapRect: MKMapRect) -> CGRect {
        let topLeft = point(MKMapPoint(x: mapRect.minX, y: mapRect.minY))
        return CGRect(x: topLeft.x, y: topLeft.y,
                      width: mapRect.width * pointsPerMapPoint, height: mapRect.height * pointsPerMapPoint)
    }

    /// The map area a view of `size` shows.
    func visibleRect(in size: CGSize) -> MKMapRect {
        MKMapRect(x: origin.x, y: origin.y, width: size.width / pointsPerMapPoint, height: size.height / pointsPerMapPoint)
    }
}

/// The bundled highway lines in map points, with each line's bounds for skipping off-screen lines.
final class HighwayGeometry: Sendable {
    struct Line: Sendable {
        let points: [MKMapPoint]
        let bounds: MKMapRect
    }

    let freeways: [Line]
    let interstates: [Line]

    private init(freeways: [Line], interstates: [Line]) {
        self.freeways = freeways
        self.interstates = interstates
    }

    func lines(_ highwayClass: HighwayClass) -> [Line] {
        highwayClass == .interstate ? interstates : freeways
    }

    /// Nil if the resource is missing or unreadable. Slow; call off the main thread.
    static func loadBundled() -> HighwayGeometry? {
        guard let url = Bundle.main.url(forResource: "highways", withExtension: "bin"),
              let data = try? Data(contentsOf: url),
              let lines = try? HighwayData.parse(data)
        else { return nil }
        var freeways: [Line] = [], interstates: [Line] = []
        for line in lines where line.coordinates.count > 1 {
            let points = line.coordinates.map(MKMapPoint.init)
            var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
            for point in points {
                minX = min(minX, point.x); maxX = max(maxX, point.x)
                minY = min(minY, point.y); maxY = max(maxY, point.y)
            }
            let geometry = Line(points: points, bounds: MKMapRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
            switch line.highwayClass {
            case .interstate: interstates.append(geometry)
            case .freeway: freeways.append(geometry)
            }
        }
        return HighwayGeometry(freeways: freeways, interstates: interstates)
    }
}

/// Highway lines over the radar, styled like the phone's. They also give the radar landmarks when
/// the map's own tiles don't load.
struct HighwayLayer: View, Equatable {
    let geometry: HighwayGeometry
    let transform: MapTransform

    /// Points closer together than this on screen are skipped, so zoomed-out lines stay cheap.
    static let minimumStep: CGFloat = 1

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.geometry === rhs.geometry && lhs.transform == rhs.transform
    }

    var body: some View {
        Canvas { context, size in
            let visible = transform.visibleRect(in: size)
            let latitude = MKMapPoint(x: visible.midX, y: visible.midY).coordinate.latitude
            let miles = visible.width * MKMetersPerMapPointAtLatitude(latitude) / MercatorBox.metersPerMile
            let detail = HighwayDetail(visibleMiles: miles)
            // A little extra, so lines crossing the edge aren't cut short.
            let area = visible.insetBy(dx: -visible.width * 0.05, dy: -visible.height * 0.05)

            // Freeways under interstates, and all casings under all lines, as on the phone.
            let layers: [(width: CGFloat, path: Path, color: Color)] = [HighwayClass.freeway, .interstate].compactMap {
                let width = detail.lineWidth(for: $0)
                guard width > 0 else { return nil }
                let color: Color = $0 == .interstate ? .white.opacity(0.95) : Color(white: 0.88).opacity(0.85)
                return (width, path(for: geometry.lines($0), in: area), color)
            }
            if detail.showsCasing {
                for layer in layers {
                    context.stroke(layer.path, with: .color(.black.opacity(0.5)),
                                   style: Self.stroke(width: layer.width + HighwayDetail.casingExtraWidth))
                }
            }
            for layer in layers {
                context.stroke(layer.path, with: .color(layer.color.opacity(detail.lineOpacity)),
                               style: Self.stroke(width: layer.width))
            }
        }
        .allowsHitTesting(false)
    }

    private func path(for lines: [HighwayGeometry.Line], in area: MKMapRect) -> Path {
        var path = Path()
        for line in lines where line.bounds.intersects(area) {
            var last = transform.point(line.points[0])
            path.move(to: last)
            for mapPoint in line.points.dropFirst() {
                let point = transform.point(mapPoint)
                guard abs(point.x - last.x) + abs(point.y - last.y) >= Self.minimumStep else { continue }
                path.addLine(to: point)
                last = point
            }
            // Short lines whose points all fell within one step still get their end.
            if let end = line.points.last.map(transform.point), end != last { path.addLine(to: end) }
        }
        return path
    }

    private static func stroke(width: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
    }
}
