import CoreGraphics
import Foundation
import Testing
@testable import Shared

struct WidgetImageTests {
    let fixtureURL: URL

    init() throws {
        let url = temporaryDirectory().appendingPathExtension("png")
        try Fixture.data("radar-sample.png").write(to: url)
        fixtureURL = url
    }

    @Test func cropRectWide() {
        #expect(WidgetImage.cropRect(imageSide: 1024, aspect: 2) == CGRect(x: 0, y: 256, width: 1024, height: 512))
    }

    @Test func cropRectTall() {
        #expect(WidgetImage.cropRect(imageSide: 1000, aspect: 0.5) == CGRect(x: 250, y: 0, width: 500, height: 1000))
    }

    @Test func cropRectSquare() {
        #expect(WidgetImage.cropRect(imageSide: 512, aspect: 1) == CGRect(x: 0, y: 0, width: 512, height: 512))
    }

    /// Small widget on a 3x phone: 158 pt → 474 px, so the 512 px tile is scaled down.
    @Test func smallWidgetDownscales() throws {
        let image = try #require(WidgetImage.load(contentsOf: fixtureURL, displaySize: CGSize(width: 158, height: 158), scale: 3))
        let cg = try #require(image.cgImage)
        #expect(cg.width == 474 && cg.height == 474)
    }

    /// Medium widget: wide crop of the square, never upscaled past the source.
    @Test func mediumWidgetCropsToAspect() throws {
        let image = try #require(WidgetImage.load(contentsOf: fixtureURL, displaySize: CGSize(width: 338, height: 158), scale: 3))
        let cg = try #require(image.cgImage)
        #expect(cg.width == 512)
        #expect(abs(Double(cg.width) / Double(cg.height) - 338.0 / 158.0) < 0.02)
    }

    @Test func largeWidgetStaysWithinWidgetPixels() throws {
        let image = try #require(WidgetImage.load(contentsOf: fixtureURL, displaySize: CGSize(width: 338, height: 354), scale: 2))
        let cg = try #require(image.cgImage)
        #expect(cg.width <= 676 && cg.height <= 708)
    }

    @Test func zeroSizeReturnsNil() {
        #expect(WidgetImage.load(contentsOf: fixtureURL, displaySize: .zero, scale: 3) == nil)
    }
}
