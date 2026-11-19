import CoreGraphics

/// How much highway to draw at the current zoom, so the lines don't bury the radar when zoomed out.
/// Used by the phone's and the watch's maps.
public enum HighwayDetail: Sendable {
    /// Interstates and freeways, full width.
    case full
    /// Interstates only, thinner.
    case interstates
    /// Interstates as faint hairlines (most of the country on screen).
    case overview

    public init(visibleMiles: Double) {
        switch visibleMiles {
        case ..<300: self = .full
        case ..<1_000: self = .interstates
        default: self = .overview
        }
    }

    /// Width of the light line, in points; 0 hides the class at this zoom.
    public func lineWidth(for highwayClass: HighwayClass) -> CGFloat {
        let interstate = highwayClass == .interstate
        switch self {
        case .full: return interstate ? 2.5 : 1.5
        case .interstates: return interstate ? 1.5 : 0
        case .overview: return interstate ? 0.75 : 0
        }
    }

    /// The dark casing under each line, 1 pt wider on each side; hairlines have none.
    public var showsCasing: Bool { self != .overview }
    public static let casingExtraWidth: CGFloat = 2

    public var lineOpacity: Double { self == .overview ? 0.6 : 1 }
}
