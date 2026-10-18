import AppKit
import QuartzCore

/// Full-window transparent view that draws the image in a CALayer and detects backdrop clicks.
/// Zoom model: `scale` = screen points per image pixel (1.0 = actual size).
@MainActor
final class ImageCanvasView: NSView {
    static let padding: CGFloat = 40

    let imageLayer = CALayer()
    /// Full-resolution oriented pixel size of the current image.
    private(set) var imageSize: CGSize = .zero
    private(set) var scale: CGFloat = 1
    var onBackdropClick: (() -> Void)?
    private var mouseDownPoint: NSPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setImage(_ image: CGImage?, pixelSize: CGSize) {
        imageSize = pixelSize
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        fitToBounds()
        CATransaction.commit()
    }

    /// The window resizes when its screen changes (resolution change, display unplugged): re-fit.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitToBounds()
    }

    private func fitToBounds() {
        scale = fitScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = imageFrame
        CATransaction.commit()
    }

    /// Largest scale that fits inside the padded bounds, never above 100%.
    var fitScale: CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        let avail = bounds.insetBy(dx: Self.padding, dy: Self.padding).size
        return min(1, avail.width / imageSize.width, avail.height / imageSize.height)
    }

    /// Displayed image rect in view coordinates, centered. At 100% it snaps to device pixels: an odd
    /// pixel size would otherwise sit on a half point and render soft on 1x screens.
    var imageFrame: CGRect {
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let rect = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                          width: size.width, height: size.height)
        guard scale == 1 else { return rect }
        return backingAlignedRect(rect, options: [.alignMinXNearest, .alignMinYNearest, .alignWidthNearest, .alignHeightNearest])
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
        mouseDownPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer { mouseDownPoint = nil }
        guard let down = mouseDownPoint, event.clickCount == 1,
              hypot(point.x - down.x, point.y - down.y) < 4,
              !imageFrame.contains(point) else { return }
        onBackdropClick?()
    }
}
