#if SELFTEST
import AppKit
import ScreenCaptureKit

/// In-process scenario runner, compiled only into the test build (-D SELFTEST).
/// LIGHTBOX_SELFTEST=<scenario> picks a scenario; it drives the real event paths, asserts on live state,
/// writes <scenario>.json to LIGHTBOX_SELFTEST_OUT and exits 0 (pass) or 1 (fail).
@MainActor
enum SelfTest {
    // Hooks set by product code.
    static var loadCount = 0
    static var openCalls: [[String]] = []
    static var decodeCallbacks = 0
    /// Window alpha (-1 if not on screen) and time right after present() orders the window front.
    private static var presentAlpha = -1.0
    private static var presentTime = 0.0
    static func presented(_ window: NSWindow) {
        presentAlpha = window.isVisible ? Double(window.alphaValue) : -1
        presentTime = now
    }

    private static let env = ProcessInfo.processInfo.environment
    private static let scenario = env["LIGHTBOX_SELFTEST"] ?? ""
    private static let outDir = URL(fileURLWithPath: env["LIGHTBOX_SELFTEST_OUT"] ?? NSTemporaryDirectory())
    private static let fixtures = URL(fileURLWithPath: env["LIGHTBOX_FIXTURES"] ?? "")
    private static weak var app: AppDelegate?
    private static var checks: [[String: Any]] = []
    private static var values: [String: Any] = [:]
    /// Runs inside applicationWillTerminate for scenarios that expect the app to quit.
    private static var onTerminate: (() -> Void)?
    private static var launchTime = 0.0

