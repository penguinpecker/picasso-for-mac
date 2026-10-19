import AppKit

/// The HUD over the image: name/position pill, bottom bar, thumbnail strip above it (unless turned off in Settings), and
/// edge arrows that appear when the pointer nears an edge.
/// Everything hides together after `hideDelay` without mouse movement. Only visible controls take clicks; the rest
/// of the overlay is transparent to the mouse, so the canvas below gets backdrop clicks, drags and double-clicks.
@MainActor
final class ControlsOverlay: NSView {
    static let hideDelay: TimeInterval = 3

    let previous: HUDButton, next: HUDButton, rotateLeft: HUDButton, rotateRight: HUDButton
    let fit: HUDButton, play: HUDButton, leftArrow: HUDButton, rightArrow: HUDButton
    let zoomSlider = HUDSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    let label = NSTextField(labelWithString: "")
    let pill = hudSurface(radius: 14), bar = hudSurface(radius: 14), stripSurface = hudSurface(radius: 14)
    let strip = ThumbnailStrip()
    let leftCircle = hudSurface(radius: 32), rightCircle = hudSurface(radius: 32)
    /// The fading elements, and whether each is currently meant to be visible (and clickable).
    private lazy var elements = [pill, bar, stripSurface, leftCircle, rightCircle]
    private var visible = [false, false, false, false, false]

    private(set) var isShown = false
    /// The last pointer position seen, in this view's coordinates.
    private var mouse: NSPoint?
    private var hideTimer: Timer?
    private var thumbnailsSetting: NSKeyValueObservation?

