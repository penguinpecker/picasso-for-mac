import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Decoded pixels: one picture, or an animation's frames. Immutable, so it crosses threads freely.
final class Decoded: @unchecked Sendable {
    /// The picture (an animation's first frame).
    let image: CGImage
    /// Full-resolution size with EXIF orientation applied (may exceed `image` when downsampled).
    let pixelSize: CGSize
    /// An animation's frames and their seconds each (empty for a still image).
    let frames: [CGImage]
    let delays: [Double]

    init(image: CGImage, pixelSize: CGSize, frames: [CGImage] = [], delays: [Double] = []) {
        self.image = image
        self.pixelSize = pixelSize
        self.frames = frames
        self.delays = delays
    }

    var longEdge: Int { max(image.width, image.height) }
    var cost: Int { (frames.isEmpty ? [image] : frames).reduce(0) { $0 + $1.bytesPerRow * $1.height } }
}

/// The decode pipeline, all ImageIO, all off the main thread. Screen-size decodes go into a byte-capped cache: the image
/// being viewed decodes at high priority, its neighbors are preloaded at low priority, and no file decodes twice at once.
/// Full resolution (for zooming past the screen-size decode) is decoded on request and never cached.
/// Read-only: sources are opened without caching and nothing is ever written back.
@MainActor
final class ImageLoader {
    let cache = NSCache<NSURL, Decoded>()
    /// The cache's budget: min(1 GB, RAM / 8), half of it while a full-resolution decode is wanted.
    let costLimit = Int(min(1 << 30, ProcessInfo.processInfo.physicalMemory / 8))
    /// The display's color space. Decodes are drawn into it in the background: Core Animation would otherwise color
    /// match them on the main thread when shown (~10 ms for 2400×1600, ~230 ms for 12000×8000).
    var colorSpace: CGColorSpace?
    /// The viewed image's screen-size decode, preloads, fast thumbnails and full resolution: each on its own queue, so
    /// none holds up another (a full-resolution draw runs for up to a second, uncancellable once drawing). Fast
    /// thumbnails and full resolution go one at a time: two full-resolution working sets at once would double the peak.
    private let current = OperationQueue(), background = OperationQueue(), side = OperationQueue(), large = OperationQueue()
    /// Screen-size decodes queued or running, by file, with whoever waits for each.
    private var jobs: [URL: (op: Operation, isPreload: Bool, waiters: [(Decoded?) -> Void])] = [:]
    /// The latest fast-thumbnail and full-resolution requests.
    private var preview: Operation?, fullResolution: Operation?

    init() {
        cache.totalCostLimit = costLimit
        current.qualityOfService = .userInitiated
        current.maxConcurrentOperationCount = 2 // one stale decode still running never holds up the next
        background.qualityOfService = .utility
        background.maxConcurrentOperationCount = 2
        side.qualityOfService = .userInitiated
        side.maxConcurrentOperationCount = 1
        large.qualityOfService = .userInitiated
        large.maxConcurrentOperationCount = 1
    }

    /// The screen-size decode of `url` at high priority: from the cache at once, else once decoded (joining a decode
    /// already running for it). nil if the file can't be read.
    func load(_ url: URL, maxPixelSize: Int, completion: @escaping (Decoded?) -> Void) {
        if let decoded = cached(url, maxPixelSize: maxPixelSize) { return completion(decoded) }
        var waiters = [completion]
        if let job = jobs[url] {
            guard job.isPreload && !job.op.isExecuting else { return jobs[url]!.waiters.append(completion) }
            job.op.cancel() // a preload still waiting: decode it now, at high priority
            waiters += job.waiters
        }
        enqueue(url, maxPixelSize: maxPixelSize, on: current, waiters: waiters)
    }

    /// The cached screen-size decode of `url` if it has the pixels `maxPixelSize` asks for: one made for a smaller
    /// screen doesn't (an animation shrunk to fit in memory does).
    func cached(_ url: URL, maxPixelSize: Int) -> Decoded? {
        guard let decoded = cache.object(forKey: url as NSURL) else { return nil }
        let wanted = min(maxPixelSize, Int(max(decoded.pixelSize.width, decoded.pixelSize.height)))
        return decoded.longEdge >= wanted || !decoded.frames.isEmpty ? decoded : nil
    }

