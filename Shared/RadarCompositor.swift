import MapKit
import UIKit

/// Draws base map + radar + user marker + scale bar into one 512×512 PNG.
///
/// Memory: everything goes into a single scale-1 bitmap that is encoded to PNG
/// immediately; no intermediate UIImages outlive the draw call.
public enum RadarCompositor {
    public static let radarOpacity: CGFloat = 0.75
    public static let backgroundColor = UIColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1)

    public struct Input: Sendable {
        public var baseMapPNG: Data?
        public var radarPNG: Data
        public var box: MercatorBox
        public var user: LocationFix?
        public var userIsStale: Bool
        public var zoom: ZoomLevel
        public var size: Int

        public init(baseMapPNG: Data?, radarPNG: Data, box: MercatorBox, user: LocationFix?,
                    userIsStale: Bool, zoom: ZoomLevel, size: Int = RadarClient.imageSize) {
            self.baseMapPNG = baseMapPNG
            self.radarPNG = radarPNG
            self.box = box
            self.user = user
            self.userIsStale = userIsStale
            self.zoom = zoom
            self.size = size
        }
    }

    public static func compose(_ input: Input) -> Data {
        let side = CGFloat(input.size)
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: rect.size, format: format)

        return renderer.pngData { context in
            backgroundColor.setFill()
            context.fill(rect)

            autoreleasepool {
                if let data = input.baseMapPNG, let base = UIImage(data: data) {
                    base.draw(in: rect)
                }
            }
            autoreleasepool {
                if let radar = UIImage(data: input.radarPNG) {
                    radar.draw(in: rect, blendMode: .normal, alpha: radarOpacity)
                }
            }

            if let user = input.user {
                let point = input.box.pixel(
                    for: MKMapPoint(CLLocationCoordinate2D(latitude: user.latitude, longitude: user.longitude)),
                    size: side)
                if rect.contains(point) {
                    drawMarker(at: point, course: user.course, stale: input.userIsStale, in: context.cgContext)
                }
            }

            drawScaleBar(zoom: input.zoom, side: side)
        }
    }

    // Sizes are in pixels of the 512 px tile, which is shown at roughly 160 pt,
    // so 1 pt ≈ 3.2 px.

    private static func drawMarker(at point: CGPoint, course: Double?, stale: Bool, in cg: CGContext) {
        let fill = stale ? UIColor.systemGray : UIColor.systemBlue
        cg.saveGState()
        cg.setShadow(offset: .zero, blur: 6, color: UIColor.black.withAlphaComponent(0.8).cgColor)

        if let course {
            cg.translateBy(x: point.x, y: point.y)
            cg.rotate(by: course * .pi / 180)
            let arrow = UIBezierPath()
            arrow.move(to: CGPoint(x: 0, y: -26))
            arrow.addLine(to: CGPoint(x: 17, y: 18))
            arrow.addLine(to: CGPoint(x: 0, y: 9))
            arrow.addLine(to: CGPoint(x: -17, y: 18))
            arrow.close()
            arrow.lineJoinStyle = .round
            arrow.lineWidth = 5
            UIColor.white.setStroke()
            fill.setFill()
            arrow.stroke()
            arrow.fill()
        } else {
            let dot = UIBezierPath(arcCenter: point, radius: 15, startAngle: 0, endAngle: .pi * 2, clockwise: true)
            UIColor.white.setFill()
            dot.fill()
            let inner = UIBezierPath(arcCenter: point, radius: 10, startAngle: 0, endAngle: .pi * 2, clockwise: true)
            fill.setFill()
            inner.fill()
        }
        cg.restoreGState()
    }

    /// A bar a quarter of the tile wide, bottom-right (bottom-left holds the time label,
    /// top-right the refresh button).
    private static func drawScaleBar(zoom: ZoomLevel, side: CGFloat) {
        let barMiles = zoom.rawValue / 4
        let barLength = side / 4
        let margin: CGFloat = 22
        let y = side - margin
        let x1 = side - margin
        let x0 = x1 - barLength

        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.9)
        shadow.shadowBlurRadius = 4

        let bar = UIBezierPath()
        bar.move(to: CGPoint(x: x0, y: y - 10))
        bar.addLine(to: CGPoint(x: x0, y: y))
        bar.addLine(to: CGPoint(x: x1, y: y))
        bar.addLine(to: CGPoint(x: x1, y: y - 10))
        bar.lineWidth = 4
        bar.lineCapStyle = .round
        bar.lineJoinStyle = .round
        UIColor.black.withAlphaComponent(0.6).setStroke()
        bar.lineWidth = 8
        bar.stroke()
        UIColor.white.setStroke()
        bar.lineWidth = 4
        bar.stroke()

        let label = "\(barMiles) mi" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 26, weight: .semibold),
            .foregroundColor: UIColor.white,
            .shadow: shadow,
        ]
        let textSize = label.size(withAttributes: attributes)
        label.draw(at: CGPoint(x: x1 - textSize.width, y: y - 12 - textSize.height), withAttributes: attributes)
    }
}
