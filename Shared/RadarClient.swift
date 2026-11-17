import Foundation
import MapKit

public protocol HTTPDataLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

public struct URLSessionLoader: HTTPDataLoading {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = RadarClient.requestTimeout
        config.timeoutIntervalForResource = RadarClient.requestTimeout
        session = URLSession(configuration: config)
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

/// A radar frame time as listed by GetCapabilities. `raw` is sent back verbatim as `TIME=`.
public struct RadarTime: Sendable, Equatable, Codable {
    public let raw: String
    public let date: Date

    public init?(raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // The `default` attribute has no fractional seconds; list values do.
        guard let date = (try? Date(trimmed, strategy: .iso8601))
            ?? (try? Date(trimmed, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        else { return nil }
        self.raw = trimmed
        self.date = date
    }
}

public struct RadarImage: Sendable {
    public let png: Data
    public let url: URL
    public let httpStatus: Int
}

public enum RadarClientError: Error, Sendable, Equatable {
    /// The body wasn't a PNG. NOAA reports WMS errors as XML with HTTP 200.
    case notPNG(httpStatus: Int, serviceMessage: String?)
    case httpStatus(Int)
    case noTimeInCapabilities
}

/// Talks to the NOAA MRMS WMS. Quirks: errors come back as XML with HTTP 200, and a TIME that
/// isn't listed in GetCapabilities returns a blank PNG rather than an error.
public actor RadarClient {
    public static let userAgent = "RadarGlance/1.0 (iOS widget; contact: radarglance@example.com)"
    public static let requestTimeout: TimeInterval = 15
    /// Matches the server's `max-age=120`; frames arrive about every 2 min.
    public static let capabilitiesTTL: TimeInterval = 120
    public static let imageSize = 512

    private let loader: HTTPDataLoading
    private let now: @Sendable () -> Date
    /// Per region, so switching between sources doesn't refetch both.
    private var cachedTimes: [String: (times: CapabilitiesTimes, fetchedAt: Date)] = [:]

    /// The last URL requested, for the debug panel.
    public private(set) var lastRequestURL: URL?
    public private(set) var lastHTTPStatus: Int?

    public init(loader: HTTPDataLoading = URLSessionLoader(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.loader = loader
        self.now = now
    }

    // MARK: URLs

    public static func capabilitiesURL(region: RadarRegion) -> URL {
        var components = URLComponents(url: region.endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "SERVICE", value: "WMS"),
            URLQueryItem(name: "VERSION", value: "1.3.0"),
            URLQueryItem(name: "REQUEST", value: "GetCapabilities"),
        ]
        return components.url!
    }

    public static func getMapURL(region: RadarRegion, box: MercatorBox, time: RadarTime?, size: Int = imageSize) -> URL {
        getMapURL(region: region, bbox: box.bboxString, width: size, height: size, time: time)
    }

    /// A GetMap for any rectangle; the radar viewer's requests needn't be square.
    public static func getMapURL(region: RadarRegion, mapRect: MKMapRect, width: Int, height: Int,
                                 time: RadarTime?) -> URL {
        getMapURL(region: region, bbox: MercatorBox.bboxString(for: mapRect), width: width, height: height, time: time)
    }

    private static func getMapURL(region: RadarRegion, bbox: String, width: Int, height: Int, time: RadarTime?) -> URL {
        var components = URLComponents(url: region.endpoint, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "SERVICE", value: "WMS"),
            URLQueryItem(name: "VERSION", value: "1.3.0"),
            URLQueryItem(name: "REQUEST", value: "GetMap"),
            URLQueryItem(name: "LAYERS", value: region.layer),
            URLQueryItem(name: "STYLES", value: ""),
            // EPSG:3857 axis order is x,y even in WMS 1.3.0.
            URLQueryItem(name: "CRS", value: "EPSG:3857"),
            URLQueryItem(name: "BBOX", value: bbox),
            URLQueryItem(name: "WIDTH", value: String(width)),
            URLQueryItem(name: "HEIGHT", value: String(height)),
            URLQueryItem(name: "FORMAT", value: "image/png"),
            URLQueryItem(name: "TRANSPARENT", value: "true"),
        ]
        if let time {
            items.append(URLQueryItem(name: "TIME", value: time.raw))
        }
        components.queryItems = items
        return components.url!
    }

    // MARK: Requests

    /// The newest frame time. Cached for `capabilitiesTTL` unless `force`.
    public func latestRadarTime(region: RadarRegion, force: Bool) async throws -> RadarTime {
        try await capabilitiesTimes(region: region, force: force).latest
    }

    /// Every listed frame time (about the last 2 h), oldest first. Cached like `latestRadarTime`.
    public func recentTimes(region: RadarRegion, force: Bool) async throws -> [RadarTime] {
        try await capabilitiesTimes(region: region, force: force).all
    }

    private func capabilitiesTimes(region: RadarRegion, force: Bool) async throws -> CapabilitiesTimes {
        if !force, let cached = cachedTimes[region.id],
           now().timeIntervalSince(cached.fetchedAt) < Self.capabilitiesTTL {
            return cached.times
        }
        let url = Self.capabilitiesURL(region: region)
        let (data, status) = try await load(url)
        guard status == 200 else { throw RadarClientError.httpStatus(status) }
        guard let times = CapabilitiesParser.times(in: data, layer: region.layer) else {
            throw RadarClientError.noTimeInCapabilities
        }
        cachedTimes[region.id] = (times, now())
        return times
    }

    /// Downloads one GetMap PNG. Pass the time from `latestRadarTime`; never a made-up time,
    /// because out-of-range times return a blank PNG rather than an error.
    public func fetchImage(region: RadarRegion, box: MercatorBox, time: RadarTime?,
                           size: Int = imageSize) async throws -> RadarImage {
        try await fetch(Self.getMapURL(region: region, box: box, time: time, size: size))
    }

    /// Downloads one GetMap PNG for any rectangle. `time` must come from `recentTimes`.
    public func fetchImage(region: RadarRegion, mapRect: MKMapRect, width: Int, height: Int,
                           time: RadarTime) async throws -> RadarImage {
        try await fetch(Self.getMapURL(region: region, mapRect: mapRect, width: width, height: height, time: time))
    }

    private func fetch(_ url: URL) async throws -> RadarImage {
        let (data, status) = try await load(url)
        try Self.validatePNG(data, httpStatus: status)
        return RadarImage(png: data, url: url, httpStatus: status)
    }

    private func load(_ url: URL) async throws -> (Data, Int) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.requestTimeout)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        lastRequestURL = url
        lastHTTPStatus = nil
        let (data, response) = try await loader.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        lastHTTPStatus = status
        return (data, status)
    }