    /// Screen-size decodes of `urls` into the cache at low priority, in order; skips what is cached or decoding.
    func preload(_ urls: [URL], maxPixelSize: Int) {
        for url in urls where jobs[url] == nil && cached(url, maxPixelSize: maxPixelSize) == nil {
            enqueue(url, maxPixelSize: maxPixelSize, on: background, waiters: [])
        }
    }

    /// The user moved on to `url`: drops every request not started yet except its decode. Screen decodes running finish
    /// into the cache (the viewer ignores their results); fast thumbnails and full resolution stop at their next step.
    func moved(to url: URL) {
        for (key, job) in jobs where key != url && !job.op.isExecuting {
            job.op.cancel()
            jobs[key] = nil
        }
        preview?.cancel()
        fullResolution?.cancel()
        cache.totalCostLimit = costLimit
    }

    /// The file's fast thumbnail with its full size, to stand in while the user flies past.
    func loadPreview(_ url: URL, completion: @escaping (Decoded?) -> Void) {
        preview = run(on: side, completion) { _ in Self.preview(url, maxPixelSize: 384) }
    }

    /// Every pixel (up to the largest texture), for zooming in past the screen-size decode. Not cached; while it is
    /// wanted the cache keeps half its budget, room for it and its decode's working copy (moved(to:) gives it back).
    /// NSCache evicts and frees down to the new limit at once, so before the decode starts.
    func loadFullResolution(_ url: URL, completion: @escaping (Decoded?) -> Void) {
        let space = colorSpace
        cache.totalCostLimit = costLimit / 2
        fullResolution = run(on: large, completion) { Self.decode(url, maxPixelSize: 16384, colorSpace: space, full: true, cancelled: $0) }
    }

    /// `work` on `queue`, given a check for whether it was cancelled; a cancelled request never reports back.
    private func run(on queue: OperationQueue, _ completion: @escaping (Decoded?) -> Void,
                     _ work: @escaping @Sendable (() -> Bool) -> Decoded?) -> Operation {
        let op = BlockOperation()
        op.addExecutionBlock { [weak op] in
            let cancelled = { op?.isCancelled ?? true }
            let decoded = work(cancelled)
            if !cancelled() { DispatchQueue.main.async { completion(decoded) } }
        }
        queue.addOperation(op)
        return op
    }

    private func enqueue(_ url: URL, maxPixelSize: Int, on queue: OperationQueue, waiters: [(Decoded?) -> Void]) {
        let op = BlockOperation(), space = colorSpace
        op.addExecutionBlock { [weak op] in
            let decoded = Self.decode(url, maxPixelSize: maxPixelSize, colorSpace: space)
            DispatchQueue.main.async { self.finished(url, op, decoded) }
        }
        jobs[url] = (op, queue === background, waiters)
        queue.addOperation(op)
    }

    private func finished(_ url: URL, _ op: Operation?, _ decoded: Decoded?) {
        #if SELFTEST
        SelfTest.screenDecodes[url, default: 0] += 1
        #endif
        if let decoded { cache.setObject(decoded, forKey: url as NSURL, cost: decoded.cost) }
        guard let job = jobs[url], job.op === op else { return } // superseded (a preload moved up): its waiters moved too
        jobs[url] = nil
        #if SELFTEST
        SelfTest.decodeCallbacks += job.waiters.count
        #endif
        for waiter in job.waiters { waiter(decoded) }
    }

    // MARK: Decoding (any thread but the main one)

