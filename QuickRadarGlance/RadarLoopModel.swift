import CoreGraphics
import Foundation
import ImageIO
import MapKit
import Observation
import Shared

/// How frames are colored; changing it re-renders the loaded frames without downloading.
struct RadarRendering: Equatable, Sendable {
    var colorScheme: RadarColorScheme = .noaa
    var hidesLightReturns = false
}

/// One radar image of the loop: NOAA's PNG, and the image drawn from it.
struct RadarFrame: Identifiable, @unchecked Sendable {
    let time: RadarTime
    let png: Data
    let image: CGImage
    let source: RadarSource
    let rendering: RadarRendering
    var id: Date { time.date }
}

/// Frames that all cover the same `rect`, oldest first.
struct RadarFrameSet: Identifiable {
    let id = UUID()
    let rect: MKMapRect
    /// Width of the visible map when these were requested, to tell how far the zoom has moved.
    let visibleWidth: Double
    let frames: [RadarFrame]
}

/// Loads recent radar frames for the area the map shows and plays them as a loop.
/// Separate from `RadarPipeline`: the widget pipeline keeps its 30 s throttle, while this
/// fetches when the user moves the map (debounced by the map view, cancelled when they move again).
@MainActor
@Observable
final class RadarLoopModel {
    static let newestHold: Duration = .milliseconds(1500)
    static let maxConcurrentRequests = 4
    /// NOAA publishes about every 2 min; check for a new frame this often while the app is open.
    static let refreshInterval: Duration = .seconds(120)

    private(set) var frameSet: RadarFrameSet?
    private(set) var currentIndex = 0
    private(set) var isPlaying = true
    private(set) var isLoading = false
    private(set) var loadProgress = 0.0
    private(set) var failure: RadarFailure?
    /// The source of the frames on screen.
    private(set) var activeSource: RadarSource?

    /// opengeo, nowCOAST, or opengeo with nowCOAST as backup.
    var sourcePreference: RadarSourcePreference = .automatic {
        didSet {
            guard sourcePreference != oldValue else { return }
            reload(force: false)
        }
    }

    var loopLength: LoopLength {
        didSet {
            guard loopLength != oldValue else { return }
            store.loopLength = loopLength
            reload(force: false)
        }
    }

    /// Time each frame is shown.
    var animationSpeed: MapSettings.AnimationSpeed = .normal

    /// Applied to loaded frames right away, from their saved PNGs.
    var rendering = RadarRendering() {
        didSet {
            guard rendering != oldValue else { return }
            reload(force: false)
        }
    }

    var currentFrame: RadarFrame? {
        guard let frames = frameSet?.frames, frames.indices.contains(currentIndex) else { return nil }
        return frames[currentIndex]
    }

    private let region = RadarRegion.conus
    private let client = RadarClient()
    private let store: SharedStore
    private var viewport: (visible: MKMapRect, viewPixels: CGSize)?
    private var loadTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?

    init(store: SharedStore = SharedStore()) {
        self.store = store
        loopLength = store.loopLength
    }

    /// The map stopped moving. Loads new frames unless the current ones still cover it.
    func mapSettled(visible: MKMapRect, viewPixels: CGSize) {
        viewport = (visible, viewPixels)
        if let frameSet, !RadarLoop.needsReload(loaded: frameSet.rect, loadedVisibleWidth: frameSet.visibleWidth,
                                                visible: visible, region: region) {
            return
        }
        reload(force: false)
    }

    /// Picks up newly published frames for the same area. Frames already loaded are reused.
    /// `force` (the refresh button) skips the 2-minute capabilities cache and restarts any load.
    func refresh(force: Bool = false) {
        guard force || loadTask == nil else { return }
        reload(force: force)
    }

    func togglePlaying() {
        isPlaying.toggle()
        updatePlayback()
    }

    /// Shows one frame and stops the animation.
    func select(index: Int) {
        guard let frames = frameSet?.frames, frames.indices.contains(index) else { return }
        isPlaying = false
        updatePlayback()
        currentIndex = index
    }

    // MARK: Loading

    private func reload(force: Bool) {
        guard let viewport else { return }
        loadTask?.cancel()
        guard let rect = RadarLoop.requestRect(visible: viewport.visible, region: region) else {
            // Nothing with radar coverage is on screen; keep what's loaded.
            loadTask = nil
            isLoading = false
            return
        }
        let size = RadarLoop.pixelSize(for: rect, visible: viewport.visible, viewPixels: viewport.viewPixels)
        let visibleWidth = viewport.visible.width
        // Same area as now: only fetch frames that aren't loaded yet.
        let reusable = frameSet.flatMap { MKMapRectEqualToRect($0.rect, rect) ? $0.frames : nil } ?? []
        let rendering = rendering
        let sources = sourcePreference.sources
        loadTask = Task {
            await load(rect: rect, size: size, visibleWidth: visibleWidth, reusable: reusable,
                       rendering: rendering, sources: sources, force: force)
        }
    }

