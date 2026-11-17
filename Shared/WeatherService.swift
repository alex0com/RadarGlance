import CoreLocation
import Foundation

/// Current temperature and humidity near the user, for the widget.
public struct WeatherConditions: Codable, Sendable, Equatable {
    public enum Origin: String, Codable, Sendable {
        /// Measured at a nearby NWS station.
        case observation
        /// NWS's hourly forecast for the current hour (when no station reported).
        case forecast
    }

    public var temperatureCelsius: Double?
    /// Percent, 0–100.
    public var relativeHumidity: Double?
    /// When the values were measured, or the forecast hour's start.
    public var time: Date
    public var origin: Origin
    public var stationID: String?
    public var latitude: Double
    public var longitude: Double
    public var fetchedAt: Date

    public init(temperatureCelsius: Double?, relativeHumidity: Double?, time: Date, origin: Origin,
                stationID: String?, latitude: Double, longitude: Double, fetchedAt: Date) {
        self.temperatureCelsius = temperatureCelsius
        self.relativeHumidity = relativeHumidity
        self.time = time
        self.origin = origin
        self.stationID = stationID
        self.latitude = latitude
        self.longitude = longitude
        self.fetchedAt = fetchedAt
    }

    /// Too old to show.
    public func isStale(now: Date) -> Bool {
        now.timeIntervalSince(fetchedAt) > WeatherService.maxCacheAge
    }
}

/// The NWS stations and hourly forecast URL for a location, from `/points`.
struct WeatherPoint: Codable, Sendable, Equatable {
    var key: String
    var stations: [String]
    var forecastHourly: URL
    var fetchedAt: Date
}

public enum WeatherServiceError: Error, Equatable {
    case httpStatus(Int)
    case noData
}

