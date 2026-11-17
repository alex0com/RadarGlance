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
    /// The widget preview in Settings, the map's starting width, and medium/large widgets
    /// set to Automatic. Changing it cuts the new zoom from the last radar download; no NOAA request.
    var phoneZoom: ZoomLevel {
        didSet {
            guard phoneZoom != oldValue else { return }
            store.phoneZoom = phoneZoom
            Task { await recompose() }
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Temperature and humidity on the widget (fetched by the widget from NWS).
    var showsWidgetWeather: Bool {
        didSet {
            guard showsWidgetWeather != oldValue else { return }
            store.showsWidgetWeather = showsWidgetWeather
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// The conditions the widget last fetched, for the debug panel.
    var widgetWeather: WeatherConditions? { store.weatherConditions }

    /// Small widgets set to Automatic (CarPlay shows only the small size).
    var carZoom: ZoomLevel {
        didSet {
            guard carZoom != oldValue else { return }
            store.carZoom = carZoom
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Same image size as the small (CarPlay) widget.
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
        phoneZoom = store.phoneZoom
        carZoom = store.carZoom
        showsWidgetWeather = store.showsWidgetWeather
        onboardingDone = store.onboardingDone
        pipeline = RadarPipeline.live(location: testLocation ?? locationService, processName: "app")
        locationService.onAuthorizationChange = { [weak self] status in
            guard let self else { return }
            let changed = status != self.authorization
            self.authorization = status
            if changed, self.isLocationAuthorized {
                Task { await self.refresh(force: true) }
            }
        }
        loadCached()
    }

    var needsOnboarding: Bool {
        testLocation == nil && !onboardingDone && authorization == .notDetermined
    }

    var isLocationAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
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
        let result = await pipeline.refresh(force: force, zoom: phoneZoom, resolution: Self.resolution)
        apply(result)
        // The widgets' own refresh is throttled right after this, so they cut their zoom
        // from this download without another request.
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func recompose() async {
        apply(await pipeline.recompose(zoom: phoneZoom, resolution: Self.resolution))
    }

    /// Seconds until another network request is allowed, if throttled.
    var throttleRemaining: Int? {
        guard snapshot?.throttled == true, let last = store.lastNetworkAttempt else { return nil }
        let remaining = Int(RadarPipeline.minimumInterval - Date().timeIntervalSince(last))
        return remaining > 0 ? remaining : nil
    }

    /// Where to center the radar map: the test location, else the last fix the radar used.
    var lastKnownCoordinate: CLLocationCoordinate2D? {
        if let fix = testLocation?.fix ?? store.cachedLocation {
            return CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude)
        }
        guard let metadata = snapshot?.metadata else { return nil }
        return CLLocationCoordinate2D(latitude: metadata.latitude, longitude: metadata.longitude)
    }

    var lastNetworkAttempt: Date? { store.lastNetworkAttempt }
    var lastSuccessfulRefresh: Date? { store.lastSuccessfulRefresh }
    var cacheDirectory: URL { cache.directory }

    private func loadCached() {
        apply(pipeline.cachedSnapshot(zoom: phoneZoom, resolution: Self.resolution))
    }

    private func apply(_ result: RadarSnapshot) {
        snapshot = result
        image = result.imageURL.flatMap { UIImage(contentsOfFile: $0.path) }
        debug = cache.readDebug()
    }
}
