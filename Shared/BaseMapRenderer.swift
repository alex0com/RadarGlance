import MapKit
import UIKit

public struct BaseMap: Sendable {
    public let png: Data
    /// Largest distance, in pixels, between where the box corners should be and where the
    /// snapshot actually put them. Should be well under 1 px.
    public let alignmentErrorPixels: Double
}

public protocol BaseMapRendering: Sendable {
    func render(box: MercatorBox, size: Int) async throws -> BaseMap
}

public enum BaseMapError: Error {
    case encodingFailed
}

/// Dark, muted Apple Maps snapshot covering exactly `box`.
public struct BaseMapRenderer: BaseMapRendering {
    public init() {}

    @MainActor
    public func render(box: MercatorBox, size: Int) async throws -> BaseMap {
        let options = MKMapSnapshotter.Options()
        options.mapRect = box.mapRect
        options.size = CGSize(width: size, height: size)
        options.traitCollection = UITraitCollection { traits in
            traits.userInterfaceStyle = .dark
            traits.displayScale = 1
        }
        let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        configuration.pointOfInterestFilter = .excludingAll
        configuration.showsTraffic = false
        options.preferredConfiguration = configuration

        let snapshot = try await MKMapSnapshotter(options: options).start()

        let corners = [
            (MKMapPoint(x: box.minX, y: box.minY), CGPoint(x: 0, y: 0)),
            (MKMapPoint(x: box.maxX, y: box.maxY), CGPoint(x: size, y: size)),
        ]
        let error = corners.map { point, expected in
            let actual = snapshot.point(for: point.coordinate)
            return max(abs(actual.x - expected.x), abs(actual.y - expected.y))
        }.max() ?? 0

        guard let png = snapshot.image.pngData() else { throw BaseMapError.encodingFailed }
        return BaseMap(png: png, alignmentErrorPixels: error)
    }
}
