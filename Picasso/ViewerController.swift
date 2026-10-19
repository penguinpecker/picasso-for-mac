import AppKit

/// Owns the single full-screen viewer window: backdrop, canvas, controls, key/scroll routing, slideshow,
/// open/close animations.
@MainActor
final class ViewerController: NSViewController {
    let window: ViewerWindow
    let canvas: ImageCanvasView
    private(set) var backdrop = NSView()
    private(set) lazy var controls = ControlsOverlay(target: self)
    let loader = ImageLoader()
    /// The folder being viewed, in Finder order, and the position in it.
    private(set) var images: [URL] = []
    private(set) var index = 0
    /// The image last asked for.
    private(set) var currentURL: URL?
    /// Bumped by every navigation: a result asked for under an older one is stale and dropped.
    private var generation = 0
    /// The image on screen (lags `currentURL` until something of it can be shown), the generation it was laid out
    /// for, and its pixels (fast thumbnail, screen-size or full-resolution decode).
    private(set) var displayedURL: URL?
    private var displayedGeneration = -1
    private(set) var shown: Decoded?
    private var lastNavigation = 0.0
    /// Starts the decode where the user stops: debounced while flying through the folder.
    private var landing: Timer?
    private var fullResolutionRequested = false
    /// View-only rotations for this session, never saved.
    private var rotations: [URL: Int] = [:]
    /// Seconds per slide (the self-test shortens it); the slideshow is running while its timer exists.
    var slideshowInterval: TimeInterval = 3
    private(set) var slideshow: Timer?
    /// Keeps the display awake while the slideshow plays.
    private(set) var slideshowActivity: NSObjectProtocol?
    /// Precise scroll accumulated over the current trackpad gesture (or smooth-mouse run), whether the gesture navigated,
    /// and whether the last precise event was part of a gesture (has phases) or of a smooth-mouse run.
    private var swipe = CGPoint.zero
    private var swiped = false
    private var inGesture = false
    /// Shown in place of the image when a file can't be decoded.
    let message = ClickThroughLabel(labelWithString: "")
    private var isClosing = false
    private var backdropSettings: [NSKeyValueObservation] = []

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
        backdropSettings = [UserDefaults.standard.observe(\.backdropOpacity) { [weak self] _, _ in
                                DispatchQueue.main.async { self?.installBackdrop() } },
                            UserDefaults.standard.observe(\.backdropStyle) { [weak self] _, _ in
                                DispatchQueue.main.async { self?.installBackdrop() } }]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static var cursorScreen: NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Keeps covering the screen after a resolution change; if that screen is gone, moves to the cursor's. A sharper
    /// screen gets a bigger decode.
    @objc private func screensChanged() {
        window.setFrame((window.screen ?? Self.cursorScreen).frame, display: true)
        land()
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
        controls.strip.images = images
        currentURL = nil
        loader.cache.removeObject(forKey: images[index] as NSURL)
        go(to: index)
    }

    /// Moves to image `i`, clamped to the folder's ends (no wrap-around).
    func go(to i: Int) {
        guard !images.isEmpty else { return }
        index = min(max(i, 0), images.count - 1)
        controls.update(name: images[index].lastPathComponent, index: index, count: images.count)
        controls.strip.select(index)
        if slideshow != nil { scheduleSlide() } // manual navigation restarts the countdown
        load(images[index])
    }

