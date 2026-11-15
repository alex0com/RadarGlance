import CoreLocation
import Foundation
import MapKit
import os

public enum RadarFailure: String, Error, Codable, Sendable, Equatable {
    case locationOff
    case locationUnavailable
    case noCoverage
    case network
    case service

    /// Short text for the widget. Never asks the driver to pick up the phone.
    public var message: String {
        switch self {
        case .locationOff: "Location off"
        case .locationUnavailable: "No location"
        case .noCoverage: "No radar coverage here"
        case .network: "Offline"
        case .service: "Radar unavailable"
        }
    }

    /// Whether a cached image would mislead (wrong place, or the user turned location off).
    public var hidesImage: Bool {
        switch self {
        case .locationOff, .noCoverage: true
        case .locationUnavailable, .network, .service: false
        }
    }
}

public struct RadarSnapshot: Sendable, Equatable {
    /// Path of the composite PNG, if there is one.
    public var imageURL: URL?
    public var metadata: RadarMetadata?
    public var failure: RadarFailure?
    /// The refresh was skipped because the last network attempt was under 30 s ago.
    public var throttled: Bool

    public init(imageURL: URL?, metadata: RadarMetadata?, failure: RadarFailure?, throttled: Bool) {
        self.imageURL = imageURL
        self.metadata = metadata
        self.failure = failure
        self.throttled = throttled
    }
}

/// The area each radar download covers: wider than the largest zoom so every zoom can be cut
/// from it, with 20 mi of margin for GPS drift and base map reuse. 1280 px keeps 250 m per
/// pixel, finer than NOAA's 1 km grid, so even the 40 mi view loses no radar detail.
public enum RadarFootprint {
    public static let miles: Double = 200
    public static let pixels = 1280
}