    /// Tries each source in order; a failure moves on to the next (the backup) unless offline.
    private func load(rect: MKMapRect, size: (width: Int, height: Int), visibleWidth: Double,
                      reusable: [RadarFrame], rendering: RadarRendering, sources: [RadarSource], force: Bool) async {
        isLoading = true
        defer {
            if !Task.isCancelled {
                isLoading = false
                loadTask = nil
            }
        }
        var lastError: Error?
        for source in sources {
            loadProgress = 0
            do {
                let frames = try await frames(from: source, rect: rect, size: size,
                                              reusable: reusable.filter { $0.source == source },
                                              rendering: rendering, force: force)
                guard !Task.isCancelled else { return }
                failure = nil
                activeSource = source
                if let frames { publish(frames, rect: rect, visibleWidth: visibleWidth) }
                return
            } catch {
                guard !Task.isCancelled else { return }
                lastError = error
                if RadarPipeline.isOffline(error) { break }
            }
        }
        // Keep showing the previous frames rather than nothing.
        if let lastError { failure = Self.failure(for: lastError) }
    }

    /// The loop from `source`, or nil if the frames on screen are already current. Throws if the
    /// frame list or the newest frame can't be loaded; a missing older frame just shortens the loop.
    private func frames(from source: RadarSource, rect: MKMapRect, size: (width: Int, height: Int),
                        reusable: [RadarFrame], rendering: RadarRendering, force: Bool) async throws -> [RadarFrame]? {
        let region = source.region(for: region)
        let times = RadarLoop.selectFrames(from: try await client.recentTimes(region: region, force: force),
                                           length: loopLength)
        guard let newest = times.last else { throw RadarClientError.noTimeInCapabilities }

        var loaded: [Date: RadarFrame] = [:]
        // Loaded with other colors: redraw from the saved PNG, no download.
        var restyle: [RadarFrame] = []
        for frame in reusable where times.contains(frame.time) {
            if frame.rendering == rendering {
                loaded[frame.id] = frame
            } else {
                restyle.append(frame)
            }
        }
        let missing = times.filter { time in loaded[time.date] == nil && !restyle.contains { $0.time == time } }
        if missing.isEmpty, restyle.isEmpty, frameSet?.frames.map(\.id) == times.map(\.date) {
            return nil
        }

        enum Work { case download(RadarTime), restyle(RadarFrame) }
        let work = restyle.map(Work.restyle) + missing.map(Work.download)
        var newestError: Error?
        await withTaskGroup(of: (RadarTime, Result<RadarFrame, Error>).self) { group in
            var pending = work[...]
            func addNext() {
                guard let item = pending.popFirst() else { return }
                group.addTask { [client] in
                    switch item {
                    case .restyle(let frame):
                        return (frame.time, Result {
                            try Self.decode(frame.png, time: frame.time, source: source, rendering: rendering)
                        })
                    case .download(let time):
                        do {
                            let image = try await client.fetchImage(region: region, mapRect: rect, width: size.width,
                                                                    height: size.height, time: time)
                            return (time, Result {
                                try Self.decode(image.png, time: time, source: source, rendering: rendering)
                            })
                        } catch {
                            return (time, .failure(error))
                        }
                    }
                }
            }
            for _ in 0..<Self.maxConcurrentRequests { addNext() }
            var done = 0
            for await (time, result) in group {
                done += 1
                switch result {
                case .success(let frame): loaded[frame.id] = frame
                case .failure(let error) where time == newest: newestError = error
                case .failure: break
                }
                if !Task.isCancelled {
                    loadProgress = Double(done) / Double(work.count)
                    addNext()
                }
            }
        }
        try Task.checkCancellation()
        if let newestError { throw newestError }
        return times.compactMap { loaded[$0.date] }
    }

    private func publish(_ frames: [RadarFrame], rect: MKMapRect, visibleWidth: Double) {
        let sameFrames = frameSet.map {
            MKMapRectEqualToRect($0.rect, rect) && $0.frames.map(\.id) == frames.map(\.id)
        } ?? false
        frameSet = RadarFrameSet(rect: rect, visibleWidth: visibleWidth, frames: frames)
        // Only recolored: keep the loop where it was.
        if !sameFrames || !frames.indices.contains(currentIndex) {
            currentIndex = frames.count - 1
        }
        updatePlayback()
    }

    private nonisolated static func decode(_ png: Data, time: RadarTime, source: RadarSource,
                                           rendering: RadarRendering) throws -> RadarFrame {
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options)
        else { throw RadarClientError.notPNG(httpStatus: 200, serviceMessage: nil) }
        let recolored = RadarPalette.recolor(image, source: source, scheme: rendering.colorScheme,
                                             hidesLightReturns: rendering.hidesLightReturns)
        return RadarFrame(time: time, png: png, image: recolored, source: source, rendering: rendering)
    }

    private static func failure(for error: Error) -> RadarFailure {
        RadarPipeline.isOffline(error) ? .network : .service
    }

    // MARK: Playback

    private func updatePlayback() {
        playTask?.cancel()
        playTask = nil
        guard isPlaying, let count = frameSet?.frames.count, count > 1 else { return }
        playTask = Task {
            while !Task.isCancelled {
                let hold = currentIndex == count - 1 ? Self.newestHold : animationSpeed.frameInterval
                try? await Task.sleep(for: hold)
                guard !Task.isCancelled else { return }
                currentIndex = (currentIndex + 1) % count
            }
        }
    }
}
