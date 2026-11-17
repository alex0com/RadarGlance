import CoreGraphics
import Foundation

/// Colors for the app's radar. NOAA sends images already colored, so other schemes are made by
/// looking up each color's reflectivity (opengeo: `noaaTable`, derived in
/// `tools/derive-radar-palette.py`; nowCOAST: its published ramp) and coloring that value with
/// the chosen scheme.
public enum RadarColorScheme: String, Codable, Sendable, CaseIterable, Identifiable {
    /// The source's own colors, unchanged.
    case noaa
    /// The traditional NWS 5 dBZ steps: blues, greens, yellow, orange, reds, magenta.
    case classicNWS
    /// Six bold bands that read at a glance.
    case highContrast
    /// A viridis ramp (blue → green → yellow) that stays distinct with red-green color blindness.
    case colorBlind

    public var id: Self { self }
    public var label: String {
        switch self {
        case .noaa: "NOAA"
        case .classicNWS: "Classic NWS"
        case .highContrast: "High contrast"
        case .colorBlind: "Color-blind friendly"
        }
    }
}

public struct RadarColor: Sendable, Equatable {
    public var r: UInt8, g: UInt8, b: UInt8, a: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    static let clear = RadarColor(0, 0, 0, 0)
}

public enum RadarPalette {
    /// "Hide light returns" drops everything below this: drizzle, clutter and other faint echoes.
    /// Light rain starts around 20 dBZ.
    public static let lightReturnThreshold = 15.0
    /// A NOAA color this close (RGB distance) to a table color is treated as that color.
    static let matchDistance = 12.0

    /// The reflectivity behind a source's color, or nil if it isn't (close to) one of its palette colors.
    public static func dbz(r: UInt8, g: UInt8, b: UInt8, source: RadarSource = .opengeo) -> Double? {
        let key = pack(r, g, b)
        let table = table(for: source)
        if let value = table.byKey[key] { return value }
        var best: (distance: Double, dbz: Double)?
        for entry in table.entries {
            let dr = Double(entry.r) - Double(r)
            let dg = Double(entry.g) - Double(g)
            let db = Double(entry.b) - Double(b)
            let distance = (dr * dr + dg * dg + db * db).squareRoot()
            if distance <= matchDistance, distance < (best?.distance ?? .infinity) {
                best = (distance, entry.dbz)
            }
        }
        return best?.dbz
    }

    /// The color `scheme` gives `dbz`. For `.noaa`, the nearest NOAA palette color.
    public static func color(forDBZ dbz: Double, scheme: RadarColorScheme) -> RadarColor {
        switch scheme {
        case .noaa:
            let entry = noaaTable.min { abs($0.dbz - dbz) < abs($1.dbz - dbz) }!
            return RadarColor(entry.r, entry.g, entry.b)
        case .classicNWS:
            return step(dbz, classicSteps, below: RadarColor(150, 150, 150, 100))
        case .highContrast:
            return step(dbz, highContrastSteps, below: RadarColor(160, 160, 170, 110))
        case .colorBlind:
            // 0…55 dBZ across viridis 0.15…1, skipping its darkest purples, so everyday rain
            // (10–30 dBZ) spans blue to green and storms reach yellow.
            let t = 0.15 + 0.85 * min(max(dbz / 55, 0), 1)
            return interpolate(viridis, at: t)
        }
    }

    /// Colors for a legend, from faint to severe.
    public static func swatch(for scheme: RadarColorScheme) -> [RadarColor] {
        stride(from: 5.0, through: 65.0, by: 5).map { color(forDBZ: $0, scheme: scheme) }
    }

    /// Recolors a radar image from `source`. Returns `image` itself when nothing would change.
    public static func recolor(_ image: CGImage, source: RadarSource = .opengeo, scheme: RadarColorScheme,
                               hidesLightReturns: Bool) -> CGImage {
        if scheme == .noaa && !hidesLightReturns { return image }
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data?.bindMemory(to: UInt8.self, capacity: width * height * 4)
        else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var lookup: [UInt32: RadarColor?] = [:]
        var lastKey: UInt32 = .max
        var lastColor: RadarColor?
        for offset in stride(from: 0, to: width * height * 4, by: 4) {
            let alpha = pixels[offset + 3]
            guard alpha > 0 else { continue }
            // opengeo pixels are opaque; nowCOAST draws its faintest values at 40%.
            let key = pack(pixels[offset], pixels[offset + 1], pixels[offset + 2]) << 8 | UInt32(alpha)
            if key != lastKey {
                lastKey = key
                if let cached = lookup[key] {
                    lastColor = cached
                } else {
                    func straight(_ value: UInt8) -> UInt8 {
                        alpha == 255 ? value : UInt8(min(255, Int(value) * 255 / Int(alpha)))
                    }
                    let mapped = mappedColor(r: straight(pixels[offset]), g: straight(pixels[offset + 1]),
                                             b: straight(pixels[offset + 2]), source: source, scheme: scheme,
                                             hidesLightReturns: hidesLightReturns)
                    lookup[key] = mapped
                    lastColor = mapped
                }
            }
            // nil: keep the pixel as the source drew it.
            guard let color = lastColor else { continue }
            let newAlpha = UInt16(color.a)
            pixels[offset] = UInt8(UInt16(color.r) * newAlpha / 255)
            pixels[offset + 1] = UInt8(UInt16(color.g) * newAlpha / 255)
            pixels[offset + 2] = UInt8(UInt16(color.b) * newAlpha / 255)
            pixels[offset + 3] = color.a
        }
        return context.makeImage() ?? image
    }

