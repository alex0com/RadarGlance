import Shared
import SwiftUI

/// Map, radar and animation settings, the widget's current image and zoom, CarPlay help, and debug info.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(RadarLoopModel.self) private var loop
    @Environment(MapSettingsModel.self) private var mapSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        @Bindable var loop = loop
        @Bindable var mapSettings = mapSettings
        NavigationStack {
            Form {
                Section {
                    SettingsPicker(title: "Appearance", systemImage: "circle.lefthalf.filled",
                                   selection: $mapSettings.settings.appearance,
                                   options: MapSettings.Appearance.allCases, label: \.label)
                    SettingsPicker(title: "Style", systemImage: "map", selection: $mapSettings.settings.style,
                                   options: MapSettings.Style.allCases, label: \.label)
                    Toggle(isOn: $mapSettings.settings.showsHighways) {
                        Label("Highway lines", systemImage: "road.lanes")
                    }
                } header: {
                    Text("Map")
                } footer: {
                    Text("Highway lines draw interstates and freeways above the radar so they stay visible in heavy rain. Standard and Satellite show more roads than Muted.")
                }

                Section {
                    SettingsPicker(title: "Source", systemImage: "antenna.radiowaves.left.and.right",
                                   selection: $mapSettings.settings.radarSource,
                                   options: RadarSourcePreference.allCases, label: \.label)
                    if let source = loop.activeSource {
                        LabeledContent("Map is using", value: source.label)
                    }
                } header: {
                    Text("Radar source")
                } footer: {
                    Text("Both are NOAA services with the same radar data. Automatic uses opengeo (updated about every 2 minutes) and switches to nowCOAST (about every 4 minutes, classic NWS colors) when opengeo fails. Applies to the map and the widget.")
                }

                Section {
                    Picker("Color scheme", selection: $mapSettings.settings.colorScheme) {
                        ForEach(RadarColorScheme.allCases) { scheme in
                            HStack {
                                Text(scheme.label)
                                Spacer()
                                ColorSwatch(scheme: scheme)
                            }
                            .tag(scheme)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Toggle(isOn: $mapSettings.settings.hidesLightReturns) {
                        Label("Hide light returns", systemImage: "drop")
                    }
                } header: {
                    Text("Radar colors")
                } footer: {
                    Text("NOAA shows the source's own colors. Hide light returns removes faint echoes below \(Int(RadarPalette.lightReturnThreshold)) dBZ, such as drizzle and ground clutter, so real rain stands out.")
                }

                Section("Radar display") {
                    HStack {
                        Label("Opacity", systemImage: "circle.dotted")
                            .frame(width: 140, alignment: .leading)
                        Slider(value: $mapSettings.settings.radarOpacity, in: MapSettings.opacityRange)
                        Text(mapSettings.settings.radarOpacity, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                    Toggle(isOn: $mapSettings.settings.smoothRadar) {
                        Label("Smooth radar", systemImage: "wand.and.rays")
                    }
                }

                Section("Animation") {
                    SettingsPicker(title: "Length", systemImage: "clock.arrow.circlepath", selection: $loop.loopLength,
                                   options: LoopLength.allCases, label: \.label)
                    SettingsPicker(title: "Speed", systemImage: "speedometer",
                                   selection: $mapSettings.settings.animationSpeed,
                                   options: MapSettings.AnimationSpeed.allCases, label: \.label)
                }

                Section {
                    radarImage
                        .listRowInsets(EdgeInsets())
                    statusLine
                    Toggle(isOn: $model.showsWidgetWeather) {
                        Label("Temperature & humidity", systemImage: "thermometer.medium")
                    }
                    SettingsPicker(title: "iPhone", systemImage: "iphone", selection: $model.phoneZoom,
                                   options: ZoomLevel.allCases, label: \.label)
                    SettingsPicker(title: "CarPlay", systemImage: "car", selection: $model.carZoom,
                                   options: ZoomLevel.allCases, label: \.label)
                    Button {
                        Task { await model.refresh(force: true) }
                    } label: {
                        Label(model.isRefreshing ? "Refreshing…" : "Refresh widget", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isRefreshing)
                } header: {
                    Text("Widget")
                } footer: {
                    Text("Temperature & humidity come from the nearest National Weather Service station (or its hourly forecast when the station has no reading), updated at most every 10 minutes, in your region's units. The widget keeps NOAA's colors. CarPlay zoom applies to small widgets, the only size CarPlay shows. To use a different zoom for a Home Screen widget, touch and hold it and choose Edit Widget.")
                }

                Section {
                    NavigationLink {
                        CarPlayHelpView()
                    } label: {
                        Label("How to add it to CarPlay", systemImage: "car")
                    }
                    DebugPanel()
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
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

    private var accessibilityText: String {
        guard let time = model.snapshot?.metadata?.displayTime else { return "Weather radar" }
        return "Weather radar, updated \(time.formatted(date: .omitted, time: .shortened))"
    }
}

private struct SettingsPicker<Value: Hashable>: View {
    let title: String
    let systemImage: String
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String

    var body: some View {
        // Label above the control so every segment's text fits.
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(label(option)).tag(option)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}

/// A strip of the scheme's colors from light rain to severe storms.
private struct ColorSwatch: View {
    let scheme: RadarColorScheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(RadarPalette.swatch(for: scheme).enumerated()), id: \.offset) { _, color in
                Color(red: Double(color.r) / 255, green: Double(color.g) / 255, blue: Double(color.b) / 255)
                    .opacity(Double(color.a) / 255)
            }
        }
        .frame(width: 104, height: 12)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

private struct DebugPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(RadarLoopModel.self) private var loop

    var body: some View {
        DisclosureGroup("Debug") {
            VStack(alignment: .leading, spacing: 6) {
                if let location = model.testLocation {
                    row("Test location", "\(location.fix.latitude), \(location.fix.longitude)")
                }
                if let debug = model.debug {
                    row("Last run", "\(debug.process) · \(time(debug.attemptTime)) · forced \(debug.forced)")
                    row("Source", debug.source.flatMap(RadarSource.init(rawValue:))?.label ?? "–")
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
                if let frames = loop.frameSet?.frames, let first = frames.first, let last = frames.last {
                    row("Animation", "\(frames.count) frames · \(last.image.width)×\(last.image.height) px · "
                        + "\(time(first.time.date))–\(time(last.time.date))")
                } else {
                    row("Animation", loop.isLoading ? "loading" : "–")
                }
                row("Map source", loop.activeSource?.label ?? "–")
                if let weather = model.widgetWeather {
                    row("Widget weather", String(format: "%@ · %@ · %@ %@",
                        weather.temperatureCelsius.map { String(format: "%.1f °C", $0) } ?? "–",
                        weather.relativeHumidity.map { String(format: "%.0f%%", $0) } ?? "–",
                        weather.stationID ?? weather.origin.rawValue, time(weather.time)))
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
