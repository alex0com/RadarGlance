import AppIntents
import Shared
import SwiftUI
import WidgetKit

struct RadarWidgetView: View {
    let entry: RadarEntry

    private static let tileColor = Color(red: 0.07, green: 0.08, blue: 0.10)

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                radarImage
                content(tileSide: max(geometry.size.width, geometry.size.height))
            }
        }
        // The tile stays dark in both appearances so the radar has contrast.
        .environment(\.colorScheme, .dark)
        // Tapping outside the refresh button opens the app's animated radar map.
        .widgetURL(URL(string: "quickradarglance://radar"))
        // The image lives in the content rather than the container background so that
        // WidgetKit animates it between entries. The background stays non-removable.
        .containerBackground(for: .widget) { Self.tileColor }
    }

    /// Crossfades when new radar arrives or the zoom changes. The extra entries that only
    /// change the time label's tint keep the same key, so they don't fade.
    @ViewBuilder
    private var radarImage: some View {
        if let image = shownImage {
            Image(uiImage: image)
                .resizable()
                .interpolation(.medium)
                .widgetAccentedRenderingMode(.fullColor)
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .id(imageKey)
                .transition(.opacity)
        }
    }

    private var imageKey: String {
        guard let metadata = entry.metadata else { return "none" }
        return "\(metadata.fetchTime.timeIntervalSince1970)-\(metadata.zoom.rawValue)"
    }

    /// Hidden for failures where a cached image would be misleading.
    private var shownImage: UIImage? {
        if entry.failure?.hidesImage == true { return nil }
        return entry.image
    }

    @ViewBuilder
    private func content(tileSide: CGFloat) -> some View {
        if entry.isPlaceholder {
            Text("Radar")
                .font(.headline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.gray.opacity(0.35))
        } else if shownImage == nil {
            messageTile(entry.failure?.message ?? "No radar yet")
                .transition(.opacity)
        } else {
            radarOverlay(tileSide: tileSide)
        }
    }

    private func radarOverlay(tileSide: CGFloat) -> some View {
        VStack {
            HStack {
                if let conditions = entry.conditions {
                    ConditionsLabel(conditions: conditions)
                }
                Spacer(minLength: 4)
                refreshButton
            }
            Spacer()
            HStack(alignment: .bottom) {
                if let time = entry.metadata?.displayTime {
                    TimeLabel(time: time, now: entry.date)
                }
                Spacer()
                if let zoom = entry.metadata?.zoom {
                    ScaleBar(zoom: zoom, tileSide: tileSide)
                        .padding(.bottom, 2)
                }
            }
        }
        .padding(8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private func messageTile(_ message: String) -> some View {
        ZStack(alignment: .topTrailing) {
            Text(message)
                .font(.headline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            refreshButton.padding(8)
        }
    }

    private var refreshButton: some View {
        Button(intent: RefreshRadarIntent()) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(.black.opacity(0.55)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Refresh radar")
    }

    private var accessibilityText: String {
        var text = "Weather radar"
        if let time = entry.metadata?.displayTime {
            text += ", updated \(time.formatted(date: .omitted, time: .shortened))"
        }
        if let conditions = entry.conditions {
            text += ". " + ConditionsLabel.spokenText(conditions)
        }
        return text
    }
}

/// "49° · 71%": temperature in the phone's preferred unit and relative humidity.
private struct ConditionsLabel: View {
    let conditions: WeatherConditions

    var body: some View {
        HStack(spacing: 4) {
            if let temperature = Self.temperature(conditions) {
                Text(temperature)
            }
            if let humidity = conditions.relativeHumidity {
                HStack(spacing: 1) {
                    Image(systemName: "humidity.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("\(Int(humidity.rounded()))%")
                }
            }
        }
        .font(.system(size: 13, weight: .semibold).monospacedDigit())
        .foregroundStyle(.white)
        .lineLimit(1)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Capsule().fill(.black.opacity(0.55)))
    }

    static func temperature(_ conditions: WeatherConditions) -> String? {
        conditions.temperatureCelsius.map {
            Measurement(value: $0, unit: UnitTemperature.celsius)
                .formatted(.measurement(width: .narrow, usage: .weather, numberFormatStyle: .number.precision(.fractionLength(0))))
        }
    }

    static func spokenText(_ conditions: WeatherConditions) -> String {
        var parts: [String] = []
        if let temperature = temperature(conditions) { parts.append("Temperature \(temperature)") }
        if let humidity = conditions.relativeHumidity { parts.append("humidity \(Int(humidity.rounded())) percent") }
        return parts.joined(separator: ", ")
    }
}

private struct TimeLabel: View {
    let time: Date
    let now: Date

    var body: some View {
        let age = RadarAge(dataTime: time, now: now)
        HStack(spacing: 3) {
            Text(time, format: .dateTime.hour().minute())
                .contentTransition(.numericText(value: time.timeIntervalSince1970))
            if age == .old {
                Text("Old")
            }
        }
        .font(.system(size: 13, weight: .semibold).monospacedDigit())
        .foregroundStyle(color(for: age))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(.black.opacity(0.55)))
    }

    private func color(for age: RadarAge) -> Color {
        switch age {
        case .fresh: .white
        case .aging: Color(red: 1.0, green: 0.75, blue: 0.2)
        case .old: Color(red: 1.0, green: 0.35, blue: 0.3)
        }
    }
}
