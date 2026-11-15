import Foundation
import Testing
@testable import Shared

struct RadarCacheTests {
    let cache = RadarCache(directory: temporaryDirectory())
    let metadata = RadarMetadata(
        radarTime: Date(timeIntervalSince1970: 1_794_706_091), fetchTime: Date(timeIntervalSince1970: 1_794_706_100),
        latitude: 35.47, longitude: -97.52, locationStale: true, zoom: .miles80, resolution: .standard)

    @Test func roundTrip() throws {
        let png = try Fixture.data("radar-sample.png")
        try cache.writeComposite(png, metadata: metadata)
        #expect(cache.readMetadata(zoom: .miles80, resolution: .standard) == metadata)
        #expect(try Data(contentsOf: cache.compositeURL(zoom: .miles80, resolution: .standard)) == png)
        #expect(cache.readMetadata(zoom: .miles40, resolution: .standard) == nil)
    }

    @Test func bestMetadataPrefersExactThenSameZoomThenNewest() throws {
        let png = try Fixture.data("radar-sample.png")
        try cache.writeComposite(png, metadata: metadata)                       // 80 mi, 512, t
        var high = metadata
        high.resolution = .high
        high.fetchTime += 30
        try cache.writeComposite(png, metadata: high)                           // 80 mi, 1024, t+30
        var otherZoom = metadata
        otherZoom.zoom = .miles160
        otherZoom.fetchTime += 60
        try cache.writeComposite(png, metadata: otherZoom)                      // 160 mi, 512, t+60

        #expect(cache.bestMetadata(zoom: .miles80, resolution: .standard) == metadata)
        #expect(cache.bestMetadata(zoom: .miles80, resolution: .high) == high)
        #expect(cache.bestMetadata(zoom: .miles160, resolution: .high) == otherZoom)
        #expect(cache.bestMetadata(zoom: .miles40, resolution: .standard) == otherZoom)
    }

    @Test func metadataWithoutImageIsIgnored() throws {
        try cache.writeComposite(try Fixture.data("radar-sample.png"), metadata: metadata)
        try FileManager.default.removeItem(at: cache.compositeURL(zoom: .miles80, resolution: .standard))
        #expect(cache.readMetadata(zoom: .miles80, resolution: .standard) == nil)
    }

    @Test func displayTimeFallsBackToFetchTime() {
        var m = metadata
        #expect(m.displayTime == m.radarTime)
        m.radarTime = nil
        #expect(m.displayTime == m.fetchTime)
    }

    @Test func writesUseFirstUnlockProtection() throws {
        // `.complete` would make the files unreadable to the widget while the phone is locked.
        #expect(RadarCache.writeOptions.contains(.completeFileProtectionUntilFirstUserAuthentication))
        #expect(!RadarCache.writeOptions.contains(.completeFileProtection))
        #expect(RadarCache.protection == .completeUntilFirstUserAuthentication)
    }

    @Test func fileProtectionAttribute() throws {
        try cache.writeComposite(try Fixture.data("radar-sample.png"), metadata: metadata)
        let attributes = try FileManager.default.attributesOfItem(atPath: cache.compositeURL(zoom: .miles80, resolution: .standard).path)
        let protection = attributes[.protectionKey] as? FileProtectionType
        #if targetEnvironment(simulator)
        // The Simulator's file system doesn't implement data protection classes, so the
        // attribute may be absent; when present it must be right.
        if let protection { #expect(protection == .completeUntilFirstUserAuthentication) }
        #else
        #expect(protection == .completeUntilFirstUserAuthentication)
        #endif
    }

    @Test func baseMapRoundTrip() throws {
        let png = try Fixture.data("radar-sample.png")
        let info = BaseMapInfo(box: MercatorBox(minX: 1, minY: 2, width: 3), createdAt: Date(timeIntervalSince1970: 1_800_000_000), alignmentErrorPixels: 0.25)
        try cache.writeBaseMap(png, info: info, zoom: .miles40, resolution: .high)
        let read = try #require(cache.readBaseMap(zoom: .miles40, resolution: .high))
        #expect(read.info == info)
        #expect(read.png == png)
    }
}

struct RadarAgeTests {
    let t = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func thresholds() {
        #expect(RadarAge(dataTime: t, now: t + 9 * 60) == .fresh)
        #expect(RadarAge(dataTime: t, now: t + 11 * 60) == .aging)
        #expect(RadarAge(dataTime: t, now: t + 21 * 60) == .old)
    }
}

struct SharedStoreTests {
    @Test func forceRefreshConsumedOnce() {
        let store = SharedStore(defaults: temporaryDefaults())
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(!store.consumeForceRefreshRequest(now: t))
        store.forceRefreshRequestedAt = t
        #expect(store.consumeForceRefreshRequest(now: t + 1))
        #expect(!store.consumeForceRefreshRequest(now: t + 2))
        store.forceRefreshRequestedAt = t + 10
        #expect(store.consumeForceRefreshRequest(now: t + 11))
    }

    @Test func networkSlotClaimAndRelease() {
        let store = SharedStore(defaults: temporaryDefaults())
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let slot = store.claimNetworkSlot(now: t, interval: 30)
        #expect(slot != nil)
        #expect(store.claimNetworkSlot(now: t + 29, interval: 30) == nil)
        store.releaseNetworkSlot(slot!)
        #expect(store.lastNetworkAttempt == nil)
        #expect(store.claimNetworkSlot(now: t + 29, interval: 30) != nil)
        #expect(store.claimNetworkSlot(now: t + 60, interval: 30) != nil)
    }

    @Test func zoomDefaultsTo80() {
        #expect(SharedStore(defaults: temporaryDefaults()).zoom == .miles80)
    }
}