/// Location → radar frame → base map → composite → cache.
public actor RadarPipeline {
    /// NOAA is called at most once per 30 s per device, forced or not.
    public static let minimumInterval: TimeInterval = 30
    /// Reuse the cached base map while the user stays within this fraction of the tile
    /// width from its center.
    public static let baseMapReuseFraction = 0.10
    public static let baseMapMaxAge: TimeInterval = 7 * 24 * 3600
    /// Below this much headroom, skip the map snapshot and draw on a plain tile.
    public static let lowMemoryBytes = 8 * 1024 * 1024
    /// Below this much headroom, a 1024 px request is rendered at 512 px instead.
    public static let highResolutionMemoryBytes = 24 * 1024 * 1024

    private let client: RadarClient
    private let location: LocationProviding
    private let renderer: BaseMapRendering
    private let cache: RadarCache
    private let store: SharedStore
    private let processName: String
    private let now: @Sendable () -> Date
    private let availableMemory: @Sendable () -> Int

    public init(client: RadarClient, location: LocationProviding, renderer: BaseMapRendering,
                cache: RadarCache, store: SharedStore, processName: String,
                now: @escaping @Sendable () -> Date = { Date() },
                availableMemory: @escaping @Sendable () -> Int = { os_proc_available_memory() }) {
        self.client = client
        self.location = location
        self.renderer = renderer
        self.cache = cache
        self.store = store
        self.processName = processName
        self.now = now
        self.availableMemory = availableMemory
    }

    /// The real services, sharing state through the App Group.
    public static func live(location: LocationProviding, processName: String) -> RadarPipeline {
        RadarPipeline(client: RadarClient(), location: location, renderer: BaseMapRenderer(),
                      cache: .appGroup(), store: SharedStore(), processName: processName)
    }

    /// The last cached image, without touching the network or location.
    public nonisolated func cachedSnapshot(zoom: ZoomLevel, resolution: TileResolution) -> RadarSnapshot {
        snapshotFromCache(zoom: zoom, resolution: resolution, failure: nil, throttled: false)
    }

    /// Downloads new radar (unless the last request was under 30 s ago) and composes the
    /// requested zoom. When throttled, the zoom is cut from the last download instead.
    public func refresh(force: Bool, zoom: ZoomLevel, resolution: TileResolution) async -> RadarSnapshot {
        await run(network: force ? .forced : .normal, zoom: zoom, resolution: resolution)
    }

    /// Composes `zoom` from the last radar download without contacting NOAA. Use when only
    /// the zoom changed.
    public func recompose(zoom: ZoomLevel, resolution: TileResolution) async -> RadarSnapshot {
        await run(network: .none, zoom: zoom, resolution: resolution)
    }

    private enum NetworkMode {
        case none, normal, forced
    }

    private func run(network: NetworkMode, zoom: ZoomLevel, resolution requestedResolution: TileResolution) async -> RadarSnapshot {
        let start = now()
        var debug = DebugRecord(process: processName, attemptTime: start, forced: network == .forced, outcome: "")
        debug.zoom = zoom.rawValue
        defer { cache.writeDebug(debug) }
        let fromCache = { (failure: RadarFailure?, throttled: Bool) in
            self.snapshotFromCache(zoom: zoom, resolution: requestedResolution, failure: failure, throttled: throttled)
        }

        // Claimed before the first suspension so concurrent refreshes (several widgets) can't
        // both pass the check.
        var slot: NetworkSlot?
        if network != .none {
            slot = store.claimNetworkSlot(now: start, interval: Self.minimumInterval)
        }
        let throttled = network != .none && slot == nil

        let fix: LocationFix
        let locationStale: Bool
        switch await location.currentLocation() {
        case .denied:
            release(slot)
            debug.outcome = "location off"
            return fromCache(.locationOff, false)
        case .unavailable:
            release(slot)
            debug.outcome = "no location"
            return fromCache(.locationUnavailable, false)
        case let .fix(value, stale):
            fix = value
            locationStale = stale
        }

        guard let region = RadarRegion.region(latitude: fix.latitude, longitude: fix.longitude) else {
            release(slot)
            debug.outcome = "no coverage at \(fix.latitude), \(fix.longitude)"
            return fromCache(.noCoverage, false)
        }

        recordMemory("start", into: &debug)
        var resolution = requestedResolution
        let available = availableMemory()
        if resolution == .high, available > 0, available < Self.highResolutionMemoryBytes {
            resolution = .standard
            recordMemory("low memory: 1024 px → 512 px", into: &debug)
        }
        debug.resolution = resolution.pixels

        // Reuse the cached base map if the user hasn't moved far; the composite then covers
        // the base map's box so the two still line up.
        let coordinate = CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude)
        var box = MercatorBox(center: coordinate, widthMiles: zoom.miles)
        var baseMapPNG: Data?
        if let cached = cache.readBaseMap(zoom: zoom, resolution: resolution),
           cached.info.box.isNearCenter(MKMapPoint(coordinate), fraction: Self.baseMapReuseFraction),
           start.timeIntervalSince(cached.info.createdAt) < Self.baseMapMaxAge {
            box = cached.info.box
            baseMapPNG = cached.png
            debug.baseMapReused = true
            debug.alignmentErrorPixels = cached.info.alignmentErrorPixels
        }
        debug.tileBBox = box.bboxString

        var radar = cache.readRadar()
        var failure: RadarFailure?
        if slot != nil {
            switch await download(region: region, around: box.center, force: network == .forced, debug: &debug) {
            case let .success(fresh):
                radar = fresh
                store.lastSuccessfulRefresh = start
            case let .failure(error):
                failure = error
            }
        }
        debug.radarReused = slot == nil || failure != nil

        guard let radar, radar.frame.box.contains(box) else {
            if debug.outcome.isEmpty {
                debug.outcome = throttled ? "throttled; no cached radar covers this area" : "no cached radar covers this area"
            }
            return fromCache(failure, throttled)
        }

        if baseMapPNG == nil {
            if available > 0 && available < Self.lowMemoryBytes {
                debug.baseMapReused = false
                recordMemory("skipped base map (low memory)", into: &debug)
            } else {
                do {
                    let base = try await renderer.render(box: box, size: resolution.pixels)
                    baseMapPNG = base.png
                    debug.baseMapReused = false
                    debug.alignmentErrorPixels = base.alignmentErrorPixels
                    try? cache.writeBaseMap(base.png, info: BaseMapInfo(
                        box: box, createdAt: start, alignmentErrorPixels: base.alignmentErrorPixels),
                        zoom: zoom, resolution: resolution)
                    recordMemory("base map rendered", into: &debug)
                } catch {
                    // Radar on a plain dark tile is still useful.
                    recordMemory("base map failed: \(error.localizedDescription)", into: &debug)
                }
            }
        }

        let png = RadarCompositor.compose(.init(
            baseMapPNG: baseMapPNG, radarPNG: radar.png, radarBox: radar.frame.box, box: box,
            user: fix, userIsStale: locationStale, size: resolution.pixels))
        recordMemory("composited", into: &debug)

        let metadata = RadarMetadata(
            radarTime: radar.frame.radarTime, fetchTime: radar.frame.fetchTime,
            latitude: fix.latitude, longitude: fix.longitude,
            locationStale: locationStale, zoom: zoom, resolution: resolution)
        do {
            try cache.writeComposite(png, metadata: metadata)
        } catch {
            debug.outcome = "cache write failed: \(error.localizedDescription)"
            return fromCache(.service, throttled)
        }
        if debug.outcome.isEmpty {
            switch (slot != nil, radar.frame.radarTime != nil) {
            case (true, true): debug.outcome = "fetched"
            case (true, false): debug.outcome = "fetched (no TIME; label uses fetch time)"
            case (false, _): debug.outcome = throttled ? "throttled; cut from last download" : "cut from last download"
            }
        }
        return RadarSnapshot(imageURL: cache.compositeURL(zoom: zoom, resolution: resolution), metadata: metadata,
                             failure: failure, throttled: throttled)
    }

    /// One GetCapabilities (unless cached) + one GetMap covering `RadarFootprint` around
    /// `center`. Saves the result as the shared radar frame.
    private func download(region: RadarRegion, around center: MKMapPoint, force: Bool,
                          debug: inout DebugRecord) async -> Result<(png: Data, frame: RadarFrame), RadarFailure> {
        let start = now()
        let radarBox = MercatorBox(center: center.coordinate, widthMiles: RadarFootprint.miles)
        debug.bbox = radarBox.bboxString

        let radarTime: RadarTime?
        do {
            radarTime = try await client.latestRadarTime(region: region, force: force)
        } catch {
            if Self.isOffline(error) {
                debug.outcome = "offline: \(error.localizedDescription)"
                return .failure(.network)
            }
            // Without TIME the image is still the newest frame; the label falls back to fetch time.
            radarTime = nil
        }
        debug.radarTimeRaw = radarTime?.raw

        do {
            let image = try await client.fetchImage(region: region, box: radarBox, time: radarTime,
                                                    size: RadarFootprint.pixels)
            debug.wmsURL = image.url.absoluteString
            debug.httpStatus = image.httpStatus
            recordMemory("radar downloaded", into: &debug)
            let frame = RadarFrame(box: radarBox, radarTime: radarTime, fetchTime: start)
            try? cache.writeRadar(image.png, frame: frame)
            return .success((image.png, frame))
        } catch {
            debug.wmsURL = await client.lastRequestURL?.absoluteString
            debug.httpStatus = await client.lastHTTPStatus
            debug.outcome = "radar failed: \(Self.describe(error))"
            return .failure(Self.isOffline(error) ? .network : .service)
        }
    }

    // MARK: Helpers

    /// See `RadarCache.bestMetadata` for which cached composite is chosen.
    private nonisolated func snapshotFromCache(zoom: ZoomLevel, resolution: TileResolution,
                                               failure: RadarFailure?, throttled: Bool) -> RadarSnapshot {
        let metadata = cache.bestMetadata(zoom: zoom, resolution: resolution)
        return RadarSnapshot(imageURL: metadata.map { cache.compositeURL(zoom: $0.zoom, resolution: $0.resolution) },
                             metadata: metadata, failure: failure, throttled: throttled)
    }

    private func release(_ slot: NetworkSlot?) {
        if let slot { store.releaseNetworkSlot(slot) }
    }

    private func recordMemory(_ step: String, into debug: inout DebugRecord) {
        debug.memory.append(MemoryReading(step: step, availableMB: Double(availableMemory()) / 1_048_576))
    }

    static func isOffline(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
             .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
            return true
        default:
            return false
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case let RadarClientError.notPNG(status, message):
            "not a PNG (HTTP \(status)): \(message ?? "no message")"
        case let RadarClientError.httpStatus(status):
            "HTTP \(status)"
        default:
            error.localizedDescription
        }
    }
}
