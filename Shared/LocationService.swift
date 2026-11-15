import CoreLocation
import Foundation

public enum LocationResult: Sendable, Equatable {
    /// `stale` means the fetch failed and this is the last cached fix.
    case fix(LocationFix, stale: Bool)
    case denied
    case unavailable
}

public protocol LocationProviding: Sendable {
    func currentLocation() async -> LocationResult
}

/// One-shot location fetch (~100 m accuracy, 10 s timeout) with fallback to the last cached fix.
@MainActor
public final class LocationService: NSObject, CLLocationManagerDelegate, LocationProviding {
    public static let timeout: Duration = .seconds(10)
    /// Below this speed `course` is noise, so no direction arrow.
    nonisolated public static let minimumSpeedForCourse: CLLocationSpeed = 2

    private let manager = CLLocationManager()
    private let store: SharedStore
    private var pending: CheckedContinuation<CLLocation?, Never>?

    /// Called on the main actor when the authorization status changes.
    public var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?

    public init(store: SharedStore = SharedStore()) {
        self.store = store
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    public var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    public func requestWhenInUseAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    public func currentLocation() async -> LocationResult {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            break
        default:
            // Not determined counts as off: the widget can't ask, and the app asks during onboarding.
            return .denied
        }
        if Self.isWidgetExtension && !manager.isAuthorizedForWidgetUpdates {
            return .denied
        }
        if let location = await requestOnce() {
            let fix = Self.fix(from: location)
            store.cachedLocation = fix
            return .fix(fix, stale: false)
        }
        if let cached = store.cachedLocation {
            return .fix(cached, stale: true)
        }
        return .unavailable
    }

    nonisolated public static func fix(from location: CLLocation) -> LocationFix {
        let moving = location.speed > minimumSpeedForCourse && location.course >= 0
        return LocationFix(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            course: moving ? location.course : nil,
            timestamp: location.timestamp
        )
    }

    private static var isWidgetExtension: Bool {
        Bundle.main.bundleURL.pathExtension == "appex"
    }

    private func requestOnce() async -> CLLocation? {
        finish(nil)
        return await withCheckedContinuation { continuation in
            pending = continuation
            manager.requestLocation()
            Task { [weak self] in
                try? await Task.sleep(for: Self.timeout)
                self?.finish(nil)
            }
        }
    }

    private func finish(_ location: CLLocation?) {
        pending?.resume(returning: location)
        pending = nil
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let location = locations.last
        MainActor.assumeIsolated { finish(location) }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated { finish(nil) }
    }

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated { onAuthorizationChange?(status) }
    }
}

/// Always returns the same position. Used for Simulator testing (`-testLocation lat,lon`).
public struct FixedLocationProvider: LocationProviding {
    public let fix: LocationFix

    public init(latitude: Double, longitude: Double, course: Double? = nil) {
        fix = LocationFix(latitude: latitude, longitude: longitude, course: course, timestamp: Date())
    }

    /// Parses `-testLocation 35.47,-97.52` from the launch arguments.
    public static func fromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> FixedLocationProvider? {
        guard let index = arguments.firstIndex(of: "-testLocation"), index + 1 < arguments.count else { return nil }
        let parts = arguments[index + 1].split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return FixedLocationProvider(latitude: parts[0], longitude: parts[1])
    }

    public func currentLocation() async -> LocationResult {
        .fix(fix, stale: false)
    }
}
