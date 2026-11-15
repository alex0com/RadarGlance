import Foundation

public enum AppGroup {
    public static let identifier = "group.com.example.radarglance"

    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    public static var defaults: UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }
}

/// Tile width options. The tile is square, so this is also its height.
public enum ZoomLevel: Int, CaseIterable, Codable, Sendable, Identifiable {
    case miles40 = 40
    case miles80 = 80
    case miles160 = 160

    /// Defaults: zoomed in for checking on foot, wide for driving.
    public static let phoneDefault = ZoomLevel.miles40
    public static let carDefault = ZoomLevel.miles160
    /// The radar image always covers this width; every zoom is cut from it.
    public static let largest = ZoomLevel.miles160

    public var id: Int { rawValue }
    public var miles: Double { Double(rawValue) }
    public var label: String { "\(rawValue) mi" }
}

/// Pixel size of the square composite. The small (CarPlay) widget uses `.standard` to stay
/// well inside the widget memory limit; medium and large widgets use `.high`.
public enum TileResolution: Int, CaseIterable, Codable, Sendable {
    case standard = 512
    case high = 1024

    public var pixels: Int { rawValue }
}

/// A position fix, as stored in the App Group and drawn by the compositor.
public struct LocationFix: Codable, Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    /// Degrees clockwise from north. Only set when moving faster than 2 m/s.
    public var course: Double?
    public var timestamp: Date

    public init(latitude: Double, longitude: Double, course: Double? = nil, timestamp: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.course = course
        self.timestamp = timestamp
    }
}

public struct NetworkSlot: Sendable {
    fileprivate let previous: Date?
}

/// Settings and cross-process state shared by the app and the widget through the App Group.
public final class SharedStore: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
    }

    private enum Key {
        static let phoneZoom = "phoneZoomMiles"
        static let carZoom = "carZoomMiles"
        static let lastNetworkAttempt = "lastNetworkAttempt"
        static let lastSuccessfulRefresh = "lastSuccessfulRefresh"
        static let forceRefreshRequestedAt = "forceRefreshRequestedAt"
        static let forceRefreshHandledAt = "forceRefreshHandledAt"
        static let cachedLocation = "cachedLocation"
        static let onboardingDone = "onboardingDone"
    }

    /// Used by the app and by medium/large widgets set to Automatic.
    public var phoneZoom: ZoomLevel {
        get { ZoomLevel(rawValue: defaults.integer(forKey: Key.phoneZoom)) ?? .phoneDefault }
        set { defaults.set(newValue.rawValue, forKey: Key.phoneZoom) }
    }

    /// Used by small widgets set to Automatic. Small is the only size CarPlay shows, and
    /// WidgetKit doesn't tell a widget whether it's in CarPlay.
    public var carZoom: ZoomLevel {
        get { ZoomLevel(rawValue: defaults.integer(forKey: Key.carZoom)) ?? .carDefault }
        set { defaults.set(newValue.rawValue, forKey: Key.carZoom) }
    }

    public var lastNetworkAttempt: Date? {
        get { defaults.object(forKey: Key.lastNetworkAttempt) as? Date }
        set { defaults.set(newValue, forKey: Key.lastNetworkAttempt) }
    }

    public var lastSuccessfulRefresh: Date? {
        get { defaults.object(forKey: Key.lastSuccessfulRefresh) as? Date }
        set { defaults.set(newValue, forKey: Key.lastSuccessfulRefresh) }
    }

    /// Set by the widget's refresh button; read by the timeline provider.
    public var forceRefreshRequestedAt: Date? {
        get { defaults.object(forKey: Key.forceRefreshRequestedAt) as? Date }
        set { defaults.set(newValue, forKey: Key.forceRefreshRequestedAt) }
    }

    public var forceRefreshHandledAt: Date? {
        get { defaults.object(forKey: Key.forceRefreshHandledAt) as? Date }
        set { defaults.set(newValue, forKey: Key.forceRefreshHandledAt) }
    }

    public var cachedLocation: LocationFix? {
        get {
            guard let data = defaults.data(forKey: Key.cachedLocation) else { return nil }
            return try? JSONDecoder().decode(LocationFix.self, from: data)
        }
        set {
            defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: Key.cachedLocation)
        }
    }

    public var onboardingDone: Bool {
        get { defaults.bool(forKey: Key.onboardingDone) }
        set { defaults.set(newValue, forKey: Key.onboardingDone) }
    }

    /// Serializes claims within a process: several widgets can refresh at the same time.
    private static let networkSlotLock = NSLock()

    /// Atomically records a network attempt at `now` unless the last one was under `interval`
    /// ago. Returns nil when throttled; otherwise a token for `releaseNetworkSlot` in case
    /// the attempt turns out not to need the network.
    public func claimNetworkSlot(now: Date, interval: TimeInterval) -> NetworkSlot? {
        Self.networkSlotLock.withLock {
            let previous = lastNetworkAttempt
            if let previous, previous <= now, now.timeIntervalSince(previous) < interval {
                return nil
            }
            lastNetworkAttempt = now
            return NetworkSlot(previous: previous)
        }
    }

    public func releaseNetworkSlot(_ slot: NetworkSlot) {
        Self.networkSlotLock.withLock { lastNetworkAttempt = slot.previous }
    }

    /// True if the refresh button was tapped after the last time a forced refresh was handled.
    /// Marks the request as handled.
    public func consumeForceRefreshRequest(now: Date) -> Bool {
        guard let requested = forceRefreshRequestedAt else { return false }
        if let handled = forceRefreshHandledAt, handled >= requested { return false }
        forceRefreshHandledAt = now
        return true
    }
}
