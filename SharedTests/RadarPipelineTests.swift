import Foundation
import Testing
@testable import Shared

struct RadarPipelineTests {
    let clock = TestClock()
    let loader: MockLoader
    let location = MockLocation(.fix(MockLocation.oklahomaCity, stale: false))
    let renderer = MockRenderer()
    let cache = RadarCache(directory: temporaryDirectory())
    let store = SharedStore(defaults: temporaryDefaults())
    let pipeline: RadarPipeline

    init() throws {
        loader = try MockLoader.healthy()
        pipeline = RadarPipeline(
            client: RadarClient(loader: loader, now: { [clock] in clock.now }),
            location: location, renderer: renderer, cache: cache, store: store,
            processName: "test", now: { [clock] in clock.now }, availableMemory: { 0 })
    }

    @Test func successWritesCompositeWithRadarTime() async throws {
        let snapshot = await pipeline.refresh(force: false, zoom: .miles80, resolution: .standard)
        #expect(snapshot.failure == nil)
        #expect(!snapshot.throttled)
        let metadata = try #require(snapshot.metadata)
        #expect(metadata.radarTime == Date(timeIntervalSince1970: 1_794_706_091))
        #expect(metadata.fetchTime == clock.now)
        let png = try Data(contentsOf: try #require(snapshot.imageURL))
        #expect(RadarClient.isPNG(png))
        #expect(store.lastSuccessfulRefresh == clock.now)
        // The GetMap asks for exactly the frame the label shows.
        #expect(loader.requests.last?.url?.query?.contains("TIME=2026-11-15T01:28:11Z") == true)
    }

    @Test func throttlesWithin30SecondsEvenWhenForced() async {
        _ = await pipeline.refresh(force: false, zoom: .miles80, resolution: .standard)
        clock.advance(10)
        let second = await pipeline.refresh(force: false, zoom: .miles80, resolution: .standard)
        clock.advance(10)
        let third = await pipeline.refresh(force: true, zoom: .miles80, resolution: .standard)
        #expect(second.throttled && third.throttled)
        #expect(second.imageURL != nil)
        #expect(loader.mapRequestCount == 1)

        clock.advance(11)
        let fourth = await pipeline.refresh(force: true, zoom: .miles80, resolution: .standard)
        #expect(!fourth.throttled)
        #expect(loader.mapRequestCount == 2)
    }

    @Test func forcedRefreshBypassesCapabilitiesCache() async {
        _ = await pipeline.refresh(force: false, zoom: .miles80, resolution: .standard)
        clock.advance(31)
        _ = await pipeline.refresh(force: false, zoom: .miles80, resolution: .standard)
        #expect(loader.capabilitiesRequestCount == 1)
        clock.advance(31)
        _ = await pipeline.refresh(force: true, zoom: .miles80, resolution: .standard)
        #expect(loader.capabilitiesRequestCount == 2)
    }

    @Test func offlineFallsBackToCache() async throws {
        let first = await pipeline.refresh(force: false, zoom: .miles80, resolution: .standard)
        clock.advance(60)
        loader.setCapabilitiesResponse(.failure(URLError(.notConnectedToInternet)))
        loader.setMapResponse(.failure(URLError(.notConnectedToInternet)))
        let second = await pipeline.refresh(force: true, zoom: .miles80, resolution: .standard)
        #expect(second.failure == .network)
        #expect(second.imageURL == first.imageURL)
        #expect(second.metadata == first.metadata)
    }

    @Test func serviceErrorFallsBackToCache() async throws {
        let first = await pipeline.refresh(force: false, zoom: .miles80, resolution: .standard)
        clock.advance(60)
        loader.setMapResponse(.success((try Fixture.data("service-exception.xml"), 200)))
        let second = await pipeline.refresh(force: true, zoom: .miles80, resolution: .standard)
        #expect(second.failure == .service)
        #expect(second.metadata == first.metadata)
        #expect(cache.readDebug()?.outcome.contains("Could not find layer") == true)
    }

    @Test func failureWithNoCacheHasNoImage() async {
        loader.setMapResponse(.failure(URLError(.timedOut)))
        let snapshot = await pipeline.refresh(force: false, zoom: .miles80, resolution: .standard)
        #expect(snapshot.failure == .network)
        #expect(snapshot.imageURL == nil)
    }

    @Test func capabilitiesFailureStillFetchesWithoutTime() async throws {
        loader.setCapabilitiesResponse(.success((try Fixture.data("service-exception.xml"), 200)))
        let snapshot = await pipeline.refresh(force: false, zoom: .miles80, resolution: .standard)
        #expect(snapshot.failure == nil)
        #expect(snapshot.metadata?.radarTime == nil)
        #expect(snapshot.metadata?.displayTime == clock.now)
        #expect(loader.requests.last?.url?.query?.contains("TIME=") == false)
    }

    @Test func locationDenied() async {
        location.set(.denied)
        let snapshot = await pipeline.refresh(force: false, zoom: .miles80, resolution: .standard)
        #expect(snapshot.failure == .locationOff)
        #expect(loader.requests.isEmpty)
    }

    @Test func noCoverageOutsideConus() async {
        location.set(.fix(LocationFix(latitude: 61.2, longitude: -149.9, timestamp: clock.now), stale: false))
        let snapshot = await pipeline.refresh(force: false, zoom: .miles80, resolution: .standard)
        #expect(snapshot.failure == .noCoverage)
        #expect(loader.requests.isEmpty)
        #expect(store.lastNetworkAttempt == nil)
    }

    @Test func staleLocationIsRecorded() async {
        location.set(.fix(MockLocation.oklahomaCity, stale: true))
        let snapshot = await pipeline.refresh(force: false, zoom: .miles80, resolution: .standard)
        #expect(snapshot.metadata?.locationStale == true)
    }

    @Test func baseMapReusedWhenNearbyAndRerenderedAfterMoving() async {
        _ = await pipeline.refresh(force: false, zoom: .miles80, resolution: .standard)
        clock.advance(60)
        // ~1 mile north: well inside 10% of an 80 mi tile.
        location.set(.fix(LocationFix(latitude: 35.485, longitude: -97.52, timestamp: clock.now), stale: false))
        _ = await pipeline.refresh(force: false, zoom: .miles80, resolution: .standard)
        #expect(renderer.calls == 1)
        #expect(cache.readDebug()?.baseMapReused == true)

        clock.advance(60)
        // ~35 miles north: outside 10%.
        location.set(.fix(LocationFix(latitude: 35.98, longitude: -97.52, timestamp: clock.now), stale: false))
        _ = await pipeline.refresh(force: false, zoom: .miles80, resolution: .standard)
        #expect(renderer.calls == 2)
    }

    @Test func reusedBaseMapKeepsItsBoxAndRadarIsCenteredOnIt() async throws {
        _ = await pipeline.refresh(force: false, zoom: .miles80, resolution: .standard)
        let first = try #require(cache.readDebug())
        clock.advance(60)
        location.set(.fix(LocationFix(latitude: 35.485, longitude: -97.52, timestamp: clock.now), stale: false))
        _ = await pipeline.refresh(force: false, zoom: .miles80, resolution: .standard)
        let second = try #require(cache.readDebug())
        #expect(second.tileBBox == first.tileBBox)
        #expect(second.bbox == first.bbox)
    }

    @Test func lowMemorySkipsBaseMap() async throws {
        let lowMemory = RadarPipeline(
            client: RadarClient(loader: loader), location: location, renderer: renderer,
            cache: cache, store: store, processName: "test", now: { [clock] in clock.now },
            availableMemory: { 4 * 1024 * 1024 })
        let snapshot = await lowMemory.refresh(force: false, zoom: .miles80, resolution: .standard)
        #expect(snapshot.failure == nil)
        #expect(renderer.calls == 0)
    }

    @Test func concurrentRefreshesMakeOneRequest() async {
        let other = RadarPipeline(
            client: RadarClient(loader: loader), location: location, renderer: renderer,
            cache: cache, store: store, processName: "test2", now: { [clock] in clock.now },
            availableMemory: { 0 })
        async let a = pipeline.refresh(force: false, zoom: .miles80, resolution: .standard)
        async let b = other.refresh(force: false, zoom: .miles80, resolution: .high)
        let results = await [a, b]
        #expect(results.filter(\.throttled).count == 1)
        #expect(loader.mapRequestCount == 1)
    }

    @Test func highResolutionComposite() async throws {
        let snapshot = await pipeline.refresh(force: false, zoom: .miles80, resolution: .high)
        #expect(snapshot.metadata?.resolution == .high)
        #expect(snapshot.imageURL?.lastPathComponent == "composite-80-1024.png")
    }

    /// Every zoom is cut from one download, so the request doesn't depend on the zoom.
    @Test func radarRequestCoversFootprintRegardlessOfZoom() async throws {
        _ = await pipeline.refresh(force: false, zoom: .miles40, resolution: .standard)
        let expected = MercatorBox(center: .init(latitude: 35.47, longitude: -97.52), widthMiles: RadarFootprint.miles)
        let query = try #require(loader.requests.last?.url?.query)
        #expect(query.contains("BBOX=\(expected.bboxString)"))
        #expect(query.contains("WIDTH=1280&HEIGHT=1280"))
    }

    @Test func zoomChangeRecomposesWithoutNetwork() async throws {
        let first = await pipeline.refresh(force: false, zoom: .miles80, resolution: .standard)
        let requests = loader.requests.count
        clock.advance(5)
        for zoom in [ZoomLevel.miles40, .miles160] {
            let snapshot = await pipeline.recompose(zoom: zoom, resolution: .standard)
            #expect(snapshot.failure == nil)
            #expect(snapshot.metadata?.zoom == zoom)
            #expect(snapshot.metadata?.fetchTime == first.metadata?.fetchTime)
            #expect(snapshot.imageURL?.lastPathComponent == "composite-\(zoom.rawValue)-512.png")
        }
        #expect(loader.requests.count == requests)
        #expect(renderer.calls == 3)
    }

    @Test func throttledRefreshAtNewZoomIsCutFromLastDownload() async {
        _ = await pipeline.refresh(force: false, zoom: .miles80, resolution: .standard)
        clock.advance(5)
        let snapshot = await pipeline.refresh(force: true, zoom: .miles40, resolution: .standard)
        #expect(snapshot.throttled)
        #expect(snapshot.metadata?.zoom == .miles40)
        #expect(loader.mapRequestCount == 1)
    }

    @Test func recomposeWithoutAnyDownloadHasNoImage() async {
        let snapshot = await pipeline.recompose(zoom: .miles40, resolution: .standard)
        #expect(snapshot.imageURL == nil)
        #expect(loader.requests.isEmpty)
    }

    /// Moving farther than the footprint margin means the cached radar can't cover the tile.
    @Test func recomposeAfterMovingFarFallsBackToCachedComposite() async {
        let first = await pipeline.refresh(force: false, zoom: .miles160, resolution: .standard)
        location.set(.fix(LocationFix(latitude: 36.2, longitude: -97.52, timestamp: clock.now), stale: false))
        let snapshot = await pipeline.recompose(zoom: .miles160, resolution: .standard)
        #expect(snapshot.metadata == first.metadata)
        #expect(cache.readDebug()?.outcome == "no cached radar covers this area")
    }

    @Test func lowMemoryDowngradesHighResolution() async throws {
        let tight = RadarPipeline(
            client: RadarClient(loader: loader), location: location, renderer: renderer,
            cache: cache, store: store, processName: "test", now: { [clock] in clock.now },
            availableMemory: { 16 * 1024 * 1024 })
        let snapshot = await tight.refresh(force: false, zoom: .miles80, resolution: .high)
        #expect(snapshot.metadata?.resolution == .standard)
        #expect(snapshot.imageURL?.lastPathComponent == "composite-80-512.png")
        #expect(renderer.calls == 1)
    }

    @Test func throttledHighResolutionIsCutFromLastDownload() async {
        _ = await pipeline.refresh(force: false, zoom: .miles80, resolution: .standard)
        clock.advance(5)
        let snapshot = await pipeline.refresh(force: false, zoom: .miles80, resolution: .high)
        #expect(snapshot.throttled)
        #expect(snapshot.metadata?.resolution == .high)
        #expect(loader.mapRequestCount == 1)
    }

    // MARK: Backup source

    @Test func fallsBackToNowCoastWhenOpengeoFails() async throws {
        loader.setMapResponse(.success((Data("<html>503</html>".utf8), 503)))
        loader.setNowCoastMapResponse(.success((try Fixture.data("radar-sample.png"), 200)))
        let snapshot = await pipeline.refresh(force: false, zoom: .miles80, resolution: .standard)
        #expect(snapshot.failure == nil)
        // nowCOAST's own newest frame, from its capabilities.
        #expect(snapshot.metadata?.radarTime == RadarTime(raw: "2026-11-17T16:16:11Z")?.date)
        #expect(loader.requests.last?.url?.host() == "nowcoast.noaa.gov")
        let debug = try #require(cache.readDebug())
        #expect(debug.source == "nowCOAST")
        #expect(debug.outcome.hasPrefix("fell back: opengeo"))
    }

    @Test func opengeoOnlyNeverUsesBackup() async {
        var settings = MapSettings()
        settings.radarSource = .opengeo
        store.mapSettings = settings
        loader.setMapResponse(.success((Data("<html>503</html>".utf8), 503)))
        let snapshot = await pipeline.refresh(force: false, zoom: .miles80, resolution: .standard)
        #expect(snapshot.failure == .service)
        #expect(loader.nowCoastRequestCount == 0)
    }

    @Test func nowCoastOnlySkipsOpengeo() async throws {
        var settings = MapSettings()
        settings.radarSource = .nowCOAST
        store.mapSettings = settings
        let snapshot = await pipeline.refresh(force: false, zoom: .miles80, resolution: .standard)
        #expect(snapshot.failure == nil)
        #expect(loader.requests.allSatisfy { $0.url?.host() == "nowcoast.noaa.gov" })
    }

    @Test func offlineDoesNotTryBackup() async {
        loader.setCapabilitiesResponse(.failure(URLError(.notConnectedToInternet)))
        loader.setMapResponse(.failure(URLError(.notConnectedToInternet)))
        let snapshot = await pipeline.refresh(force: false, zoom: .miles80, resolution: .standard)
        #expect(snapshot.failure == .network)
        #expect(loader.nowCoastRequestCount == 0)
    }
}
