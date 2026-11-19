import MapKit
import Shared
import SwiftUI

/// The radar loop over a map. The Digital Crown zooms and dragging pans (the Map handles both).
/// watchOS maps can't draw overlays, so the radar and highways are layers over the map, moved with it.
struct WatchRadarView: View {
    static let settleDelay: Duration = .milliseconds(400)

    @Environment(RadarLoopModel.self) private var loop
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    @State private var location = LocationService(store: SharedStore(defaults: .standard))
    @State private var position = MapCameraPosition.rect(RadarRegion.conus.mapRect)
    /// Where map points are on screen right now.
    @State private var transform: MapTransform?
    @State private var highways: HighwayGeometry?
    @State private var mapSize: CGSize = .zero
    @State private var visible: MKMapRect?
    @State private var settleTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                // Same zoom range as the phone's map; zoomed out, all of the coverage area fits.
                Map(position: $position,
                    bounds: MapCameraBounds(minimumDistance: 5_000, maximumDistance: 20_000_000),
                    interactionModes: [.pan, .zoom]) {
                    UserAnnotation()
                }
                .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
                .overlay(alignment: .topLeading) {
                    if let transform {
                        radarImage(transform)
                        // Above the rain, as on the phone. Equatable: not redrawn for each loop frame.
                        if let highways {
                            HighwayLayer(geometry: highways, transform: transform).equatable()
                        }
                    }
                }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { mapSize = $0 }
                .onMapCameraChange(frequency: .continuous) { context in
                    transform = MapTransform(proxy: proxy, visible: context.rect)
                }
                .onMapCameraChange(frequency: .onEnd) { context in settle(visible: context.rect) }
            }
            .ignoresSafeArea()
            .toolbar {
                // Top left: the clock is top right.
                ToolbarItem(placement: .topBarLeading) {
                    Button("Center on my location", systemImage: "location.fill") {
                        Task { await centerOnUser(force: true) }
                    }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button(loop.isPlaying ? "Pause" : "Play",
                           systemImage: loop.isPlaying ? "pause.fill" : "play.fill") {
                        loop.togglePlaying()
                    }
                    .disabled((loop.frameSet?.frames.count ?? 0) < 2)
                    Spacer()
                    // On a dark backing, so it reads over the map's labels and the rain.
                    status
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: .capsule)
                }
            }
        }
        .task {
            location.onAuthorizationChange = { _ in Task { await centerOnUser(force: false) } }
            if location.authorizationStatus == .notDetermined {
                location.requestWhenInUseAuthorization()
            }
            await centerOnUser(force: false)
        }
        .task {
            highways = await Task.detached(priority: .userInitiated) { HighwayGeometry.loadBundled() }.value
        }
        .task(id: scenePhase) {
            // While the app is open, pick up each new NOAA frame.
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                loop.refresh()
                try? await Task.sleep(for: RadarLoopModel.refreshInterval)
            }
        }
    }

    @ViewBuilder
    private func radarImage(_ transform: MapTransform) -> some View {
        if let image = loop.currentFrame?.image, let rect = loop.frameSet?.rect {
            let radarFrame = transform.rect(rect)
            // No smoothing, like the phone's default: radar cells stay crisp.
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.none)
                .frame(width: radarFrame.width, height: radarFrame.height)
                .offset(x: radarFrame.minX, y: radarFrame.minY)
                .opacity(MapSettings().radarOpacity)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var status: some View {
        if let visible, RadarLoop.coveredRect(visible: visible, region: .conus) == nil {
            Text(RadarFailure.noCoverage.message).font(.footnote).foregroundStyle(.secondary)
        } else if let failure = loop.failure {
            Text(failure.message).font(.footnote).foregroundStyle(.orange)
        } else if let frames = loop.frameSet?.frames, let frame = loop.currentFrame {
            FrameTime(time: frame.time.date, isNewest: loop.currentIndex == frames.count - 1)
        } else if loop.isLoading {
            ProgressView()
        }
    }

    /// Loads frames for the new area once the map has stopped moving; each crown turn ends a move.
    private func settle(visible rect: MKMapRect) {
        visible = rect
        settleTask?.cancel()
        settleTask = Task {
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled, mapSize.width > 0 else { return }
            loop.mapSettled(visible: rect, viewPixels: CGSize(width: mapSize.width * displayScale,
                                                              height: mapSize.height * displayScale))
        }
    }

    /// Width of the map when centered on the user. `-mapWidthMiles 600` overrides it in Debug builds.
    private static var startWidthMiles: Double {
        #if DEBUG
        let miles = UserDefaults.standard.double(forKey: "mapWidthMiles")
        if miles > 0 { return miles }
        #endif
        return ZoomLevel.phoneDefault.miles
    }

    /// Centers on the watch's position. Unless `force`, only while the user hasn't moved the map.
    private func centerOnUser(force: Bool) async {
        guard case .fix(let fix, _) = await location.currentLocation(), force || !position.positionedByUser
        else { return }
        let meters = Self.startWidthMiles * MercatorBox.metersPerMile
        position = .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude),
            latitudinalMeters: meters, longitudinalMeters: meters))
    }
}

/// The shown frame's time, tinted by age when it's the newest.
private struct FrameTime: View {
    let time: Date
    let isNewest: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let age = RadarAge(dataTime: time, now: context.date)
            Text(time, format: .dateTime.hour().minute())
                .font(.footnote.weight(isNewest ? .bold : .regular).monospacedDigit())
                .foregroundStyle(isNewest ? color(for: age) : .secondary)
        }
    }

    private func color(for age: RadarAge) -> Color {
        switch age {
        case .fresh: .primary
        case .aging: .orange
        case .old: .red
        }
    }
}
