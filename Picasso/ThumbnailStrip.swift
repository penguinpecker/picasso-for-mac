import AppKit

/// The film strip above the bar: a thumbnail per image in the folder, the current one highlighted and kept centered.
/// Virtualized for folders of thousands: only images in or near view have a cell (a layer), and only they ask for
/// thumbnails. Thumbnails decode off the main thread into a byte-capped cache, one decode per file at a time; a
/// queued decode for a file scrolled out of view is cancelled, one already running only fills the cache.
/// This goes on while the setting hides the strip: the viewer shows these thumbnails while flying through the folder.
@MainActor
final class ThumbnailStrip: NSView {
    static let cellSize = CGSize(width: 80, height: 64)
    static let gap: CGFloat = 6, inset: CGFloat = 12
    static let pitch = cellSize.width + gap
    /// Cells kept past each end of the view, so a one-step animated scroll never uncovers a gap.
    private static let margin = 2

    var onSelect: ((Int) -> Void)?
    /// The folder, in viewer order. Setting it starts over (decodes still wanted carry on).
    var images: [URL] = [] { didSet { reload() } }
    private(set) var current = 0
    /// How far the strip is scrolled: the content x at the view's left edge.
    private(set) var offset: CGFloat = 0
    /// The cells in or near view, by image index, each showing its thumbnail aspect-fit in its slot.
    private(set) var cells: [Int: CALayer] = [:]
    /// Holds the cells; scrolling moves its bounds origin.
    let content = CALayer()
    /// Thumbnails with their image's full size (the viewer shows them while flying past).
    let cache = NSCache<NSURL, Decoded>()
    /// Thumbnail decodes queued or running, at most one per file.
    private(set) var pending: [URL: Operation] = [:]
    /// Files ImageIO could not thumbnail: never asked again this session (they keep the placeholder).
    private var failed = Set<URL>()
    private let queue = OperationQueue()
    private var lastSelect = 0.0
    private var hovered: Int?
    private var pressed: Int?
    /// Where the pointer rests over the strip (nil when outside), so scrolling can move the highlight under it.
    private var pointer: NSPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(content)
        cache.totalCostLimit = 150 << 20
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .utility
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal) // the overlay caps the width
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 2 * Self.inset + CGFloat(images.count) * Self.pitch - Self.gap, height: Self.cellSize.height + 20)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func reload() {
        for cell in cells.values { cell.removeFromSuperlayer() }
        cells = [:]
        offset = 0
        lastSelect = ProcessInfo.processInfo.systemUptime // a new folder jumps to its image, it never scrolls there animated
        invalidateIntrinsicContentSize()
    }

    /// Highlights image `i` and scrolls it to the middle: animated for a single step, instantly when flying
    /// (selections under 0.25 s apart, as with key repeat) or jumping.
    func select(_ i: Int) {
        let now = ProcessInfo.processInfo.systemUptime, flying = now - lastSelect < 0.25
        lastSelect = now
        current = i
        scroll(to: centered, animated: !flying && abs(clamped(centered) - offset) <= 2 * Self.pitch)
    }

    /// A new size (another folder, another screen) re-centers the current image.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.bounds.size = bounds.size
        content.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
        scroll(to: centered, animated: false)
    }

    private var centered: CGFloat { slot(current).midX - bounds.width / 2 }
    private func clamped(_ x: CGFloat) -> CGFloat { min(max(x, 0), max(0, intrinsicContentSize.width - bounds.width)) }

    private func scroll(to x: CGFloat, animated: Bool) {
        offset = clamped(x)
        hovered = pointer.flatMap { index(at: $0, scrolledTo: offset) } // other thumbnails slide under a resting pointer
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.2)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
            content.removeAllAnimations() // a step still animating would keep sliding
        }
        content.bounds.origin.x = offset
        for (i, cell) in cells { style(cell, i) }
        CATransaction.commit()
        updateCells()
    }

    /// Gives each image in or near view a cell (its thumbnail from the cache, else requested), drops the others and
    /// cancels the queued decodes of files out of view.
    private func updateCells() {
        guard !images.isEmpty else { return }
        let first = max(0, Int(floor((offset - Self.inset) / Self.pitch)) - Self.margin)
        let last = min(images.count - 1, Int(floor((offset + bounds.width - Self.inset) / Self.pitch)) + Self.margin)
        let inView = Set(images[first...last])
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, cell) in cells where i < first || i > last {
            cell.removeFromSuperlayer()
            cells[i] = nil
        }
        for (url, op) in pending where !inView.contains(url) && !op.isExecuting && !op.isFinished {
            op.cancel()
            pending[url] = nil
        }
        for i in first...last where cells[i] == nil {
            let cell = CALayer()
            cell.cornerRadius = 4
            cell.masksToBounds = true
            cell.borderColor = .white
            cell.contentsGravity = .resizeAspectFill
            content.addSublayer(cell)
            cells[i] = cell
            let image = cache.object(forKey: images[i] as NSURL)?.image
            show(image, in: cell, i)
            style(cell, i)
            if image == nil { request(i) }
            #if SELFTEST
            if image != nil { SelfTest.thumbHits += 1 }
            #endif
        }
        CATransaction.commit()
    }

    /// Image i's slot in content coordinates.
    private func slot(_ i: Int) -> CGRect {
        CGRect(x: Self.inset + CGFloat(i) * Self.pitch, y: 10, width: Self.cellSize.width, height: Self.cellSize.height)
    }

    /// Image i's slot in view coordinates, where the strip is scrolled to (drawn there once a step's animation ends).
    func cellFrame(_ i: Int) -> CGRect { slot(i).offsetBy(dx: -offset, dy: 0) }

    /// The image whose slot is at `point` (view coordinates) with the strip scrolled to `x`.
    private func index(at point: NSPoint, scrolledTo x: CGFloat) -> Int? {
        let i = Int(floor((point.x + x - Self.inset) / Self.pitch))
        return images.indices.contains(i) && slot(i).offsetBy(dx: -x, dy: 0).contains(point) ? i : nil
    }

    /// Where the strip is drawn: still on the way to `offset` while a step animates. Clicks go by what is seen.
    private var drawnOffset: CGFloat {
        content.animation(forKey: "bounds") == nil ? offset : content.presentation()?.bounds.origin.x ?? offset
    }

    /// The thumbnail (or a placeholder) aspect-fit in the slot, so the border and corners hug the picture.
    private func show(_ image: CGImage?, in cell: CALayer, _ i: Int) {
        let slot = slot(i)
        var size = slot.size
        if let image {
            let k = min(slot.width / CGFloat(image.width), slot.height / CGFloat(image.height))
            size = CGSize(width: (CGFloat(image.width) * k).rounded(), height: (CGFloat(image.height) * k).rounded())
        }
        cell.contents = image
        cell.backgroundColor = image == nil ? NSColor(white: 1, alpha: 0.08).cgColor : nil
        cell.bounds = CGRect(origin: .zero, size: size)
        cell.position = CGPoint(x: slot.midX, y: slot.midY)
    }

    private func style(_ cell: CALayer, _ i: Int) {
        let isCurrent = i == current
        cell.borderWidth = isCurrent ? 2 : 0
        cell.opacity = isCurrent || i == hovered ? 1 : 0.6
        cell.zPosition = isCurrent ? 1 : 0
        cell.setAffineTransform(isCurrent ? CGAffineTransform(scaleX: 1.1, y: 1.1) : .identity)
    }

    private func request(_ i: Int) {
        let url = images[i]
        guard pending[url] == nil, !failed.contains(url) else { return }
        // ≈ 1.2 × the slot in pixels: sharp, and the embedded EXIF preview usually covers it.
        let maxPixel = Int(max(Self.cellSize.width, Self.cellSize.height) * (window?.backingScaleFactor ?? 2) * 1.2)
        let op = BlockOperation()
        op.addExecutionBlock { [weak self, weak op] in
            let thumbnail = ImageLoader.preview(url, maxPixelSize: maxPixel)
            DispatchQueue.main.async { self?.loaded(thumbnail, url, op) }
        }
        pending[url] = op
        queue.addOperation(op)
        #if SELFTEST
        SelfTest.thumbRequests += 1
        #endif
    }

    private func loaded(_ thumbnail: Decoded?, _ url: URL, _ op: Operation?) {
        if pending[url] === op { pending[url] = nil } // not a newer request for the same file
        #if SELFTEST
        SelfTest.thumbLoads += 1
        #endif
        guard let thumbnail else { failed.insert(url); return }
        cache.setObject(thumbnail, forKey: url as NSURL, cost: thumbnail.cost)
        // A result for a file scrolled out of view (or in another folder) only fills the cache.
        guard let cell = cells.first(where: { images[$0.key] == url }) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        show(thumbnail.image, in: cell.value, cell.key)
        CATransaction.commit()
    }

    // MARK: Mouse

    /// Over the strip the wheel and two-finger scrolling move the strip, not the folder; ⌘ still zooms the image.
    override func scrollWheel(with event: NSEvent) {
        guard !event.modifierFlags.contains(.command) else { return super.scrollWheel(with: event) }
        let d = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        scroll(to: offset - d * (event.hasPreciseScrollingDeltas ? 1 : Self.pitch), animated: false)
    }

    override func mouseDown(with event: NSEvent) {
        pressed = index(at: convert(event.locationInWindow, from: nil), scrolledTo: drawnOffset)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil }
        if let pressed, pressed == index(at: convert(event.locationInWindow, from: nil), scrolledTo: drawnOffset) {
            onSelect?(pressed)
        }
    }

    /// The highlight goes by where the strip is headed, so it is right once a step's animation ends.
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        pointer = p
        hover(index(at: p, scrolledTo: offset))
        super.mouseMoved(with: event) // on to the overlay, which keeps the controls up
    }

    override func mouseExited(with event: NSEvent) {
        pointer = nil
        hover(nil)
    }

    private func hover(_ i: Int?) {
        guard i != hovered else { return }
        let old = hovered
        hovered = i
        for j in [old, i].compactMap({ $0 }) { if let cell = cells[j] { style(cell, j) } }
    }
}
