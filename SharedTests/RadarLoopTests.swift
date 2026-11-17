import CoreGraphics
import CoreLocation
import Foundation
import MapKit
import Testing
@testable import Shared

struct RadarLoopTests {
    /// ~2 h of frames, one about every 2 min, as NOAA lists them.
    let fixtureTimes: [RadarTime]

    init() throws {
        let times = try #require(CapabilitiesParser.times(in: try Fixture.data("conus-capabilities.xml"), layer: "conus_bref_qcd"))
        fixtureTimes = times.all
    }

    // MARK: Capabilities

    @Test func parsesAllListedTimes() throws {
        // 60 listed values; `default` is the last one without fractional seconds, so no extra.
        #expect(fixtureTimes.count == 60)
        #expect(fixtureTimes.first?.raw == "2026-11-14T23:30:09.000Z")
        #expect(fixtureTimes.last?.raw == "2026-11-15T01:28:11Z")
        #expect(zip(fixtureTimes, fixtureTimes.dropFirst()).allSatisfy { $0.date < $1.date })
    }

    @Test func allTimesIncludesDefaultMissingFromList() throws {
        let xml = """
            <WMS_Capabilities><Capability><Layer><Layer><Name>conus_bref_qcd</Name>
            <Dimension name="time" default="2026-11-15T01:30:00Z">2026-11-15T01:26:11.000Z,2026-11-15T01:28:11.000Z</Dimension>
            </Layer></Layer></Capability></WMS_Capabilities>
            """
        let times = try #require(CapabilitiesParser.times(in: Data(xml.utf8), layer: "conus_bref_qcd"))
        #expect(times.all.map(\.raw) == ["2026-11-15T01:26:11.000Z", "2026-11-15T01:28:11.000Z", "2026-11-15T01:30:00Z"])
        #expect(times.latest.raw == "2026-11-15T01:30:00Z")
    }

    // MARK: Frame selection

    @Test(arguments: [(LoopLength.minutes30, 8), (.hour1, 11), (.hours2, 13)])
    func selectsFramesForLoopLength(length: LoopLength, count: Int) throws {
        let frames = RadarLoop.selectFrames(from: fixtureTimes, length: length)
        #expect(frames.count == count)
        #expect(frames.last == fixtureTimes.last)
        // Every frame is a listed time; a made-up TIME would return a blank PNG.
        #expect(frames.allSatisfy { fixtureTimes.contains($0) })
        for (older, newer) in zip(frames, frames.dropFirst()) {
            let gap = newer.date.timeIntervalSince(older.date)
            #expect(abs(gap - length.step) <= 150, "gap \(gap) s")
        }
        let span = try #require(frames.last).date.timeIntervalSince(try #require(frames.first).date)
        #expect(span <= length.duration + 60)
    }

    @Test func skipsGapsInsteadOfInventingTimes() throws {
        let newest = try #require(RadarTime(raw: "2026-11-15T01:28:11Z"))
        let older = try #require(RadarTime(raw: "2026-11-15T00:58:00.000Z"))
        let frames = RadarLoop.selectFrames(from: [older, newest], length: .hour1)
        #expect(frames == [older, newest])
    }

    @Test func noTimesNoFrames() {
        #expect(RadarLoop.selectFrames(from: [], length: .hour1).isEmpty)
    }

    // MARK: Request area

    let okc = MKMapPoint(CLLocationCoordinate2D(latitude: 35.47, longitude: -97.52))

    private func rect(around point: MKMapPoint, width: Double, height: Double) -> MKMapRect {
        MKMapRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
    }

    @Test func requestRectPadsVisibleArea() throws {
        let visible = rect(around: okc, width: 100_000, height: 200_000)
        let request = try #require(RadarLoop.requestRect(visible: visible, region: .conus))
        #expect(abs(request.width - 150_000) < 1e-6)
        #expect(abs(request.height - 300_000) < 1e-6)
        #expect(abs(request.midX - visible.midX) < 1e-6)
        #expect(abs(request.midY - visible.midY) < 1e-6)
    }

    @Test func requestRectClipsToCoverage() throws {
        let conus = RadarRegion.conus.mapRect
        let visible = rect(around: MKMapPoint(x: conus.minX, y: conus.midY), width: 1_000_000, height: 1_000_000)
        let request = try #require(RadarLoop.requestRect(visible: visible, region: .conus))
        #expect(request.minX == conus.minX)
        #expect(conus.contains(request))
    }

    @Test func noRequestOutsideCoverage() {
        let tokyo = MKMapPoint(CLLocationCoordinate2D(latitude: 35.68, longitude: 139.69))
        #expect(RadarLoop.requestRect(visible: rect(around: tokyo, width: 100_000, height: 100_000), region: .conus) == nil)
    }

    @Test func pixelSizeMatchesScreen() {
        let visible = rect(around: okc, width: 100_000, height: 200_000)
        let size = RadarLoop.pixelSize(for: rect(around: okc, width: 50_000, height: 100_000), visible: visible,
                                       viewPixels: CGSize(width: 1000, height: 2000))
        #expect(size.width == 500)
        #expect(size.height == 1000)
    }

    @Test func pixelSizeIsCapped() {
        let visible = rect(around: okc, width: 100_000, height: 200_000)
        let size = RadarLoop.pixelSize(for: rect(around: okc, width: 150_000, height: 300_000), visible: visible,
                                       viewPixels: CGSize(width: 1179, height: 2358))
        #expect(size.height == RadarLoop.maxPixels)
        #expect(size.width == RadarLoop.maxPixels / 2)
    }

    @Test func reloadOnlyWhenNeeded() throws {
        let visible = rect(around: okc, width: 100_000, height: 200_000)
        let loaded = try #require(RadarLoop.requestRect(visible: visible, region: .conus))
        func needsReload(_ visible: MKMapRect) -> Bool {
            RadarLoop.needsReload(loaded: loaded, loadedVisibleWidth: 100_000, visible: visible, region: .conus)
        }
        #expect(!needsReload(visible))
        #expect(!needsReload(visible.offsetBy(dx: 20_000, dy: 0)))
        #expect(needsReload(visible.offsetBy(dx: 40_000, dy: 0)))
        #expect(needsReload(rect(around: okc, width: 40_000, height: 80_000)))
    }

    // MARK: Settings

    @Test func loopLengthSetting() {
        let store = SharedStore(defaults: temporaryDefaults())
        #expect(store.loopLength == .hour1)
        store.loopLength = .hours2
        #expect(store.loopLength == .hours2)
    }
}