    /// The new color for one source color, or nil to keep it.
    static func mappedColor(r: UInt8, g: UInt8, b: UInt8, source: RadarSource, scheme: RadarColorScheme,
                            hidesLightReturns: Bool) -> RadarColor? {
        guard let dbz = dbz(r: r, g: g, b: b, source: source) else { return nil }
        if hidesLightReturns && dbz < lightReturnThreshold { return .clear }
        if scheme == .noaa { return nil }
        return color(forDBZ: dbz, scheme: scheme)
    }

    // MARK: Tables

    private static func pack(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> UInt32 {
        UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
    }

    private struct Table: Sendable {
        let entries: [(r: UInt8, g: UInt8, b: UInt8, dbz: Double)]
        let byKey: [UInt32: Double]

        init(_ entries: [(r: UInt8, g: UInt8, b: UInt8, dbz: Double)]) {
            self.entries = entries
            byKey = Dictionary(entries.map { (pack($0.r, $0.g, $0.b), $0.dbz) }, uniquingKeysWith: { first, _ in first })
        }
    }

    private static func table(for source: RadarSource) -> Table {
        switch source {
        case .opengeo: opengeoTable
        case .nowCOAST: nowCoastTable
        }
    }

    private static let opengeoTable = Table(noaaTable.map { ($0.r, $0.g, $0.b, $0.dbz) })

    /// Every whole-dBZ color of nowCOAST's ramp.
    private static let nowCoastTable: Table = {
        var entries: [(r: UInt8, g: UInt8, b: UInt8, dbz: Double)] = []
        for (low, high) in zip(nowCoastAnchors, nowCoastAnchors.dropFirst()) where high.dbz > low.dbz {
            for dbz in stride(from: low.dbz, to: high.dbz, by: 1) {
                let f = (dbz - low.dbz) / (high.dbz - low.dbz)
                func mix(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8((Double(a) + (Double(b) - Double(a)) * f).rounded()) }
                entries.append((mix(low.r, high.r), mix(low.g, high.g), mix(low.b, high.b), dbz))
            }
        }
        if let last = nowCoastAnchors.last { entries.append((last.r, last.g, last.b, last.dbz)) }
        return Table(entries)
    }()

    /// Lower bound in dBZ and the color from there up to the next step.
    private static let classicSteps: [(Double, RadarColor)] = [
        (5, RadarColor(4, 233, 231)), (10, RadarColor(1, 159, 244)), (15, RadarColor(3, 0, 244)),
        (20, RadarColor(2, 253, 2)), (25, RadarColor(1, 197, 1)), (30, RadarColor(0, 142, 0)),
        (35, RadarColor(253, 248, 2)), (40, RadarColor(229, 188, 0)), (45, RadarColor(253, 149, 0)),
        (50, RadarColor(253, 0, 0)), (55, RadarColor(212, 0, 0)), (60, RadarColor(188, 0, 0)),
        (65, RadarColor(248, 0, 253)), (70, RadarColor(152, 84, 198)), (75, RadarColor(253, 253, 253)),
    ]

    private static let highContrastSteps: [(Double, RadarColor)] = [
        (5, RadarColor(80, 170, 255)), (20, RadarColor(0, 220, 70)), (30, RadarColor(255, 235, 0)),
        (40, RadarColor(255, 135, 0)), (50, RadarColor(255, 20, 20)), (60, RadarColor(255, 0, 255)),
    ]

    private static let viridis: [RadarColor] = [
        RadarColor(68, 1, 84), RadarColor(71, 44, 122), RadarColor(59, 82, 139), RadarColor(44, 113, 142),
        RadarColor(33, 145, 140), RadarColor(39, 173, 129), RadarColor(92, 200, 99), RadarColor(170, 220, 50),
        RadarColor(253, 231, 37),
    ]

    private static func step(_ dbz: Double, _ steps: [(Double, RadarColor)], below: RadarColor) -> RadarColor {
        steps.last { dbz >= $0.0 }?.1 ?? below
    }

    private static func interpolate(_ ramp: [RadarColor], at t: Double) -> RadarColor {
        let position = min(max(t, 0), 1) * Double(ramp.count - 1)
        let index = min(Int(position), ramp.count - 2)
        let f = position - Double(index)
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8((Double(a) + (Double(b) - Double(a)) * f).rounded()) }
        let a = ramp[index], b = ramp[index + 1]
        return RadarColor(mix(a.r, b.r), mix(a.g, b.g), mix(a.b, b.b))
    }
}
