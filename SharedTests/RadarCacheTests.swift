import Foundation
import Testing
@testable import Shared

struct RadarCacheTests {
    let cache = RadarCache(directory: temporaryDirectory())
    let metadata = RadarMetadata(
        radarTime: Date(timeIntervalSince1970: 1_794_706_091), fetchTime: Date(timeIntervalSince1970: 1_794_706_100),
        latitude: 35.47, longitude: -97.52, locationStale: true, zoom: .miles80)

    @Test func roundTrip() throws {
        let png = try Fixture.data("radar-sample.png")
        try cache.writeComposite(png, metadata: metadata)
        #expect(cache.readMetadata(zoom: .miles80) == metadata)
        #expect(try Data(contentsOf: cache.compositeURL(zoom: .miles80)) == png)
        #expect(cache.readMetadata(zoom: .miles40) == nil)
    }

    @Test func latestAcrossZooms() throws {
        let png = try Fixture.data("radar-sample.png")
        try cache.writeComposite(png, metadata: metadata)
        var newer = metadata
        newer.zoom = .miles160
        newer.fetchTime += 60
        try cache.writeComposite(png, metadata: newer)
        #expect(cache.latestMetadata() == newer)
    }

    @Test func metadataWithoutImageIsIgnored() throws {
        try cache.writeComposite(try Fixture.data("radar-sample.png"), metadata: metadata)
        try FileManager.default.removeItem(at: cache.compositeURL(zoom: .miles80))
        #expect(cache.readMetadata(zoom: .miles80) == nil)
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
        let attributes = try FileManager.default.attributesOfItem(atPath: cache.compositeURL(zoom: .miles80).path)
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
        try cache.writeBaseMap(png, info: info, zoom: .miles40)
        let read = try #require(cache.readBaseMap(zoom: .miles40))
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

    @Test func zoomDefaultsTo80() {
        #expect(SharedStore(defaults: temporaryDefaults()).zoom == .miles80)
    }
}
