import CoreLocation
import MapKit
import Testing
@testable import Shared

struct MercatorBoxTests {
    let R = MercatorBox.halfExtent

    @Test func worldWidthMatchesMapKit() {
        #expect(MercatorBox.worldWidth == MKMapSize.world.width)
    }

    @Test func originMapsToZeroMeters() {
        let meters = MercatorBox.toMeters(MKMapPoint(CLLocationCoordinate2D(latitude: 0, longitude: 0)))
        #expect(abs(meters.x) < 1e-6)
        #expect(abs(meters.y) < 1e-6)
    }

    @Test func longitude180MapsToPlusR() {
        let meters = MercatorBox.toMeters(MKMapPoint(CLLocationCoordinate2D(latitude: 0, longitude: 180)))
        #expect(abs(meters.x - R) < 1e-3)
    }

    @Test func worldCornersMapToExtent() {
        let topLeft = MercatorBox.toMeters(MKMapPoint(x: 0, y: 0))
        #expect(topLeft.x == -R)
        #expect(topLeft.y == R)
    }

    @Test(arguments: [(35.47, -97.52), (47.6, -122.3), (25.8, -80.2), (-33.9, 151.2)])
    func roundTrip(latitude: Double, longitude: Double) {
        let point = MKMapPoint(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
        let meters = MercatorBox.toMeters(point)
        let back = MercatorBox.toMapPoint(x: meters.x, y: meters.y)
        #expect(abs(back.x - point.x) < 1e-6)
        #expect(abs(back.y - point.y) < 1e-6)
    }

    /// Compared with the recon request (docs/noaa-wms-notes.md), computed independently with
    /// spherical Web Mercator formulas. The center must match exactly. The width differs by
    /// ~0.34% because `MKMapPointsPerMeterAtLatitude` uses the polar Earth radius where the
    /// recon script used the equatorial one; that only changes the scale, not alignment.
    @Test func oklahomaCityBBoxMatchesRecon() {
        let box = MercatorBox(center: CLLocationCoordinate2D(latitude: 35.47, longitude: -97.52), widthMiles: 80)
        let b = box.bboxMeters
        let expectedCenter = (x: -10_855_876.742, y: 4_227_937.126)
        let expectedWidth = 158_085.024
        #expect(abs((b.minX + b.maxX) / 2 - expectedCenter.x) < 0.01)
        #expect(abs((b.minY + b.maxY) / 2 - expectedCenter.y) < 0.01)
        #expect(abs((b.maxX - b.minX) / expectedWidth - 1) < 0.005)
        #expect(b.maxY > b.minY, "meters y points north")
    }

    @Test func bboxIsSquareInMeters() {
        let b = MercatorBox(center: CLLocationCoordinate2D(latitude: 44, longitude: -100), widthMiles: 160).bboxMeters
        #expect(abs((b.maxX - b.minX) - (b.maxY - b.minY)) < 1e-6)
    }

    @Test func centerIsMiddlePixel() {
        let coordinate = CLLocationCoordinate2D(latitude: 35.47, longitude: -97.52)
        let box = MercatorBox(center: coordinate, widthMiles: 40)
        let pixel = box.pixel(for: MKMapPoint(coordinate), size: 512)
        #expect(abs(pixel.x - 256) < 1e-6)
        #expect(abs(pixel.y - 256) < 1e-6)
    }

    @Test func northIsUpInPixels() {
        let box = MercatorBox(center: CLLocationCoordinate2D(latitude: 35.47, longitude: -97.52), widthMiles: 80)
        let north = box.pixel(for: MKMapPoint(CLLocationCoordinate2D(latitude: 35.6, longitude: -97.52)), size: 512)
        #expect(north.y < 256)
    }

    @Test func bboxStringUsesDotsRegardlessOfLocale() {
        let box = MercatorBox(minX: 0, minY: 0, width: MercatorBox.worldWidth)
        #expect(box.bboxString == "-20037508.343,-20037508.343,20037508.343,20037508.343")
    }

    @Test func nearCenter() {
        let box = MercatorBox(minX: 0, minY: 0, width: 1000)
        #expect(box.isNearCenter(MKMapPoint(x: 550, y: 450), fraction: 0.1))
        #expect(!box.isNearCenter(MKMapPoint(x: 650, y: 500), fraction: 0.1))
    }
}

struct RadarRegionTests {
    @Test func conusCoversOklahomaCity() {
        #expect(RadarRegion.region(latitude: 35.47, longitude: -97.52) == .conus)
    }

    @Test(arguments: [(61.2, -149.9), (21.3, -157.8), (51.5, -0.1), (18.4, -66.1)])
    func outsideConusHasNoRegion(latitude: Double, longitude: Double) {
        #expect(RadarRegion.region(latitude: latitude, longitude: longitude) == nil)
    }
}
