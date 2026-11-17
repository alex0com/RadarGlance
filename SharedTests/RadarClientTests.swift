import CoreLocation
import Foundation
import MapKit
import Testing
@testable import Shared

struct RadarClientTests {
    let okcBox = MercatorBox(center: CLLocationCoordinate2D(latitude: 35.47, longitude: -97.52), widthMiles: 80)

    @Test func getMapURLSnapshot() throws {
        let time = try #require(RadarTime(raw: "2026-11-15T01:28:11Z"))
        let box = MercatorBox(minX: 0, minY: 0, width: MercatorBox.worldWidth)
        let url = RadarClient.getMapURL(region: .conus, box: box, time: time)
        #expect(url.absoluteString == "https://opengeo.ncep.noaa.gov/geoserver/conus/conus_bref_qcd/ows"
            + "?SERVICE=WMS&VERSION=1.3.0&REQUEST=GetMap&LAYERS=conus_bref_qcd&STYLES="
            + "&CRS=EPSG:3857&BBOX=-20037508.343,-20037508.343,20037508.343,20037508.343"
            + "&WIDTH=512&HEIGHT=512&FORMAT=image/png&TRANSPARENT=true&TIME=2026-11-15T01:28:11Z")
    }

    @Test func nonSquareGetMapURL() throws {
        let time = try #require(RadarTime(raw: "2026-11-15T01:28:11Z"))
        let rect = MKMapRect(x: okcBox.minX, y: okcBox.minY, width: okcBox.width, height: okcBox.width * 2)
        let url = RadarClient.getMapURL(region: .conus, mapRect: rect, width: 300, height: 600, time: time)
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        #expect(value("WIDTH") == "300")
        #expect(value("HEIGHT") == "600")
        #expect(value("BBOX") == MercatorBox.bboxString(for: rect))
        #expect(value("TIME") == "2026-11-15T01:28:11Z")
        // Same west, north and east edges as the square box; the south edge is one box further down.
        let square = okcBox.bboxMeters
        let tall = MercatorBox.bboxMeters(for: rect)
        #expect(tall.minX == square.minX && tall.maxX == square.maxX && tall.maxY == square.maxY)
        #expect(tall.minY < square.minY)
    }

    @Test func getMapURLWithoutTime() {
        let url = RadarClient.getMapURL(region: .conus, box: okcBox, time: nil)
        #expect(!url.absoluteString.contains("TIME="))
    }

    @Test func capabilitiesURL() {
        #expect(RadarClient.capabilitiesURL(region: .conus).absoluteString
            == "https://opengeo.ncep.noaa.gov/geoserver/conus/conus_bref_qcd/ows?SERVICE=WMS&VERSION=1.3.0&REQUEST=GetCapabilities")
    }

    @Test func parsesDefaultTimeFromCapabilities() throws {
        let time = try #require(CapabilitiesParser.latestTime(in: try Fixture.data("conus-capabilities.xml"), layer: "conus_bref_qcd"))
        #expect(time.raw == "2026-11-15T01:28:11Z")
        #expect(time.date == Date(timeIntervalSince1970: 1_794_706_091))
    }

    @Test func fallsBackToLastListedTime() throws {
        let xml = """
            <WMS_Capabilities><Capability><Layer><Layer><Name>conus_bref_qcd</Name>
            <Dimension name="time" units="ISO8601">2026-11-14T23:30:09.000Z,2026-11-15T01:26:11.000Z</Dimension>
            </Layer></Layer></Capability></WMS_Capabilities>
            """
        let time = try #require(CapabilitiesParser.latestTime(in: Data(xml.utf8), layer: "conus_bref_qcd"))
        #expect(time.raw == "2026-11-15T01:26:11.000Z")
    }

    @Test func parsesFractionalSeconds() throws {
        let time = try #require(RadarTime(raw: "2026-11-14T23:30:09.000Z"))
        #expect(time.date == Date(timeIntervalSince1970: 1_794_699_009))
    }

    @Test func acceptsRealPNG() throws {
        try RadarClient.validatePNG(try Fixture.data("radar-sample.png"), httpStatus: 200)
    }

    @Test func rejectsServiceExceptionXMLWithStatus200() throws {
        let xml = try Fixture.data("service-exception.xml")
        #expect(throws: RadarClientError.notPNG(httpStatus: 200, serviceMessage: "Could not find layer conus:nope")) {
            try RadarClient.validatePNG(xml, httpStatus: 200)
        }
    }

    @Test func rejectsPNGWithErrorStatus() throws {
        #expect(throws: RadarClientError.httpStatus(503)) {
            try RadarClient.validatePNG(try Fixture.data("radar-sample.png"), httpStatus: 503)
        }
    }

    @Test func rejectsEmptyBody() {
        #expect(throws: RadarClientError.notPNG(httpStatus: 200, serviceMessage: nil)) {
            try RadarClient.validatePNG(Data(), httpStatus: 200)
        }
    }

    @Test func fetchImageThrowsOnXML() async throws {
        let loader = try MockLoader.healthy()
        loader.setMapResponse(.success((try Fixture.data("service-exception.xml"), 200)))
        let client = RadarClient(loader: loader)
        await #expect(throws: RadarClientError.self) {
            _ = try await client.fetchImage(region: .conus, box: okcBox, time: nil)
        }
    }

    @Test func sendsUserAgent() async throws {
        let loader = try MockLoader.healthy()
        _ = try await RadarClient(loader: loader).fetchImage(region: .conus, box: okcBox, time: nil)
        #expect(loader.requests.first?.value(forHTTPHeaderField: "User-Agent") == RadarClient.userAgent)
        #expect(loader.requests.first?.timeoutInterval == 15)
    }

    @Test func capabilitiesCachedForTwoMinutes() async throws {
        let loader = try MockLoader.healthy()
        let clock = TestClock()
        let client = RadarClient(loader: loader, now: { clock.now })

        _ = try await client.latestRadarTime(region: .conus, force: false)
        clock.advance(60)
        _ = try await client.latestRadarTime(region: .conus, force: false)
        #expect(loader.capabilitiesRequestCount == 1)

        _ = try await client.latestRadarTime(region: .conus, force: true)
        #expect(loader.capabilitiesRequestCount == 2)

        clock.advance(121)
        _ = try await client.latestRadarTime(region: .conus, force: false)
        #expect(loader.capabilitiesRequestCount == 3)
    }
}