    /// Shows `url`: its screen-size decode at once if cached; else, when flying through the folder (steps under 0.25 s
    /// apart, as with key repeat), a thumbnail: the strip's at once if it has one, else a fast one once decoded (the
    /// image being left stays meanwhile, dimmed). Decoding starts where the user stops: at once for a single step,
    /// debounced while flying, so each step costs the main thread next to nothing.
    private func load(_ url: URL) {
        guard url != currentURL else { return }
        currentURL = url
        generation += 1
        fullResolutionRequested = false
        message.isHidden = true // a can't-open message belongs to the file being left
        #if SELFTEST
        SelfTest.loadCount += 1
        #endif
        let time = ProcessInfo.processInfo.systemUptime, flying = time - lastNavigation < 0.25
        lastNavigation = time
        loader.moved(to: url)
        landing?.invalidate()
        if let cached = loader.cached(url, maxPixelSize: screenPixels) {
            display(cached, url)
        } else if flying, window.isVisible, let thumbnail = controls.strip.cache.object(forKey: url as NSURL) {
            showPreview(thumbnail, url)
        } else if window.isVisible {
            canvas.dim()
            if flying {
                let generation = generation
                loader.loadPreview(url) { [weak self] preview in
                    guard let self, generation == self.generation, displayedGeneration != generation, let preview else { return }
                    showPreview(preview, url)
                }
            }
        }
        if flying {
            landing = Timer.scheduledTimer(timeInterval: 0.1, target: self, selector: #selector(land), userInfo: nil, repeats: false)
        } else {
            land()
        }
    }

    /// A thumbnail standing in for `url` while flying past, laid out by the image's full size.
    private func showPreview(_ preview: Decoded, _ url: URL) {
        canvas.setImage(preview, rotation: rotations[url] ?? 0)
        displayedGeneration = generation
        displayedURL = url
        shown = preview
        #if SELFTEST
        SelfTest.previewShown(url)
        #endif
    }

    /// The user stopped on the current image: decode it if needed, then preload two neighbors each way.
    @objc private func land() {
        guard let url = currentURL else { return }
        let generation = generation
        loader.colorSpace = window.colorSpace?.cgColorSpace
        loader.load(url, maxPixelSize: screenPixels) { [weak self] decoded in
            guard let self, generation == self.generation else {
                #if SELFTEST
                SelfTest.staleDropped += 1
                #endif
                return
            }
            if displayedGeneration != generation || decoded !== shown { display(decoded, url) }
            let neighbors = [index + 1, index + 2, index - 1, index - 2].filter(images.indices.contains).map { self.images[$0] }
            loader.preload(neighbors, maxPixelSize: screenPixels)
        }
    }

    /// Puts a decode of `url` on screen: in place of a smaller version shown for this visit, else laid out fresh at fit.
    /// nil: the can't-open message. The window appears (animated) with the first image.
    private func display(_ decoded: Decoded?, _ url: URL) {
        if displayedGeneration == generation, let decoded {
            // A late, smaller decode never replaces a sharper one, but an animation (maybe shrunk to fit in memory,
            // smaller than the still shown while flying) always replaces a still.
            guard !decoded.frames.isEmpty || decoded.longEdge >= shown?.longEdge ?? 0 else { return }
            canvas.setPixels(decoded)
        } else {
            canvas.setImage(decoded, rotation: rotations[url] ?? 0)
        }
        displayedGeneration = generation
        displayedURL = url
        shown = decoded
        #if SELFTEST
        SelfTest.shownURL = url
        #endif
        message.stringValue = "Can’t open “\(url.lastPathComponent)”"
        message.isHidden = decoded != nil
        if !window.isVisible { present() }
    }

    /// The screen's long edge in pixels: a screen-size decode has no more.
    private var screenPixels: Int {
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens[0]
        return Int(max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor)
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
        stopSlideshow()
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
        case (_, true, ","): Settings.show()
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
        if event.hasPreciseScrollingDeltas {
            // Each gesture starts over, also one begun with ⌘ (so before the zoom return), and smooth-mouse runs and
            // gestures never inherit each other's leftovers.
            if event.phase.contains(.began) || gesture != inGesture { swipe = .zero; swiped = false }
            inGesture = gesture
        }
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
        guard slideshow == nil else { return stopSlideshow() }
        scheduleSlide()
        slideshowActivity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated],
                                                                  reason: "Slideshow")
        controls.showPlaying(true)
    }

    private func stopSlideshow() {
        slideshow?.invalidate()
        slideshow = nil
        if let slideshowActivity { ProcessInfo.processInfo.endActivity(slideshowActivity) }
        slideshowActivity = nil
        controls.showPlaying(false)
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
        controls.showZoom(position: canvas.zoomPosition, isFit: canvas.isFit, zoomedIn: canvas.scale > canvas.fitScale,
                          canToggle: !(canvas.isFit && canvas.fitScale == 1))
        // Zoomed in past what a screen-size decode holds: swap in every pixel (kept until the next image).
        let longEdge = max(canvas.imageSize.width, canvas.imageSize.height), limit = CGFloat(screenPixels)
        guard let url = currentURL, displayedGeneration == generation, !fullResolutionRequested, longEdge > limit,
              longEdge * canvas.scale * window.backingScaleFactor > limit else { return }
        fullResolutionRequested = true
        let generation = generation
        loader.loadFullResolution(url) { [weak self] full in
            guard let self, generation == self.generation, let full else { return }
            display(full, url)
        }
    }
}

/// A label that never takes clicks, so they reach the canvas (a click on the message is a backdrop click).
final class ClickThroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
