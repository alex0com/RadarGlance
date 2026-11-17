import Foundation

/// How the app's radar map looks, and which radar source to use. Stored in the App Group; the
/// widget uses `radarSource` and keeps NOAA's colors.
public struct MapSettings: Codable, Sendable, Equatable {
    public enum Appearance: String, Codable, Sendable, CaseIterable, Identifiable {
        case system, light, dark
        public var id: Self { self }
        public var label: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
    }

    public enum Style: String, Codable, Sendable, CaseIterable, Identifiable {
        /// Faded map so the radar stands out.
        case muted
        /// Apple's normal map, with more prominent roads and places.
        case standard
        /// Satellite imagery with roads and labels.
        case satellite
        public var id: Self { self }
        public var label: String {
            switch self {
            case .muted: "Muted"
            case .standard: "Standard"
            case .satellite: "Satellite"
            }
        }
    }

    public enum AnimationSpeed: String, Codable, Sendable, CaseIterable, Identifiable {
        case slow, normal, fast
        public var id: Self { self }
        public var label: String {
            switch self {
            case .slow: "Slow"
            case .normal: "Normal"
            case .fast: "Fast"
            }
        }
        /// Time each frame is shown; the newest frame is held longer.
        public var frameInterval: Duration {
            switch self {
            case .slow: .milliseconds(800)
            case .normal: .milliseconds(500)
            case .fast: .milliseconds(300)
            }
        }
    }

    public static let opacityRange: ClosedRange<Double> = 0.3...1.0

    public var appearance: Appearance = .dark
    public var style: Style = .muted
    /// Draws interstates and freeways above the radar.
    public var showsHighways = true
    public var colorScheme: RadarColorScheme = .noaa
    /// Drops echoes below `RadarPalette.lightReturnThreshold` (drizzle, clutter).
    public var hidesLightReturns = false
    public var radarOpacity = 0.75
    public var animationSpeed: AnimationSpeed = .normal
    /// Smooths the 1 km radar cells instead of drawing them as crisp blocks.
    public var smoothRadar = false
    /// Also used by the widget: opengeo with nowCOAST as backup, or one of them only.
    public var radarSource: RadarSourcePreference = .automatic

    public init() {}

    // Missing keys fall back to defaults, so settings saved by an older version still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = MapSettings()
        appearance = try container.decodeIfPresent(Appearance.self, forKey: .appearance) ?? defaults.appearance
        style = try container.decodeIfPresent(Style.self, forKey: .style) ?? defaults.style
        showsHighways = try container.decodeIfPresent(Bool.self, forKey: .showsHighways) ?? defaults.showsHighways
        colorScheme = try container.decodeIfPresent(RadarColorScheme.self, forKey: .colorScheme) ?? defaults.colorScheme
        hidesLightReturns = try container.decodeIfPresent(Bool.self, forKey: .hidesLightReturns) ?? defaults.hidesLightReturns
        radarOpacity = try container.decodeIfPresent(Double.self, forKey: .radarOpacity) ?? defaults.radarOpacity
        animationSpeed = try container.decodeIfPresent(AnimationSpeed.self, forKey: .animationSpeed) ?? defaults.animationSpeed
        smoothRadar = try container.decodeIfPresent(Bool.self, forKey: .smoothRadar) ?? defaults.smoothRadar
        radarSource = try container.decodeIfPresent(RadarSourcePreference.self, forKey: .radarSource) ?? defaults.radarSource
    }
}
