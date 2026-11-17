import Foundation

/// A NOAA service that serves the MRMS radar mosaic. Both carry the same data; they differ in
/// colors and update rate (opengeo ~2 min, nowCOAST ~4 min).
public enum RadarSource: String, Codable, Sendable, CaseIterable {
    /// opengeo.ncep.noaa.gov, the primary source (same colors as radar.weather.gov).
    case opengeo
    /// nowcoast.noaa.gov, the backup (classic NWS colors).
    case nowCOAST

    public var label: String {
        switch self {
        case .opengeo: "NOAA opengeo"
        case .nowCOAST: "NOAA nowCOAST"
        }
    }

    /// The service's layer for `region`'s area. Only CONUS is in scope.
    public func region(for region: RadarRegion) -> RadarRegion {
        switch self {
        case .opengeo: region
        case .nowCOAST: .nowCoastConus
        }
    }
}

/// Which radar source(s) to use, set in the app's Settings and shared with the widget.
public enum RadarSourcePreference: String, Codable, Sendable, CaseIterable, Identifiable {
    /// opengeo, switching to nowCOAST whenever opengeo fails.
    case automatic
    case opengeo
    case nowCOAST

    public var id: Self { self }

    public var label: String {
        switch self {
        case .automatic: "Automatic"
        case .opengeo: "opengeo"
        case .nowCOAST: "nowCOAST"
        }
    }

    /// Sources to try, in order.
    public var sources: [RadarSource] {
        switch self {
        case .automatic: [.opengeo, .nowCOAST]
        case .opengeo: [.opengeo]
        case .nowCOAST: [.nowCOAST]
        }
    }
}

extension RadarRegion {
    /// nowCOAST's CONUS layer. Its per-layer endpoint keeps GetCapabilities small (~10 KB).
    public static let nowCoastConus = RadarRegion(
        id: "nowcoast-conus",
        endpoint: URL(string: "https://nowcoast.noaa.gov/geoserver/observations/weather_radar/conus_base_reflectivity_mosaic/ows")!,
        layer: "conus_base_reflectivity_mosaic",
        west: -130.0, east: -60.0, south: 20.0, north: 55.0
    )
}