    init(target: ViewerController) {
        func button(_ symbol: String, _ tip: String, _ action: Selector) -> HUDButton {
            HUDButton(symbol: symbol, tip: tip, size: 34, pointSize: 15, target: target, action: action)
        }
        previous = button("chevron.left", "Previous", #selector(ViewerController.showPrevious))
        next = button("chevron.right", "Next", #selector(ViewerController.showNext))
        rotateLeft = button("arrow.counterclockwise", "Rotate Left", #selector(ViewerController.rotateLeft))
        rotateRight = button("arrow.clockwise", "Rotate Right", #selector(ViewerController.rotateRight))
        fit = button("1.magnifyingglass", "Actual Size", #selector(ViewerController.toggleFit))
        play = button("play.fill", "Play Slideshow", #selector(ViewerController.toggleSlideshow))
        leftArrow = HUDButton(symbol: "chevron.left", tip: "Previous", size: 64, pointSize: 24, target: target,
                              action: #selector(ViewerController.showPrevious))
        rightArrow = HUDButton(symbol: "chevron.right", tip: "Next", size: 64, pointSize: 24, target: target,
                               action: #selector(ViewerController.showNext))
        super.init(frame: .zero)
        zoomSlider.target = target
        zoomSlider.action = #selector(ViewerController.zoomSliderMoved(_:))
        zoomSlider.controlSize = .small
        zoomSlider.trackFillColor = .white
        zoomSlider.refusesFirstResponder = true
        zoomSlider.toolTip = "Zoom"

        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)

        let stack = NSStackView(views: [previous, next, Self.separator(), rotateLeft, rotateRight, Self.separator(),
                                        zoomSlider, fit, Self.separator(), play])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.onSelect = { [weak target] in target?.go(to: $0) }
        stripSurface.addSubview(strip)
        stripSurface.isHidden = !Settings.showThumbnails
        for (circle, arrow) in [(leftCircle, leftArrow), (rightCircle, rightArrow)] {
            arrow.translatesAutoresizingMaskIntoConstraints = false
            circle.addSubview(arrow)
            NSLayoutConstraint.activate([arrow.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
                                         arrow.centerYAnchor.constraint(equalTo: circle.centerYAnchor)])
        }
        for view in elements {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.alphaValue = 0
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            pill.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            pill.heightAnchor.constraint(equalToConstant: 28),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.5),
            bar.centerXAnchor.constraint(equalTo: centerXAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -28),
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            zoomSlider.widthAnchor.constraint(equalToConstant: 120),
            // Above the bar, as wide as its thumbnails up to 60% of the screen.
            stripSurface.centerXAnchor.constraint(equalTo: centerXAnchor),
            stripSurface.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -10),
            stripSurface.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.6),
            strip.leadingAnchor.constraint(equalTo: stripSurface.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: stripSurface.trailingAnchor),
            strip.topAnchor.constraint(equalTo: stripSurface.topAnchor),
            strip.bottomAnchor.constraint(equalTo: stripSurface.bottomAnchor),
            leftCircle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            rightCircle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
        ])
        for circle in [leftCircle, rightCircle] {
            NSLayoutConstraint.activate([circle.widthAnchor.constraint(equalToConstant: 64), circle.heightAnchor.constraint(equalToConstant: 64),
                                         circle.centerYAnchor.constraint(equalTo: centerYAnchor)])
        }
        // Always active: the pointer is tracked even when another app is frontmost.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
        // Live, also for `defaults write` from outside the app: KVO hears other processes, didChangeNotification doesn't.
        thumbnailsSetting = UserDefaults.standard.observe(\.showThumbnails) { [weak self] _, _ in
            DispatchQueue.main.async { self?.settingsChanged() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        for (view, on) in zip(elements, visible) where on {
            if let hit = view.hitTest(p) { return hit }
        }
        return nil
    }

    // Presses on the pill or the bar's background end here. Unhandled, AppKit's routing delivers them to the canvas
    // (seen in the dblclick self-test), where they would count as backdrop clicks and drags.
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseUp(with event: NSEvent) {}

    override func mouseMoved(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        wake()
    }

    /// The pointer left the window (to another screen): nothing here is hovered any more.
    override func mouseExited(with event: NSEvent) {
        mouse = nil
        apply()
    }

    /// Shows the controls and restarts the hide countdown.
    func wake() {
        isShown = true
        apply()
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(timeInterval: Self.hideDelay, target: self, selector: #selector(hideIfIdle),
                                         userInfo: nil, repeats: false)
    }

    @objc private func hideIfIdle() {
        // Not while the pointer rests on the bar, the strip or a visible arrow.
        if let mouse, zip(elements, visible).dropFirst().contains(where: { $1 && $0.frame.contains(mouse) }) { return wake() }
        hide()
    }

    /// Fades the controls out, the pointer with them (if it is over the viewer, not on another screen) until it moves.
    func hide() {
        hideTimer?.invalidate()
        isShown = false
        apply()
        guard let window, NSMouseInRect(NSEvent.mouseLocation, window.frame, false) else { return }
        NSCursor.setHiddenUntilMouseMoves(true)
        #if SELFTEST
        SelfTest.cursorHides += 1
        #endif
    }

    private func settingsChanged() {
        let hidden = !Settings.showThumbnails
        guard stripSurface.isHidden != hidden else { return }
        stripSurface.isHidden = hidden
        apply()
    }

    /// Name and position for the pill, and which way there is somewhere to go.
    func update(name: String, index: Int, count: Int) {
        let text = NSMutableAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white])
        text.append(NSAttributedString(string: "  \(index + 1) / \(count)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor(white: 1, alpha: 0.55)]))
        label.attributedStringValue = text
        // At a folder end the arrows stay up, dimmed: a vanished arrow would let the next click there hit the backdrop.
        previous.isEnabled = index > 0
        next.isEnabled = index < count - 1
        leftArrow.isEnabled = previous.isEnabled
        rightArrow.isEnabled = next.isEnabled
    }

    /// `canToggle` is false when fit already is 100%: the fit / actual size button has nothing to switch to.
    func showZoom(position: Double, isFit: Bool, zoomedIn: Bool, canToggle: Bool) {
        zoomSlider.doubleValue = position
        fit.isEnabled = canToggle
        if isFit { fit.setSymbol("1.magnifyingglass", tip: "Actual Size") } else {
            fit.setSymbol(zoomedIn ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", tip: "Fit to Screen")
        }
    }

    func showPlaying(_ playing: Bool) {
        play.setSymbol(playing ? "pause.fill" : "play.fill", tip: playing ? "Pause Slideshow" : "Play Slideshow")
    }

    /// Fades each element to its target visibility: everything when shown (the strip if enabled), an arrow only near its edge.
    private func apply() {
        let edge = mouse.map { $0.x < bounds.width * 0.15 ? -1 : $0.x > bounds.width * 0.85 ? 1 : 0 } ?? 0
        let targets = [isShown, isShown, isShown && !stripSurface.isHidden, isShown && edge == -1, isShown && edge == 1]
        for (view, (old, new)) in zip(elements, zip(visible, targets)) where old != new {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                view.animator().alphaValue = new ? 1 : 0
            }
        }
        visible = targets
    }

    private static func separator() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor(white: 1, alpha: 0.15).cgColor
        NSLayoutConstraint.activate([line.widthAnchor.constraint(equalToConstant: 1), line.heightAnchor.constraint(equalToConstant: 18)])
        return line
    }
}

/// Dark translucent rounded surface with a hairline border.
@MainActor
private func hudSurface(radius: CGFloat) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .hudWindow
    view.blendingMode = .withinWindow // blurs the image under it
    view.state = .active
    view.wantsLayer = true
    view.layer?.cornerRadius = radius
    view.layer?.cornerCurve = .continuous
    view.layer?.masksToBounds = true
    view.layer?.borderWidth = 1
    view.layer?.borderColor = NSColor(white: 1, alpha: 0.1).cgColor
    return view
}

/// Borderless white SF Symbol button with hover and press highlights. It takes the first click even when the
/// window isn't key, and never takes keyboard focus (Space and the arrows belong to the viewer).
final class HUDButton: NSButton {
    private var pointSize: CGFloat = 15
    private var symbol = ""
    private var hovering = false { didSet { updateHighlight() } }
    private var pressing = false { didSet { updateHighlight() } }

    convenience init(symbol: String, tip: String, size: CGFloat, pointSize: CGFloat, target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        self.pointSize = pointSize
        self.target = target
        self.action = action
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        contentTintColor = .white
        refusesFirstResponder = true
        focusRingType = .none
        setSymbol(symbol, tip: tip)
        wantsLayer = true
        layer?.cornerRadius = size > 40 ? size / 2 : 8 // the big edge arrows are round
        layer?.cornerCurve = .continuous
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: size), heightAnchor.constraint(equalToConstant: size)])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    func setSymbol(_ name: String, tip: String) {
        guard name != symbol else { return }
        symbol = name
        image = NSImage(systemSymbolName: name, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .semibold))
        toolTip = tip
    }

    override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : 0.3; updateHighlight() } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        pressing = true
        super.mouseDown(with: event) // tracks until the button goes up
        pressing = false
    }

    private func updateHighlight() {
        let alpha: CGFloat = !isEnabled ? 0 : pressing ? 0.22 : hovering ? 0.12 : 0
        layer?.backgroundColor = NSColor(white: 1, alpha: alpha).cgColor
    }
}

final class HUDSlider: NSSlider {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
