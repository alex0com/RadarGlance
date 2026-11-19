import MapKit
import Shared
import SwiftUI

/// Asks the map to move to `coordinate` (or the live user location, when shown). A new `id`
/// triggers a move; the same request applied twice does nothing.
struct CenterRequest: Equatable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let widthMiles: Double
    var animated = true

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// A pannable, zoomable map with the current radar frame, and optionally highways, drawn over it.
struct RadarMapView: UIViewRepresentable {
    let frameSet: RadarFrameSet?
    let frameIndex: Int
    let settings: MapSettings
    /// Shows the live location dot. Off with `-testLocation`, which uses `pin` instead.
    let showsUserLocation: Bool
    let pin: CLLocationCoordinate2D?
    let center: CenterRequest?
    /// Height of controls over the bottom of the map; MapKit keeps its attribution above it.
    var bottomInset: CGFloat = 0
    /// Called when the map has stopped moving, with the visible area and its size in pixels.
    let onSettle: (MKMapRect, CGSize) -> Void

    static let settleDelay: Duration = .milliseconds(400)

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.showsScale = true
        map.showsUserLocation = showsUserLocation
        // Far enough out to fit the whole coverage area on a portrait screen.
        map.cameraZoomRange = MKMapView.CameraZoomRange(minCenterCoordinateDistance: 5_000,
                                                        maxCenterCoordinateDistance: 20_000_000)
        if center == nil {
            map.setVisibleMapRect(RadarRegion.conus.mapRect, animated: false)
        }
        context.coordinator.onSettle = onSettle
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSettle = onSettle
        map.showsUserLocation = showsUserLocation
        if coordinator.appliedBottomInset != bottomInset {
            coordinator.appliedBottomInset = bottomInset
            // Assign the whole value: reading `layoutMargins` includes the safe area, so writing
            // back a modified copy would add the safe area again on every update.
            map.layoutMargins = UIEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
        }
        coordinator.apply(settings, to: map)
        coordinator.updatePin(pin, on: map)
        if let center, center != coordinator.appliedCenter {
            coordinator.appliedCenter = center
            coordinator.move(map, to: center, useUserLocation: showsUserLocation)
        }
        coordinator.show(frameSet, index: frameIndex, on: map)
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        var onSettle: ((MKMapRect, CGSize) -> Void)?
        var appliedCenter: CenterRequest?
        var appliedBottomInset: CGFloat?
        private var appliedSettings: MapSettings?
        private var overlay: RadarOverlay?
        /// Loaded from the bundle the first time highways are shown.
        private var highwayOverlays: [HighwayOverlay] = []
        private var highwayLoad: Task<Void, Never>?
        private var wantsHighways = false
        private var highwayDetail = HighwayDetail.full
        private var pinAnnotation: MKPointAnnotation?
        private var settleTask: Task<Void, Never>?

        func move(_ map: MKMapView, to request: CenterRequest, useUserLocation: Bool) {
            let live = useUserLocation ? map.userLocation.location?.coordinate : nil
            let meters = request.widthMiles * MercatorBox.metersPerMile
            let region = MKCoordinateRegion(center: live ?? request.coordinate,
                                            latitudinalMeters: meters, longitudinalMeters: meters)
            map.setRegion(region, animated: request.animated)
        }

