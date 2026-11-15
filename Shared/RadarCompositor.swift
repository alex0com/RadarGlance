import MapKit
import UIKit

/// Draws base map + radar + user marker into one square PNG (512 or 1024 px).
///
/// The scale bar is drawn by SwiftUI (`ScaleBar`) so it stays correct when a widget crops the square.
///
/// Memory: everything goes into a single scale-1 bitmap that is encoded to PNG
/// immediately; no intermediate UIImages outlive the draw call.
public enum RadarCompositor {
    public static let radarOpacity: CGFloat = 0.75
    public static let backgroundColor = UIColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1)

    public struct Input: Sendable {
        public var baseMapPNG: Data?
        public var radarPNG: Data
        /// Area the radar image covers; usually larger than `box`.
        public var radarBox: MercatorBox
        /// Area of the composite.
        public var box: MercatorBox
        public var user: LocationFix?
        public var userIsStale: Bool
        public var size: Int

        public init(baseMapPNG: Data?, radarPNG: Data, radarBox: MercatorBox, box: MercatorBox, user: LocationFix?,
                    userIsStale: Bool, size: Int = TileResolution.standard.pixels) {
            self.baseMapPNG = baseMapPNG
            self.radarPNG = radarPNG
            self.radarBox = radarBox
            self.box = box
            self.user = user
            self.userIsStale = userIsStale
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
                if let radar = UIImage(data: input.radarPNG)?.cgImage {
                    let target = radarRect(radarBox: input.radarBox, tileBox: input.box, size: side)
                    let cg = context.cgContext
                    cg.saveGState()
                    // Enlarging: keep NOAA's 1 km cells crisp. Shrinking: smooth.
                    cg.interpolationQuality = target.width > CGFloat(radar.width) ? .none : .high
                    cg.setAlpha(radarOpacity)
                    // UIKit's context is flipped; draw the CGImage upright.
                    cg.translateBy(x: 0, y: side)
                    cg.scaleBy(x: 1, y: -1)
                    cg.draw(radar, in: CGRect(x: target.minX, y: side - target.maxY,
                                              width: target.width, height: target.height))
                    cg.restoreGState()
                }
            }

            if let user = input.user {
                let point = input.box.pixel(
                    for: MKMapPoint(CLLocationCoordinate2D(latitude: user.latitude, longitude: user.longitude)),
                    size: side)
                if rect.contains(point) {
                    drawMarker(at: point, course: user.course, stale: input.userIsStale,
                               scale: side / 512, in: context.cgContext)
                }
            }
        }
    }

    /// Where the radar image goes in a `size`×`size` composite of `tileBox` (origin top-left).
    public static func radarRect(radarBox: MercatorBox, tileBox: MercatorBox, size: CGFloat) -> CGRect {
        let scale = size / tileBox.width
        return CGRect(x: (radarBox.minX - tileBox.minX) * scale, y: (radarBox.minY - tileBox.minY) * scale,
                      width: radarBox.width * scale, height: radarBox.width * scale)
    }

    /// Sizes are in pixels of a 512 px tile, which the small widget shows at roughly 160 pt
    /// (1 pt ≈ 3.2 px); `scale` keeps the same on-screen size at 1024 px in larger widgets.
    private static func drawMarker(at point: CGPoint, course: Double?, stale: Bool, scale: CGFloat, in cg: CGContext) {
        let fill = stale ? UIColor.systemGray : UIColor.systemBlue
        cg.saveGState()
        cg.setShadow(offset: .zero, blur: 6 * scale, color: UIColor.black.withAlphaComponent(0.8).cgColor)

        if let course {
            cg.translateBy(x: point.x, y: point.y)
            cg.rotate(by: course * .pi / 180)
            cg.scaleBy(x: scale, y: scale)
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
            let dot = UIBezierPath(arcCenter: point, radius: 15 * scale, startAngle: 0, endAngle: .pi * 2, clockwise: true)
            UIColor.white.setFill()
            dot.fill()
            let inner = UIBezierPath(arcCenter: point, radius: 10 * scale, startAngle: 0, endAngle: .pi * 2, clockwise: true)
            fill.setFill()
            inner.fill()
        }
        cg.restoreGState()
    }
}
