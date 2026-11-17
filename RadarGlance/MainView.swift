import CoreLocation
import Shared
import SwiftUI

/// Full-screen animated radar map. Opened by launching the app or tapping the widget.
struct MainView: View {
    /// The widget opens the app with this URL.
    static let radarURL = URL(string: "radarglance://radar")!

    @Environment(AppModel.self) private var model
    @Environment(RadarLoopModel.self) private var loop
    @Environment(MapSettingsModel.self) private var mapSettings
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingSettings = false
    @State private var centerRequest: CenterRequest?
    @State private var playbackBarHeight: CGFloat = 0

    var body: some View {
        RadarMapView(
            frameSet: loop.frameSet,
            frameIndex: loop.currentIndex,
            settings: mapSettings.settings,
            showsUserLocation: model.testLocation == nil && model.isLocationAuthorized,
            pin: model.testLocation.map { CLLocationCoordinate2D(latitude: $0.fix.latitude, longitude: $0.fix.longitude) },
            center: centerRequest,
            bottomInset: playbackBarHeight,
            onSettle: { loop.mapSettled(visible: $0, viewPixels: $1) }
        )
        .ignoresSafeArea()
        .overlay(alignment: .topTrailing) { mapButtons }
        .overlay(alignment: .top) {
            if model.locationDenied {
                locationBanner.padding(.horizontal).padding(.trailing, 56)
            }
        }
        .safeAreaInset(edge: .bottom) {
            PlaybackBar()
                .padding(.horizontal)
                .padding(.bottom, 4)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { playbackBarHeight = $0 }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .onAppear {
            centerOnUser(animated: false)
            #if DEBUG
            applyScreenshotArguments()
            #endif
        }
        .onChange(of: mapSettings.settings, initial: true) { _, settings in
            loop.rendering = RadarRendering(colorScheme: settings.colorScheme,
                                            hidesLightReturns: settings.hidesLightReturns)
            loop.animationSpeed = settings.animationSpeed
            loop.sourcePreference = settings.radarSource
        }
        .onChange(of: model.lastKnownCoordinate?.latitude) {
            // First launch: no position until the first fix arrives.
            if centerRequest == nil { centerOnUser(animated: true) }
        }
        .onOpenURL { url in
            guard url == Self.radarURL else { return }
            showingSettings = false
            centerOnUser(animated: true)
        }
        .task {
            await model.refresh(force: false)
        }
        .task(id: scenePhase) {
            // While the app is open, pick up each new NOAA frame.
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                loop.refresh()
                try? await Task.sleep(for: RadarLoopModel.refreshInterval)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await model.refresh(force: false) }
            }
        }
    }

    #if DEBUG
    /// For README screenshots: `-mapWidthMiles 2500` starts wider than the zoom settings allow,
    /// `-showSettings` opens Settings on launch.
    private func applyScreenshotArguments() {
        let defaults = UserDefaults.standard
        if let coordinate = model.lastKnownCoordinate, defaults.double(forKey: "mapWidthMiles") > 0 {
            centerRequest = CenterRequest(coordinate: coordinate, widthMiles: defaults.double(forKey: "mapWidthMiles"),
                                          animated: false)
        }
        showingSettings = defaults.bool(forKey: "showSettings")
    }
    #endif

    private func centerOnUser(animated: Bool) {
        guard let coordinate = model.lastKnownCoordinate else { return }
        centerRequest = CenterRequest(coordinate: coordinate, widthMiles: model.phoneZoom.miles, animated: animated)
    }

    private var mapButtons: some View {
        VStack(spacing: 10) {
            mapButton("Settings", systemImage: "gearshape") { showingSettings = true }
            mapButton("Refresh radar", systemImage: "arrow.clockwise", isBusy: loop.isLoading || model.isRefreshing) {
                loop.refresh(force: true)
                Task { await model.refresh(force: true) }
            }
            if model.lastKnownCoordinate != nil {
                mapButton("Center on my location", systemImage: "location") { centerOnUser(animated: true) }
            }
        }
        .padding(.trailing)
    }

    private func mapButton(_ title: String, systemImage: String, isBusy: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if isBusy {
                    ProgressView()
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .semibold))
                }
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(title)
    }

    private var locationBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Location is off for Radar Glance").font(.headline)
            Text("The CarPlay widget needs While Using or Always.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Play/pause, a scrubber across the frames, and the shown frame's time.
private struct PlaybackBar: View {
    @Environment(RadarLoopModel.self) private var loop

    var body: some View {
        VStack(spacing: 6) {
            if let frames = loop.frameSet?.frames, let frame = loop.currentFrame {
                HStack(spacing: 12) {
                    Button {
                        loop.togglePlaying()
                    } label: {
                        Image(systemName: loop.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(loop.isPlaying ? "Pause" : "Play")
                    .disabled(frames.count < 2)

                    if frames.count > 1 {
                        Slider(value: scrubber(count: frames.count), in: 0...Double(frames.count - 1), step: 1)
                            .accessibilityLabel("Radar time")
                            .accessibilityValue(frame.time.date.formatted(date: .omitted, time: .shortened))
                    } else {
                        Spacer()
                    }

                    FrameTime(time: frame.time.date, isNewest: loop.currentIndex == frames.count - 1)
                }
            } else {
                HStack {
                    if let failure = loop.failure {
                        Text(failure.message)
                    } else {
                        ProgressView()
                        Text("Loading radar…")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 36)
            }
            if loop.sourcePreference == .automatic, loop.activeSource == .nowCOAST {
                Label("opengeo is unavailable; showing the nowCOAST backup", systemImage: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if loop.isLoading && loop.frameSet != nil {
                ProgressView(value: loop.loadProgress)
                    .progressViewStyle(.linear)
            } else if let failure = loop.failure, loop.frameSet != nil {
                Text(failure.message).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
    }

    private func scrubber(count: Int) -> Binding<Double> {
        Binding(
            get: { Double(loop.currentIndex) },
            set: { loop.select(index: Int($0.rounded())) }
        )
    }
}

private struct FrameTime: View {
    let time: Date
    let isNewest: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let age = RadarAge(dataTime: time, now: context.date)
            Text(time, format: .dateTime.hour().minute())
                .font(.subheadline.weight(isNewest ? .bold : .regular).monospacedDigit())
                .foregroundStyle(isNewest ? color(for: age) : .secondary)
                .frame(minWidth: 64, alignment: .trailing)
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