        /// Everything on screen, including under the controls. `visibleMapRect` leaves out the
        /// layout margins, but the radar should reach the screen edges.
        static func visibleArea(of map: MKMapView) -> MKMapRect {
            let bounds = map.bounds
            let topLeft = MKMapPoint(map.convert(CGPoint(x: bounds.minX, y: bounds.minY), toCoordinateFrom: map))
            let bottomRight = MKMapPoint(map.convert(CGPoint(x: bounds.maxX, y: bounds.maxY), toCoordinateFrom: map))
            return MKMapRect(x: topLeft.x, y: topLeft.y,
                             width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
        }

        func apply(_ settings: MapSettings, to map: MKMapView) {
            let old = appliedSettings
            appliedSettings = settings
            if old?.appearance != settings.appearance {
                map.overrideUserInterfaceStyle = switch settings.appearance {
                case .system: .unspecified
                case .light: .light
                case .dark: .dark
                }
            }
            if old?.style != settings.style {
                map.preferredConfiguration = Self.configuration(for: settings.style)
            }
            if old?.showsHighways != settings.showsHighways {
                showHighways(settings.showsHighways, on: map)
            }
            if old?.radarOpacity != settings.radarOpacity || old?.smoothRadar != settings.smoothRadar,
               let overlay {
                overlay.smooth = settings.smoothRadar
                if let renderer = map.renderer(for: overlay) {
                    renderer.alpha = settings.radarOpacity
                    renderer.setNeedsDisplay()
                }
            }
        }

        private static func configuration(for style: MapSettings.Style) -> MKMapConfiguration {
            switch style {
            case .muted, .standard:
                let configuration = MKStandardMapConfiguration(elevationStyle: .flat,
                                                               emphasisStyle: style == .muted ? .muted : .default)
                configuration.pointOfInterestFilter = .excludingAll
                return configuration
            case .satellite:
                let configuration = MKHybridMapConfiguration(elevationStyle: .flat)
                configuration.pointOfInterestFilter = .excludingAll
                return configuration
            }
        }

        private func showHighways(_ show: Bool, on map: MKMapView) {
            wantsHighways = show
            guard show else {
                map.removeOverlays(highwayOverlays)
                return
            }
            if !highwayOverlays.isEmpty {
                map.addOverlays(highwayOverlays, level: .aboveRoads)
                return
            }
            guard highwayLoad == nil else { return }
            highwayLoad = Task { [weak self, weak map] in
                let overlays = await Task.detached(priority: .userInitiated) { HighwayOverlay.loadBundled() }.value
                guard let self, let map else { return }
                self.highwayOverlays = overlays
                // Added after any radar, so they draw above it.
                if self.wantsHighways { map.addOverlays(overlays, level: .aboveRoads) }
            }
        }

        /// Thinner highway lines as the map zooms out, so they don't bury the radar.
        private func updateHighwayDetail(on map: MKMapView) {
            let area = Self.visibleArea(of: map)
            let miles = area.width * MKMetersPerMapPointAtLatitude(MKMapPoint(x: area.midX, y: area.midY).coordinate.latitude)
                / MercatorBox.metersPerMile
            let detail = HighwayDetail(visibleMiles: miles)
            guard detail != highwayDetail else { return }
            highwayDetail = detail
            for overlay in highwayOverlays {
                guard let renderer = map.renderer(for: overlay) as? MKMultiPolylineRenderer else { continue }
                overlay.style(renderer, detail: detail)
                renderer.setNeedsDisplay()
            }
        }

        func updatePin(_ coordinate: CLLocationCoordinate2D?, on map: MKMapView) {
            guard let coordinate else {
                if let pinAnnotation { map.removeAnnotation(pinAnnotation) }
                pinAnnotation = nil
                return
            }
            if pinAnnotation == nil {
                let annotation = MKPointAnnotation()
                map.addAnnotation(annotation)
                pinAnnotation = annotation
            }
            pinAnnotation?.coordinate = coordinate
        }

        func show(_ frameSet: RadarFrameSet?, index: Int, on map: MKMapView) {
            guard let frameSet, frameSet.frames.indices.contains(index) else { return }
            if overlay?.frameSetID != frameSet.id {
                // A new set replaces the old one only once it's fully loaded, so the radar
                // never blanks while the user pans.
                let newOverlay = RadarOverlay(frameSet: frameSet, index: index)
                newOverlay.smooth = appliedSettings?.smoothRadar ?? false
                // Keep highway lines above the rain.
                if let highway = highwayOverlays.first, map.overlays.contains(where: { $0 === highway }) {
                    map.insertOverlay(newOverlay, below: highway)
                } else {
                    map.addOverlay(newOverlay, level: .aboveRoads)
                }
                if let overlay { map.removeOverlay(overlay) }
                overlay = newOverlay
            } else if let overlay, overlay.index != index {
                overlay.index = index
                map.renderer(for: overlay)?.setNeedsDisplay()
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let highway = overlay as? HighwayOverlay {
                return highway.makeRenderer(detail: highwayDetail)
            }
            guard let overlay = overlay as? RadarOverlay else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = RadarOverlayRenderer(overlay: overlay)
            renderer.alpha = appliedSettings?.radarOpacity ?? MapSettings().radarOpacity
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard annotation === pinAnnotation else { return nil }
            let view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "pin")
            view.markerTintColor = .systemBlue
            view.glyphImage = UIImage(systemName: "location.fill")
            return view
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            updateHighwayDetail(on: mapView)
            settleTask?.cancel()
            settleTask = Task { [weak self, weak mapView] in
                try? await Task.sleep(for: RadarMapView.settleDelay)
                guard !Task.isCancelled, let self, let mapView, mapView.bounds.width > 0 else { return }
                let scale = mapView.traitCollection.displayScale
                let pixels = CGSize(width: mapView.bounds.width * scale, height: mapView.bounds.height * scale)
                self.onSettle?(Self.visibleArea(of: mapView), pixels)
            }
        }
    }
}