    /// Decodes at most `maxPixelSize` on the long edge (and 400 MB), orientation applied, in `colorSpace` (when given);
    /// `full`: a full-resolution request. An animated GIF decodes every frame, smaller if they would take more than 256 MB.
    /// Stops early, returning nil, once `cancelled`.
    nonisolated static func decode(_ url: URL, maxPixelSize: Int, colorSpace: CGColorSpace?, full: Bool = false,
                                   cancelled: () -> Bool = { false }) -> Decoded? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let size = orientedSize(source) else { return nil }
        let longEdge = Int(max(size.width, size.height))
        let count = CGImageSourceGetCount(source)
        guard count > 1, CGImageSourceGetType(source) as String? == UTType.gif.identifier else {
            let index = CGImageSourceGetPrimaryImageIndex(source)
            let target = min(maxPixelSize, Int(Double(longEdge) * min(1, (Double(400 << 20) / (size.width * size.height * 4)).squareRoot())))
            // Full resolution (scaled down to the 400 MB cap if over it) is drawn from the image itself: ImageIO's
            // thumbnail path holds three copies at full size, four with the color conversion (1.55 GB peak for
            // 12000×8000, against 0.79 GB). So is a thumbnail that comes back short: ImageIO caps a HEIF primary that
            // isn't item 0 at item 0's size.
            let thumbnail = full ? nil : image(source, at: index, maxPixelSize: target, colorSpace, cancelled)
            let picture = thumbnail.flatMap { max($0.width, $0.height) < target ? nil : $0 }
                ?? upright(source, at: index, maxPixelSize: target, colorSpace, cancelled) ?? thumbnail
            return picture.map { Decoded(image: $0, pixelSize: size) }
        }
        var scale = min(1, Double(maxPixelSize) / Double(longEdge))
        let bytes = Double(count) * size.width * size.height * 4 * scale * scale
        let budget = Double(256 << 20)
        if bytes > budget { scale *= (budget / bytes).squareRoot() }
        var frames: [CGImage] = [], delays: [Double] = []
        for i in 0..<count {
            guard let frame = image(source, at: i, maxPixelSize: max(1, Int(Double(longEdge) * scale)), colorSpace) else { continue }
            let gif = (CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any])?[kCGImagePropertyGIFDictionary]
                as? [CFString: Any]
            let delay = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0
            frames.append(frame)
            delays.append(delay < 0.02 ? 0.1 : delay) // as browsers do
        }
        guard let first = frames.first else { return nil }
        return Decoded(image: first, pixelSize: size, frames: frames.count > 1 ? frames : [], delays: frames.count > 1 ? delays : [])
    }

    private nonisolated static func image(_ source: CGImageSource, at index: Int, maxPixelSize: Int, _ space: CGColorSpace?,
                                          _ cancelled: () -> Bool = { false }) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary), !cancelled() else { return nil }
        guard let space, image.colorSpace != space,
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    /// The image at `index` drawn upright (EXIF orientation applied) at most `maxPixelSize` on the long edge, in `space`
    /// (sRGB when nil): one decode, drawn into the result.
    private nonisolated static func upright(_ source: CGImageSource, at index: Int, maxPixelSize: Int, _ space: CGColorSpace?,
                                            _ cancelled: () -> Bool) -> CGImage? {
        guard let stored = CGImageSourceCreateImageAtIndex(source, index, [kCGImageSourceShouldCache: false] as CFDictionary),
              !cancelled() else { return nil }
        let raw = (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] as? Int
        let orientation = (1...8).contains(raw ?? 1) ? raw ?? 1 : 1
        let k = min(1, CGFloat(maxPixelSize) / CGFloat(max(stored.width, stored.height)))
        let w = (CGFloat(stored.width) * k).rounded(), h = (CGFloat(stored.height) * k).rounded()
        let (W, H) = orientation >= 5 ? (h, w) : (w, h)
        guard let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        // EXIF orientations 1–8 as maps from the stored picture to the upright one (y up).
        let maps: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (1, 0, 0, 1, 0, 0), (-1, 0, 0, 1, W, 0), (-1, 0, 0, -1, W, H), (1, 0, 0, -1, 0, H),
            (0, -1, -1, 0, W, H), (0, -1, 1, 0, 0, H), (0, 1, 1, 0, 0, 0), (0, 1, -1, 0, W, 0),
        ]
        let m = maps[orientation - 1]
        ctx.concatenate(CGAffineTransform(a: m.0, b: m.1, c: m.2, d: m.3, tx: m.4, ty: m.5))
        ctx.interpolationQuality = .high
        ctx.draw(stored, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// A thumbnail at most `maxPixelSize` on the long edge, orientation applied: the file's embedded preview when it
    /// has one (fast for camera JPEGs), else downsampled from the image.
    private nonisolated static func thumbnail(_ source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), options as CFDictionary)
    }

    /// The fast thumbnail with the image's full size, so it can be laid out like the image.
    nonisolated static func preview(_ url: URL, maxPixelSize: Int) -> Decoded? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let size = orientedSize(source), let image = thumbnail(source, maxPixelSize: maxPixelSize) else { return nil }
        return Decoded(image: image, pixelSize: size)
    }

    /// Pixel size of the primary image from the header, swapped for EXIF orientations 5–8 (90° rotations).
    /// Primary, not item 0: a HEIF collection or burst may put another picture first (other formats: 0).
    nonisolated static func orientedSize(_ source: CGImageSource) -> CGSize? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0 else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }
}
