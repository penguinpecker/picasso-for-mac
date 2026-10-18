import AppKit

/// Owns the single full-screen viewer window: backdrop, canvas, controls, key/scroll routing, slideshow,
/// open/close animations.
@MainActor
final class ViewerController: NSViewController {
    let window: ViewerWindow
    let canvas: ImageCanvasView
    private(set) var backdrop = NSView()
    private(set) lazy var controls = ControlsOverlay(target: self)
    /// The folder being viewed, in Finder order, and the position in it.
    private(set) var images: [URL] = []
    private(set) var index = 0
    /// The image last asked for; a decode that finishes for any other URL is stale and dropped.
    private(set) var currentURL: URL?
    /// The image on screen (lags `currentURL` while a decode is in flight).
    private(set) var displayedURL: URL?
    /// View-only rotations for this session, never saved.
    private var rotations: [URL: Int] = [:]
    /// Seconds per slide (the self-test shortens it); the slideshow is running while its timer exists.
    var slideshowInterval: TimeInterval = 3
    private(set) var slideshow: Timer?
    /// Precise scroll accumulated over the current trackpad gesture (or smooth-mouse run), and whether the gesture navigated.
    private var swipe = CGPoint.zero
    private var swiped = false
    /// Shown in place of the image when a file can't be decoded.
    let message = ClickThroughLabel(labelWithString: "")
    private var isClosing = false

