import CoreGraphics
import ImageIO
import UIKit

/// Loads a square composite sized for a widget.
///
/// WidgetKit refuses to archive images much larger than the widget, and a full decode of a
/// 1024 px PNG costs 4 MB. ImageIO decodes directly at the needed size, then the image is
/// center-cropped to the widget's aspect ratio (what `.fill` would show anyway).
public enum WidgetImage {
    /// - Parameters:
    ///   - displaySize: The widget's size in points.
    ///   - scale: Screen scale (pixels per point).
    public static func load(contentsOf url: URL, displaySize: CGSize, scale: CGFloat) -> UIImage? {
        guard displaySize.width > 0, displaySize.height > 0,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return nil }

        let target = CGSize(width: (displaySize.width * scale).rounded(.up),
                            height: (displaySize.height * scale).rounded(.up))
        // The square must cover the widget's longer side.
        let side = max(target.width, target.height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let square = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let cropped = square.cropping(to: cropRect(imageSide: CGFloat(square.width), aspect: target.width / target.height)) ?? square
        return UIImage(cgImage: cropped)
    }

    /// The centered rect of a square image with the given width/height ratio.
    public static func cropRect(imageSide: CGFloat, aspect: CGFloat) -> CGRect {
        if aspect >= 1 {
            let height = (imageSide / aspect).rounded()
            return CGRect(x: 0, y: ((imageSide - height) / 2).rounded(), width: imageSide, height: height)
        } else {
            let width = (imageSide * aspect).rounded()
            return CGRect(x: ((imageSide - width) / 2).rounded(), y: 0, width: width, height: imageSide)
        }
    }
}
