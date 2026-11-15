import Shared
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.locationDenied {
                        locationBanner
                    }
                    radarImage
                    statusLine
                    ZoomPicker(title: "iPhone", systemImage: "iphone", selection: $model.phoneZoom)
                    ZoomPicker(title: "CarPlay", systemImage: "car", selection: $model.carZoom)
                    Text("CarPlay zoom applies to small widgets, the only size CarPlay shows. To use a different zoom for a Home Screen widget, touch and hold it and choose Edit Widget.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button {
                        Task { await model.refresh(force: true) }
                    } label: {
                        Label(model.isRefreshing ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isRefreshing)

                    NavigationLink {
                        CarPlayHelpView()
                    } label: {
                        Label("How to add it to CarPlay", systemImage: "car")
                    }

                    DebugPanel()
                }
                .padding()
            }
            .navigationTitle("Radar Glance")
        }
        .task {
            await model.refresh(force: false)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await model.refresh(force: false) }
            }
        }
    }

    private var radarImage: some View {
        ZStack {
            Color(white: 0.08)
            if let image = model.image, model.snapshot?.failure?.hidesImage != true {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .overlay(alignment: .bottomTrailing) {
                        if let zoom = model.snapshot?.metadata?.zoom {
                            GeometryReader { geometry in
                                ScaleBar(zoom: zoom, tileSide: geometry.size.width)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                                    .padding(10)
                            }
                        }
                    }
            } else if let failure = model.snapshot?.failure {
                Text(failure.message).foregroundStyle(.white)
            } else if model.isRefreshing {
                ProgressView().tint(.white)
            } else {
                Text("No radar yet").foregroundStyle(.white)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var statusLine: some View {
        HStack {
            if let metadata = model.snapshot?.metadata {
                let age = RadarAge(dataTime: metadata.displayTime, now: Date())
                Text("Radar \(metadata.displayTime.formatted(date: .omitted, time: .shortened))")
                    .foregroundStyle(age == .fresh ? Color.primary : age == .aging ? Color.orange : Color.red)
                if metadata.radarTime == nil {
                    Text("(fetch time)").foregroundStyle(.secondary)
                }
                if metadata.locationStale {
                    Text("· last known location").foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let failure = model.snapshot?.failure, !failure.hidesImage {
                Text(failure.message).foregroundStyle(.orange)
            } else if let wait = model.throttleRemaining {
                Text("Wait \(wait) s").foregroundStyle(.secondary)
            }
        }
        .font(.subheadline.monospacedDigit())
    }

    private var locationBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Location is off for Radar Glance").font(.headline)
            Text("The radar and the CarPlay widget need While Using or Always.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
    }

    private var accessibilityText: String {
        guard let time = model.snapshot?.metadata?.displayTime else { return "Weather radar" }
        return "Weather radar, updated \(time.formatted(date: .omitted, time: .shortened))"
    }
}

private struct ZoomPicker: View {
    let title: String
    let systemImage: String
    @Binding var selection: ZoomLevel

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
                .frame(width: 110, alignment: .leading)
            Picker(title, selection: $selection) {
                ForEach(ZoomLevel.allCases) { level in
                    Text(level.label).tag(level)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}

private struct DebugPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        DisclosureGroup("Debug") {
            VStack(alignment: .leading, spacing: 6) {
                if let location = model.testLocation {
                    row("Test location", "\(location.fix.latitude), \(location.fix.longitude)")
                }
                if let debug = model.debug {
                    row("Last run", "\(debug.process) · \(time(debug.attemptTime)) · forced \(debug.forced)")
                    row("Outcome", debug.outcome)
                    row("Zoom", debug.zoom.map { "\($0) mi" } ?? "–")
                    row("Radar", debug.radarReused == true ? "cut from last download" : "downloaded")
                    row("WMS BBOX (\(Int(RadarFootprint.miles)) mi)", debug.bbox ?? "–")
                    row("Tile BBOX", debug.tileBBox ?? "–")
                    row("WMS URL", debug.wmsURL ?? "–")
                    row("HTTP status", debug.httpStatus.map(String.init) ?? "–")
                    row("Radar TIME", debug.radarTimeRaw ?? "–")
                    row("Base map", debug.baseMapReused.map { $0 ? "reused" : "rendered" } ?? "–")
                    row("Alignment", debug.alignmentErrorPixels.map { String(format: "%.2f px", $0) } ?? "–")
                    ForEach(Array(debug.memory.enumerated()), id: \.offset) { _, reading in
                        row("Memory", String(format: "%@: %.1f MB free", reading.step, reading.availableMB))
                    }
                } else {
                    row("Last run", "none")
                }
                if let metadata = model.snapshot?.metadata {
                    row("Radar time", metadata.radarTime.map(time) ?? "unknown")
                    row("Fetch time", time(metadata.fetchTime))
                    row("Position", String(format: "%.4f, %.4f%@", metadata.latitude, metadata.longitude,
                                           metadata.locationStale ? " (stale)" : ""))
                }
                row("Last attempt", model.lastNetworkAttempt.map(time) ?? "–")
                row("Last success", model.lastSuccessfulRefresh.map(time) ?? "–")
                row("Cache", model.cacheDirectory.path)
            }
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .padding(.top, 8)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }

    private func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().second())
    }
}