    init() {
        let screen = Self.cursorScreen
        window = ViewerWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        canvas = ImageCanvasView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(nibName: nil, bundle: nil)

        window.level = .statusBar // above the menu bar and Dock
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.acceptsMouseMovedEvents = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentViewController = self
        window.makeFirstResponder(canvas)
        canvas.onBackdropClick = { [weak self] in self?.close() }
        canvas.onZoomChange = { [weak self] in self?.zoomChanged() }
        canvas.onDrag = { [weak self] event in self?.controls.mouseMoved(with: event) }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static var cursorScreen: NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Keeps covering the screen after a resolution change; if that screen is gone, moves to the cursor's.
    @objc private func screensChanged() {
        window.setFrame((window.screen ?? Self.cursorScreen).frame, display: true)
    }

    override func loadView() {
        view = NSView(frame: canvas.frame)
        canvas.autoresizingMask = [.width, .height]
        view.addSubview(canvas)
        installBackdrop()
        message.font = .systemFont(ofSize: 15, weight: .medium)
        message.textColor = NSColor(white: 1, alpha: 0.75)
        message.isHidden = true
        message.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(message)
        NSLayoutConstraint.activate([message.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                                     message.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        controls.frame = view.bounds
        controls.autoresizingMask = [.width, .height]
        view.addSubview(controls)
    }

    /// Rebuilds the backdrop from Settings (dim layer or behind-window blur with a dark tint).
    func installBackdrop() {
        let opacity = Settings.backdropOpacity
        let new: NSView
        if Settings.backdropStyle == "blur" {
            let blur = NSVisualEffectView()
            blur.material = .fullScreenUI
            blur.blendingMode = .behindWindow
            blur.state = .active
            let tint = NSView(frame: view.bounds)
            tint.wantsLayer = true
            tint.layer?.backgroundColor = NSColor(white: 0, alpha: opacity * 0.5).cgColor
            tint.autoresizingMask = [.width, .height]
            blur.addSubview(tint)
            new = blur
        } else {
            new = NSView()
            new.wantsLayer = true
            new.layer?.backgroundColor = NSColor(white: 0, alpha: opacity).cgColor
        }
        new.frame = view.bounds
        new.autoresizingMask = [.width, .height]
        backdrop.removeFromSuperview()
        view.addSubview(new, positioned: .below, relativeTo: canvas)
        backdrop = new
    }

    /// Shows `images[index]`, replacing the current folder. While visible this swaps in place, no re-open animation,
    /// moving to the cursor's screen if needed. Always decodes, even the file already shown (it may have changed).
    func show(_ images: [URL], at index: Int) {
        let frame = Self.cursorScreen.frame
        if window.frame != frame { window.setFrame(frame, display: true) }
        self.images = images
        currentURL = nil
        go(to: index)
    }

    /// Moves to image `i`, clamped to the folder's ends (no wrap-around).
    func go(to i: Int) {
        guard !images.isEmpty else { return }
        index = min(max(i, 0), images.count - 1)
        controls.update(name: images[index].lastPathComponent, index: index, count: images.count)
        if slideshow != nil { scheduleSlide() } // manual navigation restarts the countdown
        load(images[index])
    }

    /// Decodes off the main thread; the window appears (animated) once the first image is ready.
    private func load(_ url: URL) {
        guard url != currentURL else { return }
        currentURL = url
        message.isHidden = true // a can't-open message belongs to the file being left
        #if SELFTEST
        SelfTest.loadCount += 1
        #endif
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let maxPixel = Int(max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor)
        ImageLoader.load(url, maxPixelSize: maxPixel) { [weak self] decoded in
            #if SELFTEST
            SelfTest.decodeCallbacks += 1
            #endif
            guard let self, self.currentURL == url else { return } // the user moved on: drop the stale result
            displayedURL = url
            canvas.setImage(decoded?.image, pixelSize: decoded?.pixelSize ?? .zero, rotation: rotations[url] ?? 0)
            #if SELFTEST
            SelfTest.shownURL = url
            #endif
            message.stringValue = "Can’t open “\(url.lastPathComponent)”"
            message.isHidden = decoded != nil
            if !window.isVisible { present() }
        }
    }

    private func present() {
        window.alphaValue = 0
        #if !SELFTEST
        NSApp.activate()
        #endif
        window.makeKeyAndOrderFront(nil)
        #if SELFTEST
        SelfTest.presented(window)
        #endif
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
        canvas.animateOpen()
        controls.wake()
    }

    /// Fades out, then quits: closing the viewer ends the app.
    func close() {
        guard !isClosing else { return }
        isClosing = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            window.animator().alphaValue = 0
        }, completionHandler: {
            NSApp.terminate(nil)
        })
    }

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        let center = NSPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
        switch (event.keyCode, command, event.charactersIgnoringModifiers) {
        case (53, _, _): close() // Esc
        case (_, true, "w"): close()
        case (_, true, "q"): NSApp.terminate(nil)
        case (123, _, _): go(to: index - 1) // ←
        case (124, _, _), (49, _, _): go(to: index + 1) // →, Space
        case (115, _, _): go(to: 0) // Home, also Fn+←
        case (119, _, _): go(to: images.count - 1) // End, also Fn+→
        case (_, _, "+"), (_, _, "="): canvas.zoom(by: 1.25, at: center, animated: true)
        case (_, _, "-"): canvas.zoom(by: 1 / 1.25, at: center, animated: true)
        case (_, _, "0"): canvas.fit()
        case (_, _, "1"): canvas.actualSize()
        case (_, _, "r"), (_, _, "R"): rotate(by: event.modifierFlags.contains(.shift) ? -90 : 90)
        default: break // swallow: no beeps in a viewer
        }
    }

