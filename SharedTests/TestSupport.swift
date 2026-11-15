import Foundation
@testable import Shared

private final class BundleToken {}

enum Fixture {
    static func data(_ name: String) throws -> Data {
        let bundle = Bundle(for: BundleToken.self)
        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
        guard let url = bundle.url(forResource: parts[0], withExtension: parts[1]) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: name])
        }
        return try Data(contentsOf: url)
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { value = start }

    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

/// Answers GetCapabilities with the recon fixture and GetMap with `mapResponse`.
final class MockLoader: HTTPDataLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private var _mapResponse: Result<(Data, Int), Error>
    private var _capabilitiesResponse: Result<(Data, Int), Error>

    init(mapResponse: Result<(Data, Int), Error>, capabilitiesResponse: Result<(Data, Int), Error>) {
        _mapResponse = mapResponse
        _capabilitiesResponse = capabilitiesResponse
    }

    static func healthy() throws -> MockLoader {
        MockLoader(mapResponse: .success((try Fixture.data("radar-sample.png"), 200)),
                   capabilitiesResponse: .success((try Fixture.data("conus-capabilities.xml"), 200)))
    }

    var requests: [URLRequest] { lock.withLock { _requests } }
    var mapRequestCount: Int { requests.filter { $0.url!.query!.contains("REQUEST=GetMap") }.count }
    var capabilitiesRequestCount: Int { requests.filter { $0.url!.query!.contains("REQUEST=GetCapabilities") }.count }

    func setMapResponse(_ response: Result<(Data, Int), Error>) { lock.withLock { _mapResponse = response } }
    func setCapabilitiesResponse(_ response: Result<(Data, Int), Error>) { lock.withLock { _capabilitiesResponse = response } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let result: Result<(Data, Int), Error> = lock.withLock {
            _requests.append(request)
            return request.url!.query!.contains("REQUEST=GetMap") ? _mapResponse : _capabilitiesResponse
        }
        let (data, status) = try result.get()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (data, response)
    }
}

final class MockLocation: LocationProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _result: LocationResult

    init(_ result: LocationResult) { _result = result }

    static let oklahomaCity = LocationFix(latitude: 35.47, longitude: -97.52, timestamp: Date(timeIntervalSince1970: 1_800_000_000))

    func set(_ result: LocationResult) { lock.withLock { _result = result } }
    func currentLocation() async -> LocationResult { lock.withLock { _result } }
}

final class MockRenderer: BaseMapRendering, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }

    func render(box: MercatorBox, size: Int) async throws -> BaseMap {
        lock.withLock { _calls += 1 }
        return BaseMap(png: try Fixture.data("radar-sample.png"), alignmentErrorPixels: 0)
    }
}

func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "RadarGlanceTests-\(UUID().uuidString)")
}

func temporaryDefaults() -> UserDefaults {
    UserDefaults(suiteName: "RadarGlanceTests-\(UUID().uuidString)")!
}
