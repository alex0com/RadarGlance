import CoreGraphics
import Foundation
import Testing
@testable import Shared

struct RadarSourceTests {
    @Test func preferenceOrder() {
        #expect(RadarSourcePreference.automatic.sources == [.opengeo, .nowCOAST])
        #expect(RadarSourcePreference.opengeo.sources == [.opengeo])
        #expect(RadarSourcePreference.nowCOAST.sources == [.nowCOAST])
        #expect(MapSettings().radarSource == .automatic)
    }

    @Test func nowCoastRegionMatchesConus() {
        let region = RadarSource.nowCOAST.region(for: .conus)
        #expect(region.layer == "conus_base_reflectivity_mosaic")
        #expect(region.covers(latitude: 35.47, longitude: -97.52))
        #expect(RadarSource.opengeo.region(for: .conus) == .conus)
    }

    @Test func parsesNowCoastCapabilities() throws {
        let times = try #require(CapabilitiesParser.times(in: try Fixture.data("nowcoast-capabilities.xml"),
                                                          layer: "conus_base_reflectivity_mosaic"))
        #expect(times.latest.raw == "2026-11-17T16:16:11Z")
        #expect(times.all.count == 110)
        #expect(times.all.last == times.latest)
    }

    // MARK: nowCOAST colors

    @Test(arguments: [
        (UInt8(0), UInt8(236), UInt8(236), 10.0),  // anchor
        (0, 208, 240, 12.0),                        // interpolated between the 11 and 13 anchors
        (255, 0, 0, 55.0),
        (0, 255, 0, 25.0),
    ])
    func nowCoastColorValues(r: UInt8, g: UInt8, b: UInt8, dbz: Double) throws {
        let value = try #require(RadarPalette.dbz(r: r, g: g, b: b, source: .nowCOAST))
        #expect(abs(value - dbz) <= 0.5)
    }

    @Test func nowCoastFaintPixelsAreHiddenAndRecolored() {
        // nowCOAST draws 1–5 dBZ at 40% (premultiplied here), and 25 dBZ green opaque.
        let faint = (UInt8(119 * 102 / 255), UInt8(119 * 102 / 255), UInt8(119 * 102 / 255), UInt8(102))
        var bytes: [UInt8] = [faint.0, faint.1, faint.2, faint.3, 0, 255, 0, 255]
        let context = CGContext(data: &bytes, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = context.makeImage()!

        let hidden = pixels(RadarPalette.recolor(image, source: .nowCOAST, scheme: .noaa, hidesLightReturns: true))
        #expect(hidden[0].3 == 0)
        #expect(hidden[1] == (0, 255, 0, 255))

        let contrast = pixels(RadarPalette.recolor(image, source: .nowCOAST, scheme: .highContrast, hidesLightReturns: false))
        let green = RadarPalette.color(forDBZ: 25, scheme: .highContrast)
        #expect(contrast[1] == (green.r, green.g, green.b, green.a))
    }

    private func pixels(_ image: CGImage) -> [(UInt8, UInt8, UInt8, UInt8)] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return stride(from: 0, to: bytes.count, by: 4).map { (bytes[$0], bytes[$0 + 1], bytes[$0 + 2], bytes[$0 + 3]) }
    }
}
