import CoreLocation
import Observation
import Shared
import UIKit
import WidgetKit

@MainActor
@Observable
final class AppModel {
    private(set) var authorization: CLAuthorizationStatus
    private(set) var snapshot: RadarSnapshot?
    private(set) var image: UIImage?
    private(set) var debug: DebugRecord?
    private(set) var isRefreshing = false
    var onboardingDone: Bool {
        didSet { store.onboardingDone = onboardingDone }
    }
    var zoom: ZoomLevel {
        didSet {
            guard zoom != oldValue else { return }
            store.zoom = zoom
            Task { await refresh(force: true) }
        }
    }

    /// The app shows what the small (CarPlay) widget gets.
    static let resolution = TileResolution.standard

    /// Set with `-testLocation lat,lon`; replaces GPS for Simulator testing.
    let testLocation = FixedLocationProvider.fromLaunchArguments()

    private let store = SharedStore()
    private let cache = RadarCache.appGroup()
    private let locationService: LocationService
    private let pipeline: RadarPipeline

    init() {
        let locationService = LocationService(store: store)
        self.locationService = locationService
        authorization = locationService.authorizationStatus
        zoom = store.zoom
        onboardingDone = store.onboardingDone
        pipeline = RadarPipeline.live(location: testLocation ?? locationService, processName: "app")
        locationService.onAuthorizationChange = { [weak self] status in
            guard let self else { return }
            let changed = status != self.authorization
            self.authorization = status
            if changed, status == .authorizedWhenInUse || status == .authorizedAlways {
                Task { await self.refresh(force: true) }
            }
        }
        loadCached()
    }

    var needsOnboarding: Bool {
        testLocation == nil && !onboardingDone && authorization == .notDetermined
    }

    var locationDenied: Bool {
        testLocation == nil && (authorization == .denied || authorization == .restricted)
    }

    func requestLocationPermission() {
        onboardingDone = true
        locationService.requestWhenInUseAuthorization()
    }

    func refresh(force: Bool) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let result = await pipeline.refresh(force: force, zoom: zoom, resolution: Self.resolution)
        apply(result)
        // The widget re-reads the cache; its own refresh is throttled, so this costs no request.
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Seconds until another network request is allowed, if throttled.
    var throttleRemaining: Int? {
        guard snapshot?.throttled == true, let last = store.lastNetworkAttempt else { return nil }
        let remaining = Int(RadarPipeline.minimumInterval - Date().timeIntervalSince(last))
        return remaining > 0 ? remaining : nil
    }

    var lastNetworkAttempt: Date? { store.lastNetworkAttempt }
    var lastSuccessfulRefresh: Date? { store.lastSuccessfulRefresh }
    var cacheDirectory: URL { cache.directory }

    private func loadCached() {
        apply(pipeline.cachedSnapshot(zoom: zoom, resolution: Self.resolution))
    }

    private func apply(_ result: RadarSnapshot) {
        snapshot = result
        image = result.imageURL.flatMap { UIImage(contentsOfFile: $0.path) }
        debug = cache.readDebug()
    }
}