    static func install(_ delegate: AppDelegate) {
        guard !scenario.isEmpty else { return }
        app = delegate
        launchTime = now
        // Pretend the cursor is on the last screen before the viewer is created.
        if scenario == "screen2", let target = NSScreen.screens.last,
           let m = class_getClassMethod(NSEvent.self, #selector(getter: NSEvent.mouseLocation)) {
            let point = NSPoint(x: target.frame.midX, y: target.frame.midY)
            let block: @convention(block) (AnyObject) -> NSPoint = { _ in point }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
        // The test machine autohides the Dock and menu bar, so visibleFrame == frame there. Give screens a
        // visibleFrame without them, so a viewer sized to visibleFrame instead of frame fails this scenario.
        if scenario == "window", let m = class_getInstanceMethod(NSScreen.self, #selector(getter: NSScreen.visibleFrame)) {
            let block: @convention(block) (NSScreen) -> NSRect = { screen in
                let f = screen.frame
                return NSRect(x: f.minX, y: f.minY + 70, width: f.width, height: f.height - 70 - 24)
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
        print("argv \(CommandLine.arguments) cwd \(FileManager.default.currentDirectoryPath)")
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated {
                values["terminated"] = true
                if let onTerminate { onTerminate() } else { check("no unexpected termination", false, nil) }
                finish()
            }
        }
        Task { await run() }
    }

    private static func run() async {
        switch scenario {
        case "window": await windowScenario()
        case "fit": await fitScenario()
        case "exif": await exifScenario()
        case "formats": await formatsScenario()
        case "large": await largeScenario()
        case "blur": await blurScenario()
        case "click": await clickScenario()
        case "esc": await keyCloseScenario(53, "\u{1b}", [], fade: true)
        case "cmdw": await keyCloseScenario(13, "w", .command, fade: true)
        case "cmdq": await keyCloseScenario(12, "q", .command, fade: false)
        case "activate", "v_activate": await activateScenario()
        case "argv": await argvScenario()
        case "odoc": await odocScenario()
        case "folder": await folderScenario()
        case "panel", "emptyfolder", "odocempty": await panelScenario()
        case "panelodoc": await panelOdocScenario()
        case "screen2": await screen2Scenario()
        case "corrupt": await corruptScenario()
        case "rapid": await rapidScenario()
        case "screenchange": await screenChangeScenario()
        // Verifier probes (round 1): run by name only.
        case "v_layers": await vLayersScenario()
        case "v_folderorder": await vFolderOrderScenario()
        case "v_postclick": await vPostClickScenario()
        case "v_odocnopanel": await vOdocNoPanelScenario()
        // Verifier probes (round 2): run by name only.
        case "v2_argv": await v2ArgvScenario()
        case "v2_escearly": await v2EscEarlyScenario()
        case "v2_edgeclick": await v2EdgeClickScenario()
        case "v2_swap": await v2SwapScenario()
        case "v2_opacity": await v2OpacityScenario()
        case "v2_behind": await v2BehindScenario()
        case "v2_blurctl": await v2BehindScenario(control: true)
        default: check("known scenario", false, scenario)
        }
        finish()
    }

    // MARK: Scenarios

    /// A2 window properties, A3 dim backdrop, A8 open animation, A10 dim screenshot.
    private static func windowScenario() async {
        guard await wait(5, { viewer?.window.isVisible == true }), let v = viewer else {
            return check("window becomes visible", false, nil)
        }
        let w = v.window
        let zoom = v.canvas.imageLayer.animation(forKey: "open") as? CABasicAnimation
        var sawPartial = false
        let reached = await wait(2) {
            if w.alphaValue > 0 && w.alphaValue < 1 { sawPartial = true }
            return w.alphaValue >= 1
        }
        let fadeTime = now - presentTime
        check("open: ordered front at alpha 0", presentAlpha == 0, presentAlpha)
        check("open: alpha passes through partial values", sawPartial, nil)
        check("open: alpha reaches 1", reached && w.alphaValue == 1, Double(w.alphaValue))
        check("open: fade lasts >= 0.12 s after ordering front", fadeTime >= 0.12, fadeTime)
        check("open: image zoom 0.94 -> 1", (zoom?.fromValue as? Double) == 0.94 && (zoom?.toValue as? Double) == 1.0,
              "\(String(describing: zoom?.fromValue)) -> \(String(describing: zoom?.toValue))")

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        check("visibleFrame != frame, so the next check tells them apart", screen.map { $0.visibleFrame != $0.frame } == true,
              screen.map { NSStringFromRect($0.visibleFrame) })
        check("frame == frame of the cursor's screen", screen != nil && w.frame == screen!.frame,
              "window \(NSStringFromRect(w.frame)) screen \(screen.map { NSStringFromRect($0.frame) } ?? "nil")")
        let menuDock = max(CGWindowLevelForKey(.mainMenuWindow), CGWindowLevelForKey(.dockWindow))
        check("above menu bar and Dock (level > \(menuDock))", Int32(w.level.rawValue) > menuDock, w.level.rawValue)
        check("level == .statusBar", w.level == .statusBar, w.level.rawValue)
        check("collectionBehavior has moveToActiveSpace + fullScreenAuxiliary",
              w.collectionBehavior.contains([.moveToActiveSpace, .fullScreenAuxiliary]), w.collectionBehavior.rawValue)
        check("borderless", w.styleMask == .borderless, w.styleMask.rawValue)
        check("isOpaque == false, clear background", !w.isOpaque && w.backgroundColor.alphaComponent == 0, w.isOpaque)
        check("canBecomeKey && canBecomeMain", w.canBecomeKey && w.canBecomeMain, "\(w.canBecomeKey) \(w.canBecomeMain)")
        check("no shadow", !w.hasShadow, w.hasShadow)
        check("exactly one viewer window", viewerWindowCount == 1, viewerWindowCount)

        let alpha = v.backdrop.layer?.backgroundColor?.alpha ?? -1
        check("dim backdrop (not blur)", !(v.backdrop is NSVisualEffectView), type(of: v.backdrop))
        check("dim backdrop alpha == 0.75", abs(alpha - 0.75) < 0.001, alpha)
        check("backdrop fills the window", v.backdrop.frame == v.view.bounds, NSStringFromRect(v.backdrop.frame))
        // The captured window itself: translucent black corners, opaque image in the middle.
        if let shot = screenshot("window") {
            let corner = pixel(shot, x: 0.01, yFromTop: 0.01), center = pixel(shot, x: 0.5, yFromTop: 0.5)
            check("capture: backdrop is translucent black (alpha ~0.75)",
                  abs(corner.a - 0.75) < 0.03 && corner.r < 0.02 && corner.g < 0.02 && corner.b < 0.02, corner)
            check("capture: image area opaque", center.a > 0.99, center)
        }
    }

    /// A4: fit with 40 pt padding, centered, aspect kept, never upscaled.
    private static func fitScenario() async {
        guard let v = await ready() else { return }
        let avail = v.canvas.bounds.insetBy(dx: 40, dy: 40)
        checkFit(v, "landscape", CGSize(width: 4000, height: 3000))
        check("landscape: scale < 1", v.canvas.scale < 1, v.canvas.scale)
        check("landscape: touches the padding", abs(v.canvas.imageLayer.frame.height - avail.height) < 0.01
              || abs(v.canvas.imageLayer.frame.width - avail.width) < 0.01, NSStringFromRect(v.canvas.imageLayer.frame))

        guard await open("02-portrait.jpg", size: CGSize(width: 3000, height: 4000)) else { return }
        checkFit(v, "portrait", CGSize(width: 3000, height: 4000))

        guard await open("03-small.png", size: CGSize(width: 300, height: 200)) else { return }
        checkFit(v, "small", CGSize(width: 300, height: 200))
        let f = v.canvas.imageLayer.frame
        check("small: exactly 300x200 pt (no upscale)", f.size == CGSize(width: 300, height: 200), NSStringFromRect(f))
        check("small: scale == 1", v.canvas.scale == 1, v.canvas.scale)
        check("small: aligned to device pixels", v.canvas.backingAlignedRect(f, options: .alignAllEdgesNearest) == f,
              NSStringFromRect(f))
        check("still one viewer window after re-open", viewerWindowCount == 1, viewerWindowCount)
    }

    /// A5: EXIF orientation 6 displays portrait and upright.
    private static func exifScenario() async {
        guard let v = await ready() else { return }
        let f = v.canvas.imageLayer.frame
        check("oriented size 3000x4000", v.canvas.imageSize == CGSize(width: 3000, height: 4000), v.canvas.imageSize)
        check("displayed portrait (h > w)", f.height > f.width, NSStringFromRect(f))
        if let image = currentImage(v) {
            check("decoded portrait", image.height > image.width, "\(image.width)x\(image.height)")
            checkBands(image, "exif6")
        } else { check("decoded image present", false, nil) }
        screenshot("exif")
    }

    /// A6: every format decodes and shows its content upright.
    private static func formatsScenario() async {
        guard let v = await ready() else { return }
        let cases: [(String, CGSize)] = [
            ("01-landscape.jpg", CGSize(width: 4000, height: 3000)), ("03-small.png", CGSize(width: 300, height: 200)),
            ("05-photo.heic", CGSize(width: 2400, height: 1600)), ("06-photo.webp", CGSize(width: 1600, height: 1200)),
            ("07-photo.tiff", CGSize(width: 1500, height: 1000)), ("08-photo.bmp", CGSize(width: 1200, height: 900)),
            ("09-anim.gif", CGSize(width: 600, height: 400)), ("11-primary.heic", CGSize(width: 1200, height: 1800)),
        ]
        for (name, size) in cases {
            guard await open(name, size: size), let image = currentImage(v) else { check("\(name) displays", false, nil); continue }
            let f = v.canvas.imageLayer.frame
            check("\(name): decoded \(image.width)x\(image.height), shown \(Int(f.width))x\(Int(f.height)) pt",
                  image.width > 0 && f.width > 0 && abs(f.width / f.height - size.width / size.height) < 0.01, nil)
            checkBands(image, name)
        }
    }

    /// A7: huge image decoded off-main (dispatchPrecondition in ImageLoader.decode) at <= screen pixels.
    private static func largeScenario() async {
        guard let v = await ready(timeout: 10) else { return }
        values["launchToVisible"] = now - launchTime
        let screen = v.window.screen!
        let screenPixels = Int(max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor)
        check("oriented size 12000x8000", v.canvas.imageSize == CGSize(width: 12000, height: 8000), v.canvas.imageSize)
        guard let image = currentImage(v) else { return check("decoded image present", false, nil) }
        let longEdge = max(image.width, image.height)
        values["decoded"] = "\(image.width)x\(image.height)"
        values["screenPixels"] = screenPixels
        check("decoded at <= screen pixels (\(screenPixels))", longEdge <= screenPixels, longEdge)
        check("not full res", longEdge < 12000, longEdge)
        let shownPixels = v.canvas.imageLayer.frame.width * screen.backingScaleFactor
        check("decoded >= displayed pixels at fit", CGFloat(image.width) >= shownPixels - 1, "\(image.width) vs \(shownPixels)")
        checkBands(image, "huge")
    }

    /// A3 blur style + A10 blur screenshot. Launched with `-backdropStyle blur`.
    private static func blurScenario() async {
        guard let v = await ready() else { return }
        guard let blur = v.backdrop as? NSVisualEffectView else { return check("backdrop is NSVisualEffectView", false, type(of: v.backdrop)) }
        check("backdrop is NSVisualEffectView", true, nil)
        check("blendingMode .behindWindow", blur.blendingMode == .behindWindow, blur.blendingMode.rawValue)
        check("state .active", blur.state == .active, blur.state.rawValue)
        check("material .fullScreenUI", blur.material == .fullScreenUI, blur.material.rawValue)
        let tint = blur.subviews.first?.layer?.backgroundColor?.alpha ?? -1
        check("dark tint alpha == 0.75 * 0.5", abs(tint - 0.375) < 0.001, tint)
        // Window-only captures don't include what's behind the window, so only darkness is checkable here.
        if let shot = screenshot("blur") {
            let c = pixel(shot, x: 0.01, yFromTop: 0.01)
            check("capture: backdrop dark and not transparent", c.a > 0.3 && max(c.r, c.g, c.b) / c.a < 0.45, c)
        }
    }

    /// A8: image click keeps the viewer, backdrop drag keeps it, backdrop click fades out and quits.
    private static func clickScenario() async {
        guard let v = await ready() else { return }
        let f = v.canvas.imageLayer.frame
        click(NSPoint(x: f.midX, y: f.midY), v.window)
        click(NSPoint(x: f.minX + 5, y: f.maxY - 5), v.window)
        await sleep(0.4)
        check("click on image keeps viewer open", v.window.isVisible && v.window.alphaValue == 1, Double(v.window.alphaValue))
        click(NSPoint(x: 20, y: 20), v.window, to: NSPoint(x: 220, y: 20))
        await sleep(0.4)
        check("drag on backdrop keeps viewer open", v.window.isVisible && v.window.alphaValue == 1, Double(v.window.alphaValue))
        expectQuit(v, fade: true)
        click(NSPoint(x: 20, y: 20), v.window)
        await sleep(2)
        check("backdrop click quits the app", false, "still running after 2 s")
    }

    /// A8: Esc / Cmd+W fade out and quit; Cmd+Q quits.
    private static func keyCloseScenario(_ code: UInt16, _ chars: String, _ modifiers: NSEvent.ModifierFlags, fade: Bool) async {
        guard let v = await ready() else { return }
        let event = key(code, chars, modifiers, v.window)
        if modifiers.contains(.command) {
            let item = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items)
                .first { $0.keyEquivalent == chars && $0.keyEquivalentModifierMask == .command }
            item?.menu?.update()
            check("main menu has an enabled ⌘\(chars.uppercased()) item", item?.isEnabled == true, item?.title)
        }
        expectQuit(v, fade: fade)
        // Real path first: NSApp routes key equivalents to the main menu, plain keys to the key window.
        values["path"] = "NSApp.sendEvent"
        NSApp.sendEvent(event)
        await sleep(0.6)
        // Accessory apps that aren't active have no key window: deliver to the viewer window directly.
        values["path"] = "window.sendEvent"
        v.window.sendEvent(event)
        await sleep(2)
        check("key closes the viewer and quits", false, "still running")
    }

    /// Release path for real keystrokes: launched straight from a terminal, NSApp.activate() makes the viewer
    /// the key window, so Esc routed by NSApp.sendEvent to the key window closes it. (Takes focus briefly.)
    private static func activateScenario() async {
        guard let v = await ready() else { return }
        NSApp.activate()
        let key = await wait(2) { v.window.isKeyWindow }
        values["firstResponder"] = v.window.firstResponder.map { "\(type(of: $0))" } ?? "nil"
        check("window becomes key when the app is active", key, "\(v.window.isKeyWindow) active \(NSApp.isActive)")
        expectQuit(v, fade: true)
        NSApp.sendEvent(self.key(53, "\u{1b}", [], v.window))
        await sleep(2)
        check("Esc via key window quits", false, "still running")
    }

    /// A9: an argv path opens exactly once even if AppKit also delivers it via application(_:open:).
    private static func argvScenario() async {
        guard let v = await ready() else { return }
        await sleep(1)
        values["appkitOpenCalls"] = openCalls
        values["loadCount"] = loadCount
        check("argv image shown", v.currentURL?.lastPathComponent == "01-landscape.jpg", v.currentURL?.path ?? "nil")
        check("opened exactly once", loadCount == 1, loadCount)
        check("one viewer window", viewerWindowCount == 1, viewerWindowCount)
    }

    /// Finder route: launched by LaunchServices (`open -a`), the file arrives once via application(_:open:).
    private static func odocScenario() async {
        guard let v = await ready() else { return }
        await sleep(1)
        values["appkitOpenCalls"] = openCalls
        check("no path in argv", CommandLine.arguments.count == 1, CommandLine.arguments)
        check("application(_:open:) called once with the file",
              openCalls.count == 1 && openCalls.first?.first?.hasSuffix("01-landscape.jpg") == true, openCalls)
        check("image shown", v.currentURL?.lastPathComponent == "01-landscape.jpg", v.currentURL?.path ?? "nil")
        check("opened exactly once", loadCount == 1, loadCount)
    }

    /// A folder argument opens its first image in name order.
    private static func folderScenario() async {
        guard let v = await ready() else { return }
        await sleep(0.5)
        values["appkitOpenCalls"] = openCalls
        check("folder opens first image by name", v.currentURL?.lastPathComponent == "01-landscape.jpg", v.currentURL?.path ?? "nil")
        check("opened exactly once", loadCount == 1, loadCount)
    }

    /// A9: no arguments shows an open panel; cancelling it quits.
    private static func panelScenario() async {
        let found = await wait(5) { NSApp.windows.contains { $0 is NSOpenPanel && $0.isVisible } }
        let panel = NSApp.windows.first { $0 is NSOpenPanel } as? NSOpenPanel
        values["panelClass"] = panel.map { "\(type(of: $0))" } ?? "none"
        check("open panel shown", found, values["panelClass"])
        guard let panel else { return }
        check("panel accepts files and folders", panel.canChooseFiles && panel.canChooseDirectories,
              "\(panel.canChooseFiles) \(panel.canChooseDirectories)")
        check("no viewer before a choice", viewer == nil, nil)
        if scenario == "odocempty" {
            check("folder arrived through application(_:open:)",
                  openCalls.count == 1 && openCalls.first?.first?.hasSuffix("empty-folder") == true, openCalls)
        }
        let items = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items) ?? []
        let edit = [("x", #selector(NSText.cut(_:))), ("c", #selector(NSText.copy(_:))),
                    ("v", #selector(NSText.paste(_:))), ("a", #selector(NSText.selectAll(_:)))]
        check("Edit menu: ⌘X ⌘C ⌘V ⌘A to the first responder", edit.allSatisfy { key, action in
            items.contains { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == .command && $0.action == action && $0.target == nil }
        }, items.map { "\($0.keyEquivalent) \($0.action.map(NSStringFromSelector) ?? "-")" })
        onTerminate = { check("cancel quits the app", true, nil) }
        panel.cancel(nil)
        await sleep(2)
        check("cancel quits the app", false, "still running")
    }

    /// A Finder open (LaunchServices odoc) while the no-file panel is up: the panel's modal session ends,
    /// the viewer gets real queued events, and a backdrop click fades out and quits.
    private static func panelOdocScenario() async {
        guard await wait(5, { NSApp.windows.contains { $0 is NSOpenPanel && $0.isVisible } }) else {
            return check("panel shown", false, nil)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-g", "-a", Bundle.main.bundlePath, env["LIGHTBOX_ODOC_FILE"] ?? ""]
        try? p.run()
        guard await wait(6, { viewer?.window.isVisible == true && viewer?.window.alphaValue == 1 }), let v = viewer else {
            return check("viewer shown after odoc", false, openCalls)
        }
        // Nothing has been posted yet: the panel must end on its own.
        let ended = await wait(1) { NSApp.modalWindow == nil && !NSApp.windows.contains { $0 is NSOpenPanel && $0.isVisible } }
        values["openCalls"] = openCalls
        check("panel closed and its modal session ended", ended, NSApp.modalWindow.map { "modal \(type(of: $0))" })
        check("odoc file shown", v.currentURL?.lastPathComponent == "01-landscape.jpg", v.currentURL?.path)
        expectQuit(v, fade: true)
        postClick(NSPoint(x: 20, y: 20), v.window)
        await sleep(2)
        check("queued backdrop click quits", false, "still running, viewer alpha \(v.window.alphaValue)")
    }

    /// The viewer opens on the screen under the cursor even when that isn't the main screen
    /// (install() points NSEvent.mouseLocation at the last screen for this scenario).
    private static func screen2Scenario() async {
        guard let v = await ready(), let target = NSScreen.screens.last else { return }
        values["screens"] = NSScreen.screens.map { NSStringFromRect($0.frame) }
        values["mouse"] = NSStringFromPoint(NSEvent.mouseLocation)
        let multi = NSScreen.screens.count > 1
        check("cursor screen is not the menu-bar screen", !multi || target != NSScreen.screens[0],
              multi ? nil : "single display: not exercised")
        check("window frame == cursor screen frame", v.window.frame == target.frame,
              "window \(NSStringFromRect(v.window.frame)) target \(NSStringFromRect(target.frame))")
        check("window.screen is the cursor screen", v.window.screen == target, v.window.screen.map { NSStringFromRect($0.frame) })
        let f = v.canvas.imageLayer.frame, b = v.canvas.bounds
        check("image centered in window", abs(f.midX - b.midX) < 0.01 && abs(f.midY - b.midY) < 0.01, NSStringFromRect(f))
        screenshot("screen2")
    }

    /// An undecodable file says so instead of showing an empty backdrop; a good file clears the message.
    /// Launched with a text file named broken.jpg.
    private static func corruptScenario() async {
        guard let v = await ready() else { return }
        let broken = URL(fileURLWithPath: CommandLine.arguments[1])
        func checkMessage(_ stage: String) {
            check("\(stage): message names the file", !v.message.isHidden && v.message.stringValue.contains("broken.jpg"),
                  v.message.stringValue)
            check("\(stage): no image", v.canvas.imageLayer.contents == nil, nil)
        }
        checkMessage("launch")
        screenshot("corrupt")
        guard await open("03-small.png", size: CGSize(width: 300, height: 200)) else { return }
        check("good file hides the message", v.message.isHidden, v.message.stringValue)
        app?.application(NSApp, open: [broken])
        guard await wait(5, { !v.message.isHidden }) else { return check("message after a good file", false, nil) }
        checkMessage("after a good file")
        // The message isn't the image: clicking it closes like the backdrop.
        expectQuit(v, fade: true)
        click(NSPoint(x: v.message.frame.midX, y: v.message.frame.midY), v.window)
        await sleep(2)
        check("click on the message quits", false, "still running")
    }

    /// Opens in quick succession: the last one wins, and a queued stale request is skipped, not decoded.
    private static func rapidScenario() async {
        guard let v = await ready() else { return }
        let before = decodeCallbacks
        for name in ["10-huge.jpg", "03-small.png", "02-portrait.jpg"] {
            app?.application(NSApp, open: [fixtures.appendingPathComponent(name)])
        }
        let portrait = CGSize(width: 3000, height: 4000)
        await wait(5) { v.canvas.imageSize == portrait && currentImage(v) != nil }
        await sleep(0.3) // the serial queue finishes stale work first, so nothing else may arrive
        let image = currentImage(v)
        let decodes = decodeCallbacks - before
        values["decodesForThreeRequests"] = decodes
        check("last opened wins", v.currentURL?.lastPathComponent == "02-portrait.jpg", v.currentURL?.lastPathComponent)
        check("layout matches last", v.canvas.imageSize == portrait, v.canvas.imageSize)
        check("contents is the portrait", image.map { $0.height > $0.width && $0.width < 3000 } == true,
              image.map { "\($0.width)x\($0.height)" })
        check("queued stale request skipped (< 3 decodes for 3 requests)", decodes < 3, decodes)
        check("one window", viewerWindowCount == 1, viewerWindowCount)
    }

    /// A display change (resolution change, unplugged screen) re-frames the window and re-fits the image.
    private static func screenChangeScenario() async {
        guard let v = await ready() else { return }
        let w = v.window, full = w.screen!.frame, landscape = CGSize(width: 4000, height: 3000)
        // Resolution change: the window is still on its screen but no longer matches it.
        w.setFrame(NSRect(x: full.minX, y: full.minY, width: full.width / 2, height: full.height / 3), display: true)
        checkFit(v, "resized window", landscape)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        check("re-framed to its screen", w.frame == full, NSStringFromRect(w.frame))
        checkFit(v, "after screen change", landscape)
        // Unplugged screen: the window is on no screen and moves to the cursor's.
        w.setFrameOrigin(NSPoint(x: -100_000, y: -100_000))
        check("window off every screen", w.screen == nil, w.screen.map { NSStringFromRect($0.frame) })
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        let mouse = NSEvent.mouseLocation
        let cursorScreen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        check("moved to the cursor's screen", cursorScreen != nil && w.frame == cursorScreen!.frame, NSStringFromRect(w.frame))
        checkFit(v, "after moving screens", landscape)
    }

    // MARK: Verifier probes (round 1)

    /// Records which windows (owner + layer only) sit above the viewer, plus key status.
    private static func vLayersScenario() async {
        guard let v = await ready() else { return }
        let w = v.window
        values["isKeyWindow"] = w.isKeyWindow
        values["appActive"] = NSApp.isActive
        values["firstResponder"] = w.firstResponder.map { "\(type(of: $0))" } ?? "nil"
        let mainH = NSScreen.screens[0].frame.height
        let cg = CGRect(x: w.frame.minX, y: mainH - w.frame.maxY, width: w.frame.width, height: w.frame.height)
        let above = (CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], CGWindowID(w.windowNumber)) as? [[String: Any]]) ?? []
        let overlapping: [String] = above.compactMap { info in
            guard let d = info[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: d),
                  r.intersects(cg), (info[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return nil }
            return "\(info[kCGWindowOwnerName as String] ?? "?") layer \(info[kCGWindowLayer as String] ?? "?") \(NSStringFromRect(r))"
        }
        values["aboveViewer"] = overlapping
        let ours = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(w.windowNumber)) as? [[String: Any]])?.first
        values["ourLayer"] = ours?[kCGWindowLayer as String] ?? "?"
        check("recorded", true, overlapping)
    }

    /// Folder opens at its first supported image in Finder order (LIGHTBOX_EXPECT).
    private static func vFolderOrderScenario() async {
        guard let v = await ready() else { return }
        let expect = env["LIGHTBOX_EXPECT"] ?? ""
        check("folder opens \(expect) first", v.currentURL?.lastPathComponent == expect, v.currentURL?.lastPathComponent)
    }

    /// Control: a backdrop click posted into the app's event queue (not sendEvent) closes the viewer.
    private static func vPostClickScenario() async {
        guard let v = await ready() else { return }
        expectQuit(v, fade: true)
        postClick(NSPoint(x: 20, y: 20), v.window)
        await sleep(2)
        check("queued backdrop click quits", false, "still running")
    }

    /// Finder-style cold launch: the file arrives and no open panel is ever created.
    private static func vOdocNoPanelScenario() async {
        guard await ready() != nil else { return }
        await sleep(0.5)
        check("no open panel created", !NSApp.windows.contains { $0 is NSOpenPanel }, NSApp.windows.map { "\(type(of: $0))" })
        check("no modal session", NSApp.modalWindow == nil, NSApp.modalWindow.map { "\(type(of: $0))" })
        check("opened once", loadCount == 1 && openCalls.count == 1, "\(loadCount) \(openCalls)")
    }

    // MARK: Verifier probes (round 2)

    /// Any argv form (relative, symlink, after -NS flag pairs) opens LIGHTBOX_EXPECT exactly once and decodes it.
    private static func v2ArgvScenario() async {
        guard let v = await ready() else { return }
        await sleep(0.8)
        values["openCalls"] = openCalls
        values["url"] = v.currentURL?.path ?? "nil"
        let expect = env["LIGHTBOX_EXPECT"] ?? ""
        check("shows \(expect)", v.currentURL?.lastPathComponent == expect, v.currentURL?.path)
        check("loadCount == 1", loadCount == 1, loadCount)
        check("decoded image present", currentImage(v) != nil, nil)
        check("no open panel", !NSApp.windows.contains { $0 is NSOpenPanel }, nil)
    }

    /// Esc during the open fade (alpha < 1) still fades out and quits.
    private static func v2EscEarlyScenario() async {
        guard await wait(5, { viewer?.window.isVisible == true }), let v = viewer else {
            return check("visible", false, nil)
        }
        values["alphaAtEsc"] = Double(v.window.alphaValue)
        check("Esc sent mid-fade (alpha < 1)", v.window.alphaValue < 1, Double(v.window.alphaValue))
        expectQuit(v, fade: false)
        v.window.sendEvent(key(53, "\u{1b}", [], v.window))
        await sleep(2)
        check("Esc mid-fade quits", false, "still running alpha \(v.window.alphaValue)")
    }

    /// 2 pt inside the image edge keeps the viewer; 2 pt outside (in the padding) closes it.
    private static func v2EdgeClickScenario() async {
        guard let v = await ready() else { return }
        let f = v.canvas.imageLayer.frame
        for p in [NSPoint(x: f.minX + 2, y: f.midY), NSPoint(x: f.maxX - 2, y: f.midY),
                  NSPoint(x: f.midX, y: f.maxY - 2), NSPoint(x: f.midX, y: f.minY + 2)] {
            click(p, v.window)
        }
        await sleep(0.4)
        check("clicks 2 pt inside every edge keep the viewer", v.window.alphaValue == 1, Double(v.window.alphaValue))
        expectQuit(v, fade: true)
        click(NSPoint(x: f.minX - 2, y: f.midY), v.window)
        await sleep(2)
        check("click 2 pt outside the image closes", false, "still running")
    }

    /// Opening another file while visible swaps in place: same window, alpha stays 1, no new open zoom.
    private static func v2SwapScenario() async {
        guard let v = await ready() else { return }
        await sleep(0.4)
        let w = v.window
        app?.application(NSApp, open: [fixtures.appendingPathComponent("02-portrait.jpg")])
        var minAlpha = 1.0, sawOpenAnim = false
        let ok = await wait(5) {
            minAlpha = min(minAlpha, Double(w.alphaValue))
            if v.canvas.imageLayer.animation(forKey: "open") != nil { sawOpenAnim = true }
            return v.canvas.imageSize == CGSize(width: 3000, height: 4000) && currentImage(v)?.height ?? 0 > currentImage(v)?.width ?? 0
        }
        check("swapped to portrait", ok, v.canvas.imageSize)
        check("same window object", viewer?.window === w && viewerWindowCount == 1, viewerWindowCount)
        check("alpha stayed 1 during swap", minAlpha == 1, minAlpha)
        check("no open zoom on swap", !sawOpenAnim, nil)
    }

    /// -backdropOpacity out of range is clamped to 0.3...1.0 (LIGHTBOX_EXPECT = expected alpha).
    private static func v2OpacityScenario() async {
        guard let v = await ready() else { return }
        let alpha = Double(v.backdrop.layer?.backgroundColor?.alpha ?? -1)
        let expect = Double(env["LIGHTBOX_EXPECT"] ?? "") ?? -1
        check("backdrop alpha == \(expect)", abs(alpha - expect) < 0.001, alpha)
    }

    /// Puts an opaque striped window of our own directly under the viewer (covering its whole screen, so nothing
    /// private is behind it), then captures ONLY our two windows with ScreenCaptureKit and samples the backdrop.
    /// Dim: stripes show through at 25%. Blur: stripes must still be distinguishable (content behind is visible).
    private static func v2BehindScenario(control: Bool = false) async {
        guard let v = await ready() else { return }
        let frame = v.window.frame, stripe: CGFloat = 270
        values["reduceTransparency"] = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let under = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        under.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        under.isOpaque = true
        under.backgroundColor = .black
        under.isReleasedWhenClosed = false
        under.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        content.wantsLayer = true
        for i in 0..<Int(ceil(frame.height / stripe)) {
            let l = CALayer()
            l.frame = CGRect(x: 0, y: frame.height - CGFloat(i + 1) * stripe, width: frame.width, height: stripe)
            l.backgroundColor = i % 2 == 0 ? CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1) : CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
            content.layer?.addSublayer(l)
        }
        under.contentView = content
        under.orderFrontRegardless()
        // Control: plain vibrancy windows (not the product) over the stripes, viewer hidden.
        var controls: [NSWindow] = []
        if control {
            for (i, material) in [NSVisualEffectView.Material.fullScreenUI, .hudWindow].enumerated() {
                let r = NSRect(x: frame.minX + CGFloat(i) * 500, y: frame.maxY - 540, width: 400, height: 540)
                let c = NSWindow(contentRect: r, styleMask: .borderless, backing: .buffered, defer: false)
                c.level = .statusBar
                c.isOpaque = false
                c.backgroundColor = .clear
                c.isReleasedWhenClosed = false
                c.appearance = NSAppearance(named: .darkAqua)
                let fx = NSVisualEffectView(frame: NSRect(origin: .zero, size: r.size))
                fx.material = material
                fx.blendingMode = .behindWindow
                fx.state = .active
                c.contentView = fx
                c.orderFrontRegardless()
                controls.append(c)
            }
            v.window.orderOut(nil)
        }
        await sleep(0.8)
        values["style"] = Settings.backdropStyle
        do {
            let sc = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let ids = ([under] + (control ? controls : [v.window])).map { CGWindowID($0.windowNumber) }
            let wins = sc.windows.filter { ids.contains($0.windowID) }
            guard wins.count == ids.count, let display = sc.displays.first(where: { $0.frame.width == frame.width && $0.frame.origin.x == frame.origin.x }) else {
                return check("found our 2 windows + display", false, "\(wins.count) windows")
            }
            let filter = SCContentFilter(display: display, including: wins)
            let config = SCStreamConfiguration()
            let scale = v.window.backingScaleFactor
            config.width = Int(frame.width * scale)
            config.height = Int(frame.height * scale)
            config.showsCursor = false
            let shot = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            // Save the middle band only (no menu bar / Dock strips).
            let crop = shot.cropping(to: CGRect(x: 0, y: CGFloat(shot.height) * 0.1, width: CGFloat(shot.width), height: CGFloat(shot.height) * 0.8))
            if let crop, let png = NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:]) {
                try? png.write(to: outDir.appendingPathComponent("v2_behind-\(control ? "control" : Settings.backdropStyle).png"))
            }
            let x = 150 / frame.width
            let s0 = pixel(shot, x: x, yFromTop: 135 / frame.height)   // green stripe
            let s1 = pixel(shot, x: x, yFromTop: 405 / frame.height)   // magenta stripe
            values["greenSample"] = s0
            values["magentaSample"] = s1
            if control {
                let h0 = pixel(shot, x: 700 / frame.width, yFromTop: 135 / frame.height)
                let h1 = pixel(shot, x: 700 / frame.width, yFromTop: 405 / frame.height)
                values["hudGreen"] = h0
                values["hudMagenta"] = h1
                check("control fullScreenUI: stripes distinguishable", s0.g - s1.g > 0.05 && s1.r - s0.r > 0.05, "\(s0) vs \(s1)")
                check("control hudWindow: stripes distinguishable", h0.g - h1.g > 0.05 && h1.r - h0.r > 0.05, "\(h0) vs \(h1)")
            } else if Settings.backdropStyle == "blur" {
                check("blur: content behind shows through (green stripe greener, magenta stripe redder)",
                      s0.g - s1.g > 0.05 && s1.r - s0.r > 0.05, "\(s0) vs \(s1)")
                check("blur: still dark", max(s0.r, s0.g, s0.b, s1.r, s1.g, s1.b) < 0.8, nil)
            } else {
                check("dim: green stripe at 25%", abs(s0.g - 0.25) < 0.04 && s0.r < 0.06, s0)
                check("dim: magenta stripe at 25%", abs(s1.r - 0.25) < 0.04 && s1.g < 0.06, s1)
            }
        } catch {
            check("ScreenCaptureKit capture", false, "\(error)")
        }
        under.orderOut(nil)
    }

    private static func postClick(_ point: NSPoint, _ window: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.postEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: now,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                               clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!, atStart: false)
        }
    }

    // MARK: Helpers

    private static var viewer: ViewerController? { app?.viewer }
    private static var now: Double { ProcessInfo.processInfo.systemUptime }
    private static var viewerWindowCount: Int { NSApp.windows.filter { $0 is ViewerWindow }.count }

    private static func sleep(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }

    @discardableResult
    private static func wait(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
        let end = now + timeout
        while !condition() {
            if now > end { return false }
            await sleep(0.005)
        }
        return true
    }

    /// Waits until the viewer is fully faded in.
    private static func ready(timeout: Double = 5) async -> ViewerController? {
        let ok = await wait(timeout) { viewer?.window.isVisible == true && viewer?.window.alphaValue == 1 }
        if !ok {
            check("viewer visible within \(timeout) s", false,
                  "loads \(loadCount), open calls \(openCalls), url \(viewer?.currentURL?.path ?? "nil"), windows \(NSApp.windows)")
        }
        return ok ? viewer : nil
    }

    /// Opens a fixture through the Finder path and waits until it is decoded and laid out.
    private static func open(_ name: String, size: CGSize) async -> Bool {
        app?.application(NSApp, open: [fixtures.appendingPathComponent(name)])
        let ok = await wait(5) {
            viewer?.currentURL?.lastPathComponent == name && viewer?.canvas.imageSize == size && viewer.flatMap(currentImage) != nil
        }
        if !ok { check("\(name) loads", false, viewer?.canvas.imageSize) }
        return ok
    }

    /// A4 fit: centered, inside the bounds inset by 40 pt, aspect kept, at min(1, fit) scale.
    private static func checkFit(_ v: ViewerController, _ name: String, _ size: CGSize) {
        let bounds = v.canvas.bounds, avail = bounds.insetBy(dx: 40, dy: 40)
        let f = v.canvas.imageLayer.frame
        let expected = min(1, avail.width / size.width, avail.height / size.height)
        values["\(name)Frame"] = NSStringFromRect(f)
        values["\(name)Scale"] = Double(v.canvas.scale)
        check("\(name): oriented size \(size)", v.canvas.imageSize == size, v.canvas.imageSize)
        check("\(name): inside bounds inset by 40", avail.insetBy(dx: -0.01, dy: -0.01).contains(f), NSStringFromRect(f))
        check("\(name): centered", abs(f.midX - bounds.midX) < 0.01 && abs(f.midY - bounds.midY) < 0.01,
              "\(f.midX),\(f.midY) vs \(bounds.midX),\(bounds.midY)")
        check("\(name): aspect preserved", abs(f.width / f.height - size.width / size.height) < 0.001, f.width / f.height)
        check("\(name): scale == fit scale \(expected)", abs(v.canvas.scale - expected) < 0.0001, v.canvas.scale)
    }

    private static func currentImage(_ v: ViewerController) -> CGImage? {
        guard let contents = v.canvas.imageLayer.contents else { return nil }
        return CFGetTypeID(contents as CFTypeRef) == CGImage.typeID ? (contents as! CGImage) : nil
    }

    /// Fixtures have a red band at the visual top and a blue band at the bottom.
    private static func checkBands(_ image: CGImage, _ name: String) {
        let top = pixel(image, x: 0.5, yFromTop: 0.02), bottom = pixel(image, x: 0.5, yFromTop: 0.98)
        check("\(name): red band on top", top.r > 0.8 && top.g < 0.25 && top.b < 0.25, top)
        check("\(name): blue band at bottom", bottom.b > 0.8 && bottom.r < 0.25 && bottom.g < 0.25, bottom)
    }

    /// Premultiplied sRGB color at a unit position, y measured from the top.
    private static func pixel(_ image: CGImage, x: CGFloat, yFromTop: CGFloat) -> (r: Double, g: Double, b: Double, a: Double) {
        let n = 64
        var buffer = [UInt8](repeating: 0, count: n * n * 4)
        buffer.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        }
        let i = (Int(yFromTop * CGFloat(n - 1)) * n + Int(x * CGFloat(n - 1))) * 4 // bitmap row 0 is the top
        return (Double(buffer[i]) / 255, Double(buffer[i + 1]) / 255, Double(buffer[i + 2]) / 255, Double(buffer[i + 3]) / 255)
    }

    private static func key(_ code: UInt16, _ chars: String, _ modifiers: NSEvent.ModifierFlags, _ window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: now,
                         windowNumber: window.windowNumber, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    /// Mouse down at `point`, up at `to` (a drag when they differ), window coordinates.
    private static func click(_ point: NSPoint, _ window: NSWindow, to: NSPoint? = nil) {
        for (type, p) in [(NSEvent.EventType.leftMouseDown, point), (.leftMouseUp, to ?? point)] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: now,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
        }
    }

    /// Arms the termination check: quitting must happen, with a visible fade when `fade`.
    private static func expectQuit(_ v: ViewerController, fade: Bool) {
        let start = now
        onTerminate = {
            let elapsed = now - start
            values["closeElapsed"] = elapsed
            values["alphaAtTerminate"] = Double(v.window.alphaValue)
            check("app terminates", true, values["path"])
            if fade {
                check("fade-out before quit (>= 0.1 s, alpha ~0)", elapsed >= 0.1 && v.window.alphaValue < 0.05,
                      "\(elapsed) s, alpha \(v.window.alphaValue)")
            }
        }
    }

    /// Captures the viewer window only (never the screen) and returns the image.
    @discardableResult
    private static func screenshot(_ name: String) -> CGImage? {
        guard let w = viewer?.window else { return nil }
        let png = outDir.appendingPathComponent("\(name).png")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", "\(w.windowNumber)", png.path] // this window only
        try? p.run()
        p.waitUntilExit()
        let image = CGImageSourceCreateWithURL(png as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        check("screenshot \(name).png", image != nil, png.path)
        return image
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: Any?) {
        let text = detail.map { "\($0)" } ?? ""
        checks.append(["name": name, "pass": ok, "detail": text])
        print("\(ok ? "  ok  " : "  FAIL") \(name) \(text)")
    }

    private static func finish() -> Never {
        let pass = !checks.isEmpty && checks.allSatisfy { $0["pass"] as? Bool == true }
        let json: [String: Any] = ["scenario": scenario, "pass": pass, "checks": checks,
                                   "values": values.mapValues { "\($0)" }]
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: outDir.appendingPathComponent("\(scenario).json"))
        }
        exit(pass ? 0 : 1)
    }
}
#endif
