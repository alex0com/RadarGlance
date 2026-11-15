import Foundation

/// How old the radar data is, for the time label's tint.
public enum RadarAge: Sendable, Equatable {
    case fresh
    case aging
    case old

    public static let amberAfter: TimeInterval = 10 * 60
    public static let redAfter: TimeInterval = 20 * 60

    public init(dataTime: Date, now: Date) {
        let age = now.timeIntervalSince(dataTime)
        if age > Self.redAfter {
            self = .old
        } else if age > Self.amberAfter {
            self = .aging
        } else {
            self = .fresh
        }
    }
}
