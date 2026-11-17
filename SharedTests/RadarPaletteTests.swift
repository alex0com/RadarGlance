import CoreGraphics
import Foundation
import Testing
@testable import Shared

struct RadarPaletteTests {
    // MARK: NOAA table

    @Test func tableIsInRampOrder() {
        let values = RadarPalette.noaaTable.map(\.dbz)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(RadarPalette.noaaTable.count > 150)
    }

    @Test func tableColorsAreUnique() {
        let keys = RadarPalette.noaaTable.map { "\($0.r),\($0.g),\($0.b)" }
        #expect(Set(keys).count == keys.count)
    }

    /// Well-sampled colors from the nowCOAST comparison (tools/derive-radar-palette.py).
    @Test(arguments: [
        (UInt8(67), UInt8(94), UInt8(159), 10.5),  // deep blue
        (94, 173, 207, 15.5),                       // cyan
        (82, 214, 162, 20.5),                       // teal
        (14, 214, 20, 24.5),                        // bright green
    ])
    func calibratedColors(r: UInt8, g: UInt8, b: UInt8, dbz: Double) throws {
        let value = try #require(RadarPalette.dbz(r: r, g: g, b: b))
        #expect(abs(value - dbz) <= 1)
    }

    @Test func yellowsAreModerateAndRedsAreHeavy() throws {
        let yellow = try #require(RadarPalette.dbz(r: 255, g: 226, b: 0))
        let red = try #require(RadarPalette.dbz(r: 255, g: 0, b: 0))
        #expect((33...42).contains(yellow))
        #expect(red > yellow + 5)
    }

    @Test func nearbyColorMatchesAndFarColorDoesNot() {
        #expect(RadarPalette.dbz(r: 68, g: 95, b: 160) == RadarPalette.dbz(r: 67, g: 94, b: 159))
        #expect(RadarPalette.dbz(r: 255, g: 0, b: 255) == nil)
    }

    // MARK: Schemes

    @Test func classicNWSSteps() {
        #expect(RadarPalette.color(forDBZ: 50, scheme: .classicNWS) == RadarColor(253, 0, 0))
        #expect(RadarPalette.color(forDBZ: 54.9, scheme: .classicNWS) == RadarColor(253, 0, 0))
        #expect(RadarPalette.color(forDBZ: 20, scheme: .classicNWS) == RadarColor(2, 253, 2))
        #expect(RadarPalette.color(forDBZ: 4, scheme: .classicNWS).a < 255)
    }

    @Test func colorBlindRampEnds() {
        #expect(RadarPalette.color(forDBZ: 65, scheme: .colorBlind) == RadarColor(253, 231, 37))
        #expect(RadarPalette.color(forDBZ: 100, scheme: .colorBlind) == RadarColor(253, 231, 37))
        #expect(RadarPalette.color(forDBZ: 55, scheme: .colorBlind) == RadarColor(253, 231, 37))
        #expect(RadarPalette.color(forDBZ: -40, scheme: .colorBlind) == RadarPalette.color(forDBZ: 0, scheme: .colorBlind))
    }

    @Test func swatchesHaveThirteenSteps() {
        for scheme in RadarColorScheme.allCases {
            #expect(RadarPalette.swatch(for: scheme).count == 13)
        }
    }

    // MARK: Recoloring

    /// transparent, deep blue (~10 dBZ), bright green (~25 dBZ), magenta (not a NOAA color).
    private func sampleImage() -> CGImage {
        rgbaImage([(0, 0, 0, 0), (67, 94, 159, 255), (14, 214, 20, 255), (255, 0, 255, 255)])
    }

    @Test func noaaWithoutHidingIsUntouched() {
        let image = sampleImage()
        #expect(RadarPalette.recolor(image, scheme: .noaa, hidesLightReturns: false) === image)
    }

    @Test func hidingLightReturnsKeepsHeavierEchoes() {
        let pixels = rgbaPixels(RadarPalette.recolor(sampleImage(), scheme: .noaa, hidesLightReturns: true))
        #expect(pixels[0].3 == 0)
        #expect(pixels[1].3 == 0)  // 10 dBZ is below the threshold
        #expect(pixels[2] == (14, 214, 20, 255))
        #expect(pixels[3] == (255, 0, 255, 255))
    }

    @Test func classicRecolorsKnownColorsOnly() throws {
        let pixels = rgbaPixels(RadarPalette.recolor(sampleImage(), scheme: .classicNWS, hidesLightReturns: false))
        let blue = RadarPalette.color(forDBZ: try #require(RadarPalette.dbz(r: 67, g: 94, b: 159)), scheme: .classicNWS)
        let green = RadarPalette.color(forDBZ: try #require(RadarPalette.dbz(r: 14, g: 214, b: 20)), scheme: .classicNWS)
        #expect(pixels[0].3 == 0)
        #expect(pixels[1] == (blue.r, blue.g, blue.b, blue.a))
        #expect(pixels[2] == (green.r, green.g, green.b, green.a))
        #expect(pixels[3] == (255, 0, 255, 255))
    }

    private func rgbaImage(_ pixels: [(UInt8, UInt8, UInt8, UInt8)]) -> CGImage {
        var bytes = pixels.flatMap { [$0.0, $0.1, $0.2, $0.3] }
        let context = CGContext(data: &bytes, width: pixels.count, height: 1, bitsPerComponent: 8,
                                bytesPerRow: pixels.count * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    private func rgbaPixels(_ image: CGImage) -> [(UInt8, UInt8, UInt8, UInt8)] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return stride(from: 0, to: bytes.count, by: 4).map { (bytes[$0], bytes[$0 + 1], bytes[$0 + 2], bytes[$0 + 3]) }
    }
}