    // MARK: Validation

    public static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    public static func isPNG(_ data: Data) -> Bool {
        data.count > pngSignature.count && Array(data.prefix(pngSignature.count)) == pngSignature
    }

    public static func validatePNG(_ data: Data, httpStatus: Int) throws {
        if isPNG(data) && httpStatus == 200 { return }
        if !isPNG(data) {
            throw RadarClientError.notPNG(httpStatus: httpStatus, serviceMessage: serviceExceptionMessage(in: data))
        }
        throw RadarClientError.httpStatus(httpStatus)
    }

    /// The text of the first `<ServiceException>` in an OGC error document.
    public static func serviceExceptionMessage(in data: Data) -> String? {
        // `<ServiceException[\s>]` so it doesn't match the `<ServiceExceptionReport>` wrapper.
        guard let text = String(data: data, encoding: .utf8),
              let match = text.firstMatch(of: /<ServiceException(?:\s[^>]*)?>(.*?)<\/ServiceException>/.dotMatchesNewlines())
        else { return nil }
        let message = match.1.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }
}

/// The frame times a GetCapabilities document lists for a layer.
public struct CapabilitiesTimes: Sendable, Equatable {
    /// The `default` time (the newest frame), or the last listed time if there's no usable default.
    public let latest: RadarTime
    /// Every listed time plus `latest`, oldest first, without duplicates.
    public let all: [RadarTime]
}

/// Pulls the frame times out of a WMS 1.3.0 GetCapabilities document.
public enum CapabilitiesParser {
    public static func latestTime(in data: Data, layer: String) -> RadarTime? {
        times(in: data, layer: layer)?.latest
    }

    public static func times(in data: Data, layer: String) -> CapabilitiesTimes? {
        let delegate = Delegate(layer: layer)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        guard let dimension = delegate.match ?? delegate.firstTimeDimension else { return nil }
        // The list is in ascending order.
        let listed = dimension.values.split(separator: ",").compactMap { RadarTime(raw: String($0)) }
        guard let latest = dimension.defaultValue.flatMap(RadarTime.init(raw:)) ?? listed.last else { return nil }
        // `default` has no fractional seconds, so it doesn't match its list entry textually.
        var byDate: [Date: RadarTime] = [latest.date: latest]
        for time in listed where byDate[time.date] == nil {
            byDate[time.date] = time
        }
        return CapabilitiesTimes(latest: latest, all: byDate.values.sorted { $0.date < $1.date })
    }

    private struct TimeDimension {
        var defaultValue: String?
        var values = ""
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        let layer: String
        var match: TimeDimension?
        var firstTimeDimension: TimeDimension?

        private var currentLayerName: String?
        private var text = ""
        private var current: TimeDimension?

        init(layer: String) { self.layer = layer }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            if name == "Dimension", attributes["name"]?.lowercased() == "time" {
                current = TimeDimension(defaultValue: attributes["default"])
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "Name":
                currentLayerName = text.trimmingCharacters(in: .whitespacesAndNewlines)
            case "Dimension":
                guard var dimension = current else { break }
                dimension.values = text
                if firstTimeDimension == nil { firstTimeDimension = dimension }
                if currentLayerName == layer { match = dimension }
                current = nil
            default:
                break
            }
            text = ""
        }
    }
}
