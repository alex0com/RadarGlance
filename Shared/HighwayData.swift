import CoreLocation
import Foundation

/// Interstates and other limited-access highways, drawn over the radar so they stay visible
/// in heavy rain. Built from US Census TIGER/Line primary roads by `tools/build-highways.py`.
public enum HighwayClass: UInt8, Sendable {
    case interstate = 0
    case freeway = 1
}

public struct HighwayLine: Sendable {
    public let highwayClass: HighwayClass
    public let coordinates: [CLLocationCoordinate2D]
}

public enum HighwayDataError: Error, Equatable {
    case badHeader
    case truncated
    case unknownClass(UInt8)
}

/// Reads the `highways.bin` format described in `tools/build-highways.py`.
public enum HighwayData {
    static let magic = Array("RGHW".utf8)
    static let version: UInt8 = 1
    static let escape: Int16 = -32768

    public static func parse(_ data: Data) throws -> [HighwayLine] {
        var reader = Reader(bytes: [UInt8](data))
        let header = try reader.bytes(4)
        let fileVersion = try reader.read(UInt8.self)
        guard header.elementsEqual(magic), fileVersion == version else {
            throw HighwayDataError.badHeader
        }
        let count = Int(try reader.read(UInt32.self))
        var lines: [HighwayLine] = []
        lines.reserveCapacity(count)
        for _ in 0..<count {
            let rawClass = try reader.read(UInt8.self)
            guard let highwayClass = HighwayClass(rawValue: rawClass) else {
                throw HighwayDataError.unknownClass(rawClass)
            }
            let pointCount = Int(try reader.read(UInt32.self))
            guard pointCount > 0 else { continue }
            var lat = Int(try reader.read(Int32.self))
            var lon = Int(try reader.read(Int32.self))
            var coordinates = [CLLocationCoordinate2D(latitude: Double(lat) / 1e5, longitude: Double(lon) / 1e5)]
            coordinates.reserveCapacity(pointCount)
            for _ in 1..<pointCount {
                let dLat = try reader.read(Int16.self)
                if dLat == escape {
                    lat += Int(try reader.read(Int32.self))
                    lon += Int(try reader.read(Int32.self))
                } else {
                    lat += Int(dLat)
                    lon += Int(try reader.read(Int16.self))
                }
                coordinates.append(CLLocationCoordinate2D(latitude: Double(lat) / 1e5, longitude: Double(lon) / 1e5))
            }
            lines.append(HighwayLine(highwayClass: highwayClass, coordinates: coordinates))
        }
        return lines
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        mutating func bytes(_ count: Int) throws -> ArraySlice<UInt8> {
            guard offset + count <= bytes.count else { throw HighwayDataError.truncated }
            defer { offset += count }
            return bytes[offset..<offset + count]
        }

        mutating func read<T: FixedWidthInteger>(_: T.Type) throws -> T {
            let size = MemoryLayout<T>.size
            guard offset + size <= bytes.count else { throw HighwayDataError.truncated }
            let value = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
            offset += size
            return T(littleEndian: value)
        }
    }
}
