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

    @Test func reusedBaseMapUsesItsOwnBoxForRadar() async throws {
        _ = await pipeline.refresh(force: false, zoom: .miles80, resolution: .standard)
        let firstBBox = try #require(cache.readDebug()?.bbox)
        clock.advance(60)
        location.set(.fix(LocationFix(latitude: 35.485, longitude: -97.52, timestamp: clock.now), stale: false))
        _ = await pipeline.refresh(force: false, zoom: .miles80, resolution: .standard)
        #expect(cache.readDebug()?.bbox == firstBBox)
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

    @Test func highResolutionRequests1024() async throws {
        let snapshot = await pipeline.refresh(force: false, zoom: .miles80, resolution: .high)
        #expect(snapshot.metadata?.resolution == .high)
        #expect(snapshot.imageURL?.lastPathComponent == "composite-80-1024.png")
        #expect(loader.requests.last?.url?.query?.contains("WIDTH=1024&HEIGHT=1024") == true)
    }

    @Test func lowMemoryDowngradesHighResolution() async throws {
        let tight = RadarPipeline(
            client: RadarClient(loader: loader), location: location, renderer: renderer,
            cache: cache, store: store, processName: "test", now: { [clock] in clock.now },
            availableMemory: { 16 * 1024 * 1024 })
        let snapshot = await tight.refresh(force: false, zoom: .miles80, resolution: .high)
        #expect(snapshot.metadata?.resolution == .standard)
        #expect(loader.requests.last?.url?.query?.contains("WIDTH=512") == true)
        #expect(renderer.calls == 1)
    }

    @Test func throttledHighResolutionFallsBackToStandardCache() async {
        _ = await pipeline.refresh(force: false, zoom: .miles80, resolution: .standard)
        clock.advance(5)
        let snapshot = await pipeline.refresh(force: false, zoom: .miles80, resolution: .high)
        #expect(snapshot.throttled)
        #expect(snapshot.metadata?.resolution == .standard)
        #expect(snapshot.imageURL != nil)
    }
}