/// The radar frames of one `RadarFrameSet`, drawn one at a time over their shared rect.
final class RadarOverlay: NSObject, MKOverlay, @unchecked Sendable {
    let frameSetID: UUID
    let boundingMapRect: MKMapRect
    let coordinate: CLLocationCoordinate2D
    private let images: [CGImage]
    private let lock = NSLock()
    private var _index: Int
    private var _smooth = false

    init(frameSet: RadarFrameSet, index: Int) {
        frameSetID = frameSet.id
        boundingMapRect = frameSet.rect
        coordinate = MKMapPoint(x: frameSet.rect.midX, y: frameSet.rect.midY).coordinate
        images = frameSet.frames.map(\.image)
        _index = index
    }

    /// Set on the main thread; read by the renderer on MapKit's drawing threads.
    var index: Int {
        get { lock.withLock { _index } }
        set { lock.withLock { _index = newValue } }
    }

    /// Smooth the radar cells instead of drawing them as blocks.
    var smooth: Bool {
        get { lock.withLock { _smooth } }
        set { lock.withLock { _smooth = newValue } }
    }

    var currentImage: CGImage? {
        let index = index
        return images.indices.contains(index) ? images[index] : nil
    }
}

final class RadarOverlayRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let overlay = overlay as? RadarOverlay, let image = overlay.currentImage else { return }
        let rect = rect(for: overlay.boundingMapRect)
        context.saveGState()
        // By default no smoothing, like the widget: radar cells stay crisp.
        context.interpolationQuality = overlay.smooth ? .high : .none
        // CGContext draws images bottom-up; the renderer's coordinates run top-down.
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
}

/// One layer of the bundled highway lines: a dark casing or the light line on top of it, so they
/// read on light, dark and satellite maps.
final class HighwayOverlay: MKMultiPolyline, @unchecked Sendable {
    enum Layer { case casing, line }

    let highwayClass: HighwayClass
    let layer: Layer

    init(_ polylines: [MKPolyline], highwayClass: HighwayClass, layer: Layer) {
        self.highwayClass = highwayClass
        self.layer = layer
        super.init(polylines)
    }

    func makeRenderer(detail: HighwayDetail) -> MKMultiPolylineRenderer {
        let renderer = MKMultiPolylineRenderer(multiPolyline: self)
        renderer.lineCap = .round
        renderer.lineJoin = .round
        style(renderer, detail: detail)
        return renderer
    }

    func style(_ renderer: MKMultiPolylineRenderer, detail: HighwayDetail) {
        let width = detail.lineWidth(for: highwayClass)
        switch layer {
        case .casing:
            renderer.strokeColor = UIColor.black.withAlphaComponent(0.5)
            renderer.lineWidth = width + HighwayDetail.casingExtraWidth
            renderer.alpha = width > 0 && detail.showsCasing ? 1 : 0
        case .line:
            renderer.strokeColor = highwayClass == .interstate
                ? UIColor.white.withAlphaComponent(0.95) : UIColor(white: 0.88, alpha: 0.85)
            renderer.lineWidth = width
            renderer.alpha = width == 0 ? 0 : detail.lineOpacity
        }
    }

    /// Casings under lines, interstates over freeways. Empty if the resource is missing.
    nonisolated static func loadBundled() -> [HighwayOverlay] {
        guard let url = Bundle.main.url(forResource: "highways", withExtension: "bin"),
              let data = try? Data(contentsOf: url),
              let lines = try? HighwayData.parse(data)
        else { return [] }
        var polylines: [HighwayClass: [MKPolyline]] = [:]
        for line in lines {
            polylines[line.highwayClass, default: []].append(MKPolyline(coordinates: line.coordinates,
                                                                         count: line.coordinates.count))
        }
        let freeways = polylines[.freeway] ?? [], interstates = polylines[.interstate] ?? []
        return [
            HighwayOverlay(freeways, highwayClass: .freeway, layer: .casing),
            HighwayOverlay(interstates, highwayClass: .interstate, layer: .casing),
            HighwayOverlay(freeways, highwayClass: .freeway, layer: .line),
            HighwayOverlay(interstates, highwayClass: .interstate, layer: .line),
        ]
    }
}
