import Foundation

/// What the widget needs to draw a cached image. Saved as `metadata-<zoom>.json`.
public struct RadarMetadata: Codable, Sendable, Equatable {
    /// NOAA's valid time for the frame. Nil if GetCapabilities failed and the image was
    /// requested without TIME; the label then falls back to `fetchTime`.
    public var radarTime: Date?
    public var fetchTime: Date
    public var latitude: Double
    public var longitude: Double
    public var locationStale: Bool
    public var zoom: ZoomLevel
    public var resolution: TileResolution

    public init(radarTime: Date?, fetchTime: Date, latitude: Double, longitude: Double,
                locationStale: Bool, zoom: ZoomLevel, resolution: TileResolution) {
        self.radarTime = radarTime
        self.fetchTime = fetchTime
        self.latitude = latitude
        self.longitude = longitude
        self.locationStale = locationStale
        self.zoom = zoom
        self.resolution = resolution
    }

    /// The time shown on the widget and used for stale tinting.
    public var displayTime: Date { radarTime ?? fetchTime }
}

/// The cached base map's coverage. Saved as `basemap-<zoom>.json`.
public struct BaseMapInfo: Codable, Sendable, Equatable {
    public var box: MercatorBox
    public var createdAt: Date
    public var alignmentErrorPixels: Double

    public init(box: MercatorBox, createdAt: Date, alignmentErrorPixels: Double) {
        self.box = box
        self.createdAt = createdAt
        self.alignmentErrorPixels = alignmentErrorPixels
    }
}

public struct MemoryReading: Codable, Sendable, Equatable {
    public var step: String
    /// From `os_proc_available_memory()`. Zero where the OS doesn't report it (Simulator).
    public var availableMB: Double
}

/// The last pipeline run, for the app's debug panel. Saved as `debug.json`.
public struct DebugRecord: Codable, Sendable, Equatable {
    public var process: String
    public var attemptTime: Date
    public var forced: Bool
    public var outcome: String
    public var bbox: String?
    public var wmsURL: String?
    public var httpStatus: Int?
    public var radarTimeRaw: String?
    public var resolution: Int?
    public var baseMapReused: Bool?
    public var alignmentErrorPixels: Double?
    public var memory: [MemoryReading] = []

    public init(process: String, attemptTime: Date, forced: Bool, outcome: String) {
        self.process = process
        self.attemptTime = attemptTime
        self.forced = forced
        self.outcome = outcome
    }
}

/// Files in the App Group container, readable while the iPhone is locked after first unlock.
///
/// Never use `.complete` protection: CarPlay usually runs with the phone locked, and the
/// widget couldn't read the files.
public struct RadarCache: Sendable {
    public static let protection = FileProtectionType.completeUntilFirstUserAuthentication
    public static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: Self.protection])
    }

    /// The shared cache. Falls back to the process's own caches directory if the App Group
    /// is missing (misconfigured signing), so the app still works on its own.
    public static func appGroup() -> RadarCache {
        let base = AppGroup.containerURL
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return RadarCache(directory: base.appending(path: "RadarCache", directoryHint: .isDirectory))
    }

    public func compositeURL(zoom: ZoomLevel, resolution: TileResolution) -> URL {
        file("composite-\(zoom.rawValue)-\(resolution.pixels).png")
    }
    private func metadataURL(zoom: ZoomLevel, resolution: TileResolution) -> URL {
        file("metadata-\(zoom.rawValue)-\(resolution.pixels).json")
    }
    private func baseMapURL(zoom: ZoomLevel, resolution: TileResolution) -> URL {
        file("basemap-\(zoom.rawValue)-\(resolution.pixels).png")
    }
    private func baseMapInfoURL(zoom: ZoomLevel, resolution: TileResolution) -> URL {
        file("basemap-\(zoom.rawValue)-\(resolution.pixels).json")
    }
    private var debugURL: URL { file("debug.json") }

    private func file(_ name: String) -> URL {
        directory.appending(path: name, directoryHint: .notDirectory)
    }

    // MARK: Composite

    /// Writes the image first so the metadata never points at a missing image.
    public func writeComposite(_ png: Data, metadata: RadarMetadata) throws {
        try png.write(to: compositeURL(zoom: metadata.zoom, resolution: metadata.resolution), options: Self.writeOptions)
        try write(metadata, to: metadataURL(zoom: metadata.zoom, resolution: metadata.resolution))
    }

    public func readMetadata(zoom: ZoomLevel, resolution: TileResolution) -> RadarMetadata? {
        guard FileManager.default.fileExists(atPath: compositeURL(zoom: zoom, resolution: resolution).path)
        else { return nil }
        return read(RadarMetadata.self, from: metadataURL(zoom: zoom, resolution: resolution))
    }

    /// The best cached composite for a widget: same zoom and resolution, else the newest at
    /// the same zoom, else the newest of all.
    public func bestMetadata(zoom: ZoomLevel, resolution: TileResolution) -> RadarMetadata? {
        if let exact = readMetadata(zoom: zoom, resolution: resolution) { return exact }
        let all = ZoomLevel.allCases.flatMap { z in
            TileResolution.allCases.compactMap { readMetadata(zoom: z, resolution: $0) }
        }
        let newest = { (list: [RadarMetadata]) in list.max { $0.fetchTime < $1.fetchTime } }
        return newest(all.filter { $0.zoom == zoom }) ?? newest(all)
    }

    // MARK: Base map

    public func writeBaseMap(_ png: Data, info: BaseMapInfo, zoom: ZoomLevel, resolution: TileResolution) throws {
        try png.write(to: baseMapURL(zoom: zoom, resolution: resolution), options: Self.writeOptions)
        try write(info, to: baseMapInfoURL(zoom: zoom, resolution: resolution))
    }

    public func readBaseMap(zoom: ZoomLevel, resolution: TileResolution) -> (png: Data, info: BaseMapInfo)? {
        guard let info = read(BaseMapInfo.self, from: baseMapInfoURL(zoom: zoom, resolution: resolution)),
              let png = try? Data(contentsOf: baseMapURL(zoom: zoom, resolution: resolution))
        else { return nil }
        return (png, info)
    }

    // MARK: Debug

    public func writeDebug(_ record: DebugRecord) {
        try? write(record, to: debugURL)
    }

    public func readDebug() -> DebugRecord? {
        read(DebugRecord.self, from: debugURL)
    }

    // MARK: JSON

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: Self.writeOptions)
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }
}