/// Reads current conditions from the NWS API (api.weather.gov; public, no key). Uses the latest
/// observation from the nearest stations, filling gaps (stations often omit humidity) from the
/// hourly forecast. Results are cached in the App Group so the widget usually makes one request
/// every `refreshInterval` at most.
public actor WeatherService {
    public static let refreshInterval: TimeInterval = 10 * 60
    /// Cached conditions are reused within this distance.
    public static let reuseDistance: CLLocationDistance = 5_000
    /// Kept on failures up to this age, then hidden.
    public static let maxCacheAge: TimeInterval = 3 * 3600
    static let maxObservationAge: TimeInterval = 2 * 3600
    static let pointMaxAge: TimeInterval = 7 * 24 * 3600
    static let stationsToTry = 3
    static let base = URL(string: "https://api.weather.gov")!

    private let loader: HTTPDataLoading
    private let store: SharedStore
    private let now: @Sendable () -> Date

    public init(loader: HTTPDataLoading = URLSessionLoader(), store: SharedStore = SharedStore(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.loader = loader
        self.store = store
        self.now = now
    }

    /// Conditions at the location: cached if recent and nearby, otherwise fetched. On failure,
    /// the cached value if it's nearby and not stale; nil if there's nothing to show.
    public func conditions(latitude: Double, longitude: Double, force: Bool = false) async -> WeatherConditions? {
        let here = CLLocation(latitude: latitude, longitude: longitude)
        let cached = store.weatherConditions.flatMap { cached -> WeatherConditions? in
            let there = CLLocation(latitude: cached.latitude, longitude: cached.longitude)
            return here.distance(from: there) <= Self.reuseDistance ? cached : nil
        }
        if !force, let cached, now().timeIntervalSince(cached.fetchedAt) < Self.refreshInterval {
            return cached
        }
        do {
            let fresh = try await fetch(latitude: latitude, longitude: longitude)
            store.weatherConditions = fresh
            return fresh
        } catch {
            guard let cached, !cached.isStale(now: now()) else { return nil }
            return cached
        }
    }

    private func fetch(latitude: Double, longitude: Double) async throws -> WeatherConditions {
        let point = try await point(latitude: latitude, longitude: longitude)
        var temperature: Double?
        var humidity: Double?
        var time: Date?
        var station: String?
        for id in point.stations.prefix(Self.stationsToTry) {
            guard let observation = try? await observation(station: id),
                  now().timeIntervalSince(observation.time) <= Self.maxObservationAge
            else { continue }
            if temperature == nil, let value = observation.temperature {
                temperature = value
                time = observation.time
                station = id
            }
            if humidity == nil { humidity = observation.humidity }
            if temperature != nil && humidity != nil { break }
        }
        var origin = WeatherConditions.Origin.observation
        if temperature == nil || humidity == nil, let hour = try? await currentHour(point.forecastHourly) {
            if temperature == nil {
                temperature = hour.temperature
                origin = .forecast
                time = hour.start
            }
            humidity = humidity ?? hour.humidity
        }
        guard let time, temperature != nil || humidity != nil else { throw WeatherServiceError.noData }
        return WeatherConditions(temperatureCelsius: temperature, relativeHumidity: humidity, time: time,
                                 origin: origin, stationID: origin == .observation ? station : nil,
                                 latitude: latitude, longitude: longitude, fetchedAt: now())
    }

    // MARK: Requests

    /// Stations and forecast URL, cached per ~1 km for a week.
    private func point(latitude: Double, longitude: Double) async throws -> WeatherPoint {
        let key = String(format: "%.2f,%.2f", latitude, longitude)
        if let cached = store.weatherPoint, cached.key == key,
           now().timeIntervalSince(cached.fetchedAt) < Self.pointMaxAge {
            return cached
        }
        let points = try JSONDecoder().decode(
            PointsResponse.self, from: try await load(Self.base.appending(path: "points/\(key)")))
        var components = URLComponents(url: points.properties.observationStations, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "limit", value: String(Self.stationsToTry))]
        let stations = try JSONDecoder().decode(StationsResponse.self, from: try await load(components.url!))
        let point = WeatherPoint(key: key, stations: stations.features.map(\.properties.stationIdentifier),
                                 forecastHourly: points.properties.forecastHourly, fetchedAt: now())
        store.weatherPoint = point
        return point
    }

    private func observation(station: String) async throws -> (time: Date, temperature: Double?, humidity: Double?) {
        let data = try await load(Self.base.appending(path: "stations/\(station)/observations/latest"))
        let properties = try JSONDecoder().decode(ObservationResponse.self, from: data).properties
        guard let time = Self.date(properties.timestamp) else { throw WeatherServiceError.noData }
        let temperature = properties.temperature?.value
        var humidity = properties.relativeHumidity?.value
        if humidity == nil, let temperature, let dewpoint = properties.dewpoint?.value {
            humidity = Self.relativeHumidity(temperature: temperature, dewpoint: dewpoint)
        }
        return (time, temperature, humidity)
    }

    private func currentHour(_ url: URL) async throws -> (start: Date, temperature: Double?, humidity: Double?) {
        let periods = try JSONDecoder().decode(HourlyResponse.self, from: try await load(url)).properties.periods
        let now = now()
        let period = periods.first { period in
            guard let start = Self.date(period.startTime), let end = Self.date(period.endTime) else { return false }
            return start <= now && now < end
        } ?? periods.first
        guard let period, let start = Self.date(period.startTime) else { throw WeatherServiceError.noData }
        let temperature = period.temperature.map {
            period.temperatureUnit == "F" ? ($0 - 32) * 5 / 9 : $0
        }
        return (start, temperature, period.relativeHumidity?.value)
    }

    private func load(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: RadarClient.requestTimeout)
        // api.weather.gov requires a User-Agent identifying the app.
        request.setValue(RadarClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/geo+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await loader.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw WeatherServiceError.httpStatus(status) }
        return data
    }

    // MARK: Helpers

    /// Magnus formula; temperatures in °C.
    static func relativeHumidity(temperature: Double, dewpoint: Double) -> Double {
        func vapor(_ t: Double) -> Double { exp(17.625 * t / (243.04 + t)) }
        return min(100, max(0, 100 * vapor(dewpoint) / vapor(temperature)))
    }

    /// NWS times carry offsets like `+00:00` or `-06:00`.
    static func date(_ string: String) -> Date? {
        try? Date(string, strategy: .iso8601)
    }

    private struct Quantity: Decodable { let value: Double? }

    private struct PointsResponse: Decodable {
        struct Properties: Decodable {
            let observationStations: URL
            let forecastHourly: URL
        }
        let properties: Properties
    }

    private struct StationsResponse: Decodable {
        struct Feature: Decodable {
            struct Properties: Decodable { let stationIdentifier: String }
            let properties: Properties
        }
        let features: [Feature]
    }

    private struct ObservationResponse: Decodable {
        struct Properties: Decodable {
            let timestamp: String
            let temperature: Quantity?
            let dewpoint: Quantity?
            let relativeHumidity: Quantity?
        }
        let properties: Properties
    }

    private struct HourlyResponse: Decodable {
        struct Properties: Decodable {
            struct Period: Decodable {
                let startTime: String
                let endTime: String
                let temperature: Double?
                let temperatureUnit: String?
                let relativeHumidity: Quantity?
            }
            let periods: [Period]
        }
        let properties: Properties
    }
}
