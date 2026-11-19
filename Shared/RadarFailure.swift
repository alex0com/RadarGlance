import Foundation

public enum RadarFailure: String, Error, Codable, Sendable, Equatable {
    case locationOff
    case locationUnavailable
    case noCoverage
    case network
    case service

    /// Short text for the widget. Never asks the driver to pick up the phone.
    public var message: String {
        switch self {
        case .locationOff: "Location off"
        case .locationUnavailable: "No location"
        case .noCoverage: "No radar coverage here"
        case .network: "Offline"
        case .service: "Radar unavailable"
        }
    }

    /// Whether a cached image would mislead (wrong place, or the user turned location off).
    public var hidesImage: Bool {
        switch self {
        case .locationOff, .noCoverage: true
        case .locationUnavailable, .network, .service: false
        }
    }

    /// Whether `error` means the device is offline, rather than the service failing.
    public static func isOffline(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
             .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
            return true
        default:
            return false
        }
    }
}
