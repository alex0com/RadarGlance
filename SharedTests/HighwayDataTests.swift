import Foundation
import Testing
@testable import Shared

struct HighwayDataTests {
    private func header(lineCount: UInt32) -> Data {
        var data = Data("RGHW".utf8)
        data.append(1)
        data.append(littleEndian: lineCount)
        return data
    }

    @Test func parsesDeltasAndEscapes() throws {
        var data = header(lineCount: 2)
        // Interstate: 3 points with small deltas.
        data.append(0)
        data.append(littleEndian: UInt32(3))
        data.append(littleEndian: Int32(3_547_000))   // 35.47
        data.append(littleEndian: Int32(-9_752_000))  // -97.52
        data.append(littleEndian: Int16(100))
        data.append(littleEndian: Int16(-200))
        data.append(littleEndian: Int16(-50))
        data.append(littleEndian: Int16(25))
        // Freeway: 2 points with a delta too big for Int16.
        data.append(1)
        data.append(littleEndian: UInt32(2))
        data.append(littleEndian: Int32(2_800_000))
        data.append(littleEndian: Int32(-8_200_000))
        data.append(littleEndian: Int16(-32768))
        data.append(littleEndian: Int32(50_000))
        data.append(littleEndian: Int32(-40_000))

        let lines = try HighwayData.parse(data)
        #expect(lines.count == 2)
        #expect(lines[0].highwayClass == .interstate)
        #expect(lines[0].coordinates.map(\.latitude) == [35.47, 35.471, 35.4705])
        #expect(lines[0].coordinates.map(\.longitude) == [-97.52, -97.522, -97.52175])
        #expect(lines[1].highwayClass == .freeway)
        #expect(lines[1].coordinates.last?.latitude == 28.5)
        #expect(lines[1].coordinates.last?.longitude == -82.4)
    }

    @Test func rejectsBadHeader() {
        var data = Data("NOPE".utf8)
        data.append(1)
        data.append(littleEndian: UInt32(0))
        #expect(throws: HighwayDataError.badHeader) { try HighwayData.parse(data) }
    }

    @Test func rejectsTruncatedData() {
        var data = header(lineCount: 1)
        data.append(0)
        data.append(littleEndian: UInt32(5))
        #expect(throws: HighwayDataError.truncated) { try HighwayData.parse(data) }
    }

    /// The resource the app ships, read from the repository.
    @Test func bundledFileParsesAndStaysInConus() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("RadarGlance/Resources/highways.bin")
        let lines = try HighwayData.parse(try Data(contentsOf: url))
        #expect(lines.count > 10_000)
        #expect(lines.contains { $0.highwayClass == .interstate })
        #expect(lines.contains { $0.highwayClass == .freeway })
        let points = lines.flatMap(\.coordinates)
        // Lines are kept if any point is in the CONUS box, so allow a little spill past its edges.
        #expect(points.allSatisfy { (17...57).contains($0.latitude) && (-132 ... -58).contains($0.longitude) })
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