    override func scrollWheel(with event: NSEvent) {
        #if SELFTEST
        SelfTest.scrollEvents += 1
        #endif
        // Physical direction (right/down positive) whatever the natural-scrolling setting.
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        let delta = CGPoint(x: event.scrollingDeltaX * sign, y: event.scrollingDeltaY * sign)
        let gesture = !event.phase.isEmpty || !event.momentumPhase.isEmpty // trackpad
        if event.modifierFlags.contains(.command) || (!gesture && Settings.scrollWheelAction == "zoom") {
            // Zoom at the cursor, up = in: a wheel notch is one zoom step, precise deltas zoom smoothly.
            guard delta.y != 0 else { return }
            let factor = event.hasPreciseScrollingDeltas ? exp(-delta.y * 0.005) : delta.y < 0 ? 1.25 : 1 / 1.25
            canvas.zoom(by: factor, at: canvas.convert(event.locationInWindow, from: nil))
            return
        }
        if event.hasPreciseScrollingDeltas && canvas.canPan {
            // Zoomed past the view: two-finger scrolling pans, momentum included (deltas already follow the scrolling setting).
            canvas.pan(by: CGPoint(x: event.scrollingDeltaX, y: -event.scrollingDeltaY))
            return
        }
        guard event.hasPreciseScrollingDeltas else {
            // Mouse wheel: one image per notch, down/right = next.
            let d = abs(delta.x) > abs(delta.y) ? delta.x : delta.y
            if d != 0 { go(to: index + (d > 0 ? 1 : -1)) }
            return
        }
        if event.phase.isEmpty && event.momentumPhase.isEmpty {
            // Smooth-scrolling mice: precise but no gesture phases. Like the wheel (down/right = next), one image
            // per 50 pt along the dominant axis; switching axis starts over.
            if abs(delta.x) > abs(delta.y) { swipe.y = 0; swipe.x += delta.x } else if delta.y != 0 { swipe.x = 0; swipe.y += delta.y }
            let d = swipe.x + swipe.y // one of them is 0
            if abs(d) > 50 { swipe = .zero; go(to: index + (d > 0 ? 1 : -1)) }
            return
        }
        // Trackpad: one image per horizontal swipe, fingers moving left = next. Momentum never navigates.
        if event.phase.contains(.began) { swipe = .zero; swiped = false }
        guard event.momentumPhase.isEmpty, !swiped else { return }
        swipe.x += delta.x
        swipe.y += delta.y
        guard abs(swipe.x) > 50, abs(swipe.x) > abs(swipe.y) else { return }
        go(to: index + (swipe.x < 0 ? 1 : -1))
        swiped = true
    }

    /// Pinch: zoom at the fingers. Handled here, not in the canvas, so it also works over the controls (like scrollWheel).
    override func magnify(with event: NSEvent) {
        canvas.zoom(by: 1 + event.magnification, at: canvas.convert(event.locationInWindow, from: nil))
    }

    // MARK: Actions (keys, bar and edge buttons)

    @objc func showPrevious() { go(to: index - 1) }
    @objc func showNext() { go(to: index + 1) }
    @objc func rotateLeft() { rotate(by: -90) }
    @objc func rotateRight() { rotate(by: 90) }
    @objc func toggleFit() { if canvas.isFit { canvas.actualSize() } else { canvas.fit() } }
    @objc func zoomSliderMoved(_ slider: NSSlider) { canvas.zoomPosition = slider.doubleValue }

    @objc func toggleSlideshow() {
        if let slideshow {
            slideshow.invalidate()
            self.slideshow = nil
        } else {
            scheduleSlide()
        }
        controls.showPlaying(slideshow != nil)
    }

    private func scheduleSlide() {
        slideshow?.invalidate()
        slideshow = Timer.scheduledTimer(timeInterval: slideshowInterval, target: self, selector: #selector(nextSlide),
                                         userInfo: nil, repeats: false)
    }

    @objc private func nextSlide() { go(to: index + 1 < images.count ? index + 1 : 0) } // loops

    /// Rotates the current image, remembered for this session only. While its decode is in flight the turn is
    /// only recorded (setImage applies it), so the image being left keeps its rotation.
    private func rotate(by degrees: Int) {
        guard let url = currentURL else { return }
        rotations[url] = ((rotations[url] ?? 0) + degrees + 360) % 360
        if url == displayedURL { canvas.rotate(by: degrees) }
    }

    private func zoomChanged() {
        controls.showZoom(position: canvas.zoomPosition, isFit: canvas.isFit, zoomedIn: canvas.scale > canvas.fitScale)
    }
}

/// A label that never takes clicks, so they reach the canvas (a click on the message is a backdrop click).
final class ClickThroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
