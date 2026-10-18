import AppKit
import QuartzCore

/// Full-window transparent view that draws the image in a CALayer: zoom, pan, view-only rotation, backdrop clicks.
/// Zoom model: `scale` = screen points per image pixel (1.0 = actual size).
@MainActor
final class ImageCanvasView: NSView {
    static let padding: CGFloat = 40
    static let maxZoom: CGFloat = 16

    let imageLayer = CALayer()
    /// Full-resolution oriented pixel size of the current image.
    private(set) var imageSize: CGSize = .zero
    private(set) var scale: CGFloat = 1
    /// View-only clockwise rotation in degrees: 0, 90, 180 or 270.
    private(set) var rotation = 0
    /// The image center's offset from the view center, in points.
    private(set) var offset = CGPoint.zero
    var onBackdropClick: (() -> Void)?
    /// Called after every change of scale, offset or rotation.
    var onZoomChange: (() -> Void)?
    /// Called for every drag: a drag is mouse movement, which the controls' tracking area doesn't report.
    var onDrag: ((NSEvent) -> Void)?
    /// Where the press began, whether that was on the image (judged at press time: the image can swap before the
    /// release), the offset then, which a drag pans from, and whether it has been dragged (then it is not a click).
    private var press: (point: NSPoint, onImage: Bool, offset: CGPoint, moved: Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        imageLayer.contentsGravity = .resizeAspect // a decode a pixel off the header aspect must not stretch
        imageLayer.minificationFilter = .trilinear
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setImage(_ image: CGImage?, pixelSize: CGSize, rotation: Int) {
        imageSize = pixelSize
        self.rotation = rotation
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        CATransaction.commit()
        fit(animated: false)
    }

    /// The window resizes when its screen changes (resolution change, display unplugged): re-fit.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fit(animated: false)
    }

    private var rotatedSize: CGSize {
        rotation % 180 == 0 ? imageSize : CGSize(width: imageSize.height, height: imageSize.width)
    }

    /// Largest scale that fits inside the padded bounds, never above 100%.
    var fitScale: CGFloat {
        let size = rotatedSize
        guard size.width > 0, size.height > 0 else { return 1 }
        let avail = bounds.insetBy(dx: Self.padding, dy: Self.padding).size
        return min(1, avail.width / size.width, avail.height / size.height)
    }

    var minZoom: CGFloat { max(0.01, fitScale * 0.5) }
    var isFit: Bool { scale == fitScale }
    /// Whether the displayed image is larger than the view on some axis, so there is something to pan.
    var canPan: Bool { rotatedSize.width * scale > bounds.width || rotatedSize.height * scale > bounds.height }

    /// The zoom as a 0...1 slider position, logarithmic from minZoom to maxZoom. Setting it zooms about the center.
    var zoomPosition: Double {
        get { log(scale / minZoom) / log(Self.maxZoom / minZoom) }
        set { zoom(to: minZoom * pow(Self.maxZoom / minZoom, newValue), at: NSPoint(x: bounds.midX, y: bounds.midY)) }
    }

    /// Displayed (rotated) image rect in view coordinates. At 100% it snaps to device pixels: an odd
    /// pixel size would otherwise sit on a half point and render soft on 1x screens.
    var imageFrame: CGRect {
        let size = CGSize(width: rotatedSize.width * scale, height: rotatedSize.height * scale)
        let rect = CGRect(x: bounds.midX + offset.x - size.width / 2, y: bounds.midY + offset.y - size.height / 2,
                          width: size.width, height: size.height)
        guard scale == 1 else { return rect }
        return backingAlignedRect(rect, options: [.alignMinXNearest, .alignMinYNearest, .alignWidthNearest, .alignHeightNearest])
    }

    func fit(animated: Bool = true) { set(fitScale, offset: .zero, animated: animated) }
    func actualSize() { set(1, offset: .zero, animated: true) }
    func zoom(by factor: CGFloat, at point: NSPoint, animated: Bool = false) { zoom(to: scale * factor, at: point, animated: animated) }

    /// Zooms keeping the image point under `point` where it is (as far as the pan limits allow).
    func zoom(to target: CGFloat, at point: NSPoint, animated: Bool = false) {
        let s = min(max(target, minZoom), Self.maxZoom), k = s / scale
        let q = CGPoint(x: point.x - bounds.midX, y: point.y - bounds.midY)
        set(s, offset: CGPoint(x: q.x - (q.x - offset.x) * k, y: q.y - (q.y - offset.y) * k), animated: animated)
    }

    func pan(by delta: CGPoint) {
        set(scale, offset: CGPoint(x: offset.x + delta.x, y: offset.y + delta.y), animated: false)
    }

    func rotate(by degrees: Int) {
        rotation = (rotation + degrees % 360 + 360) % 360
        fit()
    }

    /// Applies a zoom and pan: an axis larger than the view can't be dragged past its edges, a smaller one is centered.
    private func set(_ newScale: CGFloat, offset newOffset: CGPoint, animated: Bool) {
        // Zooming in and back out (×1.25 then ×0.8) can land an ulp off fit; that is fit.
        scale = abs(newScale / fitScale - 1) < 1e-6 ? fitScale : newScale
        let slack = CGPoint(x: max(0, (rotatedSize.width * scale - bounds.width) / 2),
                            y: max(0, (rotatedSize.height * scale - bounds.height) / 2))
        offset = CGPoint(x: min(max(newOffset.x, -slack.x), slack.x), y: min(max(newOffset.y, -slack.y), slack.y))
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.2)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true) // interactive: follow the fingers exactly
        }
        let frame = imageFrame
        imageLayer.bounds.size = rotation % 180 == 0 ? frame.size : CGSize(width: frame.height, height: frame.width)
        imageLayer.position = CGPoint(x: frame.midX, y: frame.midY)
        // Exact quarter turns, clockwise (negative angles in the y-up layer space).
        let (cos, sin): (CGFloat, CGFloat) = [(1, 0), (0, -1), (-1, 0), (0, 1)][rotation / 90]
        let transform = CGAffineTransform(a: cos, b: sin, c: -sin, d: cos, tx: 0, ty: 0)
        if imageLayer.affineTransform() != transform { imageLayer.setAffineTransform(transform) }
        CATransaction.commit()
        onZoomChange?()
    }

    func animateOpen() {
        let zoom = CABasicAnimation(keyPath: "transform.scale")
        zoom.fromValue = 0.94
        zoom.toValue = 1.0
        zoom.duration = 0.22
        zoom.timingFunction = CAMediaTimingFunction(name: .easeOut)
        imageLayer.add(zoom, forKey: "open")
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let onImage = imageFrame.contains(point)
        if event.clickCount == 2 && onImage {
            if isFit { zoom(to: 1, at: point, animated: true) } else { fit() }
        }
        press = (point, onImage, offset, false)
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event)
        guard let press else { return }
        let point = convert(event.locationInWindow, from: nil)
        if hypot(point.x - press.point.x, point.y - press.point.y) >= 4 { self.press?.moved = true }
        set(scale, offset: CGPoint(x: press.offset.x + point.x - press.point.x, y: press.offset.y + point.y - press.point.y),
            animated: false)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer { press = nil }
        guard let press, event.clickCount == 1, !press.moved,
              hypot(point.x - press.point.x, point.y - press.point.y) < 4,
              !press.onImage, !imageFrame.contains(point) else { return }
        onBackdropClick?()
    }
}
