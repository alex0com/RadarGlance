import Foundation
import Testing
@testable import Shared

/// Answers api.weather.gov paths from a table; anything else is a 404.
final class RoutedLoader: HTTPDataLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [String: (Data, Int)]
    private var _requests: [URLRequest] = []

    init(_ routes: [String: (Data, Int)]) { self.routes = routes }

    var requests: [URLRequest] { lock.withLock { _requests } }
    func count(_ path: String) -> Int { requests.filter { $0.url!.path() == path }.count }
    func set(_ path: String, _ response: (Data, Int)?) { lock.withLock { routes[path] = response } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (data, status) = lock.withLock {
            _requests.append(request)
            return routes[request.url!.path()] ?? (Data(), 404)
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

struct WeatherServiceTests {
    static let pointsPath = "/points/35.47,-97.52"
    static let stationsPath = "/gridpoints/OUN/97,94/stations"
    static let hourlyPath = "/gridpoints/OUN/97,94/forecast/hourly"
    static func observationPath(_ station: String) -> String { "/stations/\(station)/observations/latest" }

    /// 10 minutes after the observations in the fixtures, inside the first forecast hour.
    let clock = TestClock(try! Date("2026-11-17T16:10:00Z", strategy: .iso8601))
    let store = SharedStore(defaults: temporaryDefaults())
    let loader: RoutedLoader
    let service: WeatherService

    init() throws {
        loader = RoutedLoader([
            Self.pointsPath: (try Fixture.data("nws-points.json"), 200),
            Self.stationsPath: (try Fixture.data("nws-stations.json"), 200),
            // KOKC: temperature 9 °C, no humidity or dewpoint.
            Self.observationPath("KOKC"): (try Fixture.data("nws-observation.json"), 200),
            Self.observationPath("KPWA"): (Self.observation(temperature: 10, humidity: 60), 200),
            Self.hourlyPath: (try Fixture.data("nws-hourly.json"), 200),
        ])
        service = WeatherService(loader: loader, store: store, now: { [clock] in clock.now })
    }

    static func observation(temperature: Double?, humidity: Double?, dewpoint: Double? = nil,
                            time: String = "2026-11-17T15:55:00+00:00") -> Data {
        func quantity(_ value: Double?) -> String { #"{"value": \#(value.map { String($0) } ?? "null")}"# }
        return Data("""
            {"properties": {"timestamp": "\(time)", "temperature": \(quantity(temperature)),
             "dewpoint": \(quantity(dewpoint)), "relativeHumidity": \(quantity(humidity))}}
            """.utf8)
    }

    private func conditions() async -> WeatherConditions? {
        await service.conditions(latitude: 35.47, longitude: -97.52)
    }

    @Test func temperatureFromNearestStationHumidityFromNext() async throws {
        let result = try #require(await conditions())
        #expect(result.temperatureCelsius == 9)
        #expect(result.relativeHumidity == 60)
        #expect(result.stationID == "KOKC")
        #expect(result.origin == .observation)
        #expect(result.time == WeatherService.date("2026-11-17T15:50:00+00:00"))
        #expect(loader.count(Self.hourlyPath) == 0)
        #expect(loader.requests.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent") == RadarClient.userAgent })
    }

    @Test func humidityFromHourlyForecastWhenNoStationHasIt() async throws {
        loader.set(Self.observationPath("KPWA"), nil)
        let result = try #require(await conditions())
        #expect(result.temperatureCelsius == 9)
        #expect(result.relativeHumidity == 71)
        #expect(result.origin == .observation)
    }

    @Test func forecastWhenNoStationReports() async throws {
        loader.set(Self.observationPath("KOKC"), nil)
        loader.set(Self.observationPath("KPWA"), nil)
        let result = try #require(await conditions())
        let temperature = try #require(result.temperatureCelsius)
        let expected: Double = (49 - 32) * 5 / 9
        #expect(abs(temperature - expected) < 0.01)
        #expect(result.relativeHumidity == 71)
        #expect(result.origin == .forecast)
        #expect(result.stationID == nil)
    }

    @Test func oldObservationsAreSkipped() async throws {
        loader.set(Self.observationPath("KOKC"), (Self.observation(temperature: 1, humidity: 1, time: "2026-11-17T10:00:00+00:00"), 200))
        let result = try #require(await conditions())
        #expect(result.temperatureCelsius == 10)
        #expect(result.stationID == "KPWA")
    }

    @Test func humidityFromDewpoint() async throws {
        loader.set(Self.observationPath("KOKC"), (Self.observation(temperature: 20, humidity: nil, dewpoint: 10), 200))
        let result = try #require(await conditions())
        let humidity = try #require(result.relativeHumidity)
        #expect(abs(humidity - 52.5) < 0.5)
        #expect(loader.count(Self.observationPath("KPWA")) == 0)
    }

    @Test func cachedForTenMinutesAndPointForAWeek() async {
        _ = await conditions()
        let first = loader.requests.count
        clock.advance(9 * 60)
        _ = await conditions()
        #expect(loader.requests.count == first)
        clock.advance(2 * 60)
        _ = await conditions()
        #expect(loader.requests.count > first)
        #expect(loader.count(Self.pointsPath) == 1)
        #expect(loader.count(Self.stationsPath) == 1)
    }

    @Test func movingFarRefetches() async {
        _ = await conditions()
        let first = loader.requests.count
        // ~11 km north: outside the reuse distance; a different /points key (404 here).
        let moved = await service.conditions(latitude: 35.57, longitude: -97.52)
        #expect(loader.requests.count > first)
        #expect(moved == nil)
    }

    @Test func failureKeepsRecentCacheThenGivesUp() async throws {
        let cached = try #require(await conditions())
        for path in [Self.observationPath("KOKC"), Self.observationPath("KPWA"), Self.hourlyPath] {
            loader.set(path, (Data(), 503))
        }
        clock.advance(20 * 60)
        #expect(await conditions() == cached)
        clock.advance(3 * 3600)
        #expect(await conditions() == nil)
    }

    @Test func parsesNWSTimeOffsets() {
        #expect(WeatherService.date("2026-11-17T10:00:00-06:00") == WeatherService.date("2026-11-17T16:00:00+00:00"))
        #expect(WeatherService.date("2026-11-17T16:00:00+00:00") != nil)
    }

    @Test func widgetSettingDefaultsOff() {
        #expect(!store.showsWidgetWeather)
    }
}
