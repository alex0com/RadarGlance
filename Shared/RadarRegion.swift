import Foundation

/// A NOAA MRMS WMS coverage area. Values come from the layer's GetCapabilities.
public struct RadarRegion: Sendable, Equatable {
    public let id: String
    public let endpoint: URL
    public let layer: String
    public let west: Double
    public let east: Double
    public let south: Double
    public let north: Double

    public static let conus = RadarRegion(
        id: "conus",
        endpoint: URL(string: "https://opengeo.ncep.noaa.gov/geoserver/conus/conus_bref_qcd/ows")!,
        layer: "conus_bref_qcd",
        west: -130.0, east: -60.0, south: 20.0, north: 55.0
    )

    /// Only CONUS is in scope for now.
    public static let all: [RadarRegion] = [.conus]

    public func covers(latitude: Double, longitude: Double) -> Bool {
        (south...north).contains(latitude) && (west...east).contains(longitude)
    }

    public static func region(latitude: Double, longitude: Double) -> RadarRegion? {
        all.first { $0.covers(latitude: latitude, longitude: longitude) }
    }
}
