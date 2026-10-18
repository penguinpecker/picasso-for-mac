import AppKit

/// Owns the single full-screen viewer window: backdrop, canvas, key routing, open/close animations.
@MainActor
final class ViewerController: NSViewController {
    let window: ViewerWindow
    let canvas: ImageCanvasView
    private(set) var backdrop = NSView()
    private(set) var currentURL: URL?
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

    /// Shows `url`; the window appears (animated) once the first image is decoded.
    func show(_ url: URL) {
        guard url != currentURL else { return }
        currentURL = url
        #if SELFTEST
        SelfTest.loadCount += 1
        #endif
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let maxPixel = Int(max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor)
        ImageLoader.load(url, maxPixelSize: maxPixel) { [weak self] decoded in
            #if SELFTEST
            SelfTest.decodeCallbacks += 1
            #endif
            guard let self, self.currentURL == url else { return } // a newer open superseded this one
            canvas.setImage(decoded?.image, pixelSize: decoded?.pixelSize ?? .zero)
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
        switch (event.keyCode, command, event.charactersIgnoringModifiers) {
        case (53, _, _): close() // Esc
        case (_, true, "w"): close()
        case (_, true, "q"): NSApp.terminate(nil)
        default: break // swallow: no beeps in a viewer
        }
    }
}

/// A label that never takes clicks, so they reach the canvas (a click on the message is a backdrop click).
final class ClickThroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
