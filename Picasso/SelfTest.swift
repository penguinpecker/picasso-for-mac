#if SELFTEST
import AppKit
import UniformTypeIdentifiers

/// In-process scenario runner, compiled only into the test build (-D SELFTEST).
/// PICASSO_SELFTEST=<scenario> picks a scenario; it drives the real event paths, asserts on live state,
/// writes <scenario>.json to PICASSO_SELFTEST_OUT and exits 0 (pass) or 1 (fail).
@MainActor
enum SelfTest {
    // Hooks set by product code.
    static var loadCount = 0
    static var openCalls: [[String]] = []
    static var decodeCallbacks = 0
    static var scrollEvents = 0
    static var cursorHides = 0
    /// Thumbnail decodes queued, decodes delivered (cancelled ones never are), and cells served from the cache.
    static var thumbRequests = 0 { didSet { if oldValue == 0 { firstThumbRequest = now } } }
    static var thumbLoads = 0 { didSet { lastThumbLoad = now } }
    static var thumbHits = 0
    private static var firstThumbRequest = 0.0, lastThumbLoad = 0.0
    private static var sentScrolls = 0
    /// Set when the viewer puts a decode on screen. Anything shown that isn't the current image is stale.
    static var shownURL: URL? {
        didSet {
            shownCount += 1
            if shownURL != viewer?.currentURL { staleShown.append(shownURL?.lastPathComponent ?? "nil") }
        }
    }
    private static var shownCount = 0
    private static var staleShown: [String] = []
    /// Fast thumbnails put on screen while flying (stale ones are recorded too), and decodes that arrived stale.
    static var previews = 0
    static var staleDropped = 0
    /// Screen-size decodes run, by file.
    static var screenDecodes: [URL: Int] = [:]
    static func previewShown(_ url: URL) {
        previews += 1
        if url != viewer?.currentURL { staleShown.append("preview " + url.lastPathComponent) }
    }
    /// Window alpha (-1 if not on screen) and time right after present() orders the window front.
    private static var presentAlpha = -1.0
    private static var presentTime = 0.0
    static func presented(_ window: NSWindow) {
        presentAlpha = window.isVisible ? Double(window.alphaValue) : -1
        presentTime = now
    }

    private static let env = ProcessInfo.processInfo.environment
    private static let scenario = env["PICASSO_SELFTEST"] ?? ""
    private static let outDir = URL(fileURLWithPath: env["PICASSO_SELFTEST_OUT"] ?? NSTemporaryDirectory())
    private static let fixtures = URL(fileURLWithPath: env["PICASSO_FIXTURES"] ?? "")
    private static weak var app: AppDelegate?
    /// NSEvent.mouseLocation in the screen2 scenario.
    private static var fakeMouse = NSPoint.zero
    private static var checks: [[String: Any]] = []
    private static var values: [String: Any] = [:]
    /// Runs inside applicationWillTerminate for scenarios that expect the app to quit.
    private static var onTerminate: (() -> Void)?
    private static var launchTime = 0.0

    static func install(_ delegate: AppDelegate) {
        guard !scenario.isEmpty else { return }
        // test.sh preflight: with the display asleep or the session locked, every GUI scenario would fail for no reason.
        if scenario == "preflight" {
            let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
            let asleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
            let onConsole = session["kCGSSessionOnConsoleKey"] as? Bool ?? false
            let locked = session["CGSSessionScreenIsLocked"] as? Bool ?? false
            print("display asleep: \(asleep), session on console: \(onConsole), screen locked: \(locked)")
            exit(asleep || !onConsole || locked ? 2 : 0)
        }
        app = delegate
        launchTime = now
        // The thumbs scenario turns this off; a run killed before it cleaned up must not leave it off for the next.
        UserDefaults.standard.removeObject(forKey: "showThumbnails")
        // screen2: pretend the cursor is on the last screen before the viewer is created (the scenario moves it later).
        // autohide: start where it really is, then move it off the viewer.
        if ["screen2", "autohide"].contains(scenario), let target = NSScreen.screens.last,
           let m = class_getClassMethod(NSEvent.self, #selector(getter: NSEvent.mouseLocation)) {
            fakeMouse = scenario == "screen2" ? NSPoint(x: target.frame.midX, y: target.frame.midY) : NSEvent.mouseLocation
            let block: @convention(block) (AnyObject) -> NSPoint = { _ in fakeMouse }
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
        // The owner may be using the machine: real pointer and keyboard input must not steer a scenario (a real click
        // on the viewer activates the app, then real keys reach it). Synthesized events go straight to
        // window.sendEvent, or through the queue tagged with `synthetic` (button tracking loops need that), or are
        // keys sent through NSApp by sendKey.
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseEntered, .mouseExited, .leftMouseDown, .leftMouseUp,
                                                    .leftMouseDragged, .rightMouseDown, .rightMouseUp, .otherMouseDown,
                                                    .otherMouseUp, .scrollWheel, .magnify, .swipe, .rotate,
                                                    .keyDown, .keyUp, .flagsChanged]) { event in
            let pass = MainActor.assumeIsolated {
                event.type == .keyDown ? sendingKey
                    : [.leftMouseDown, .leftMouseUp, .leftMouseDragged].contains(event.type) && event.eventNumber == synthetic
            }
            return pass ? event : nil
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
        case "activate": await activateScenario()
        case "argv": await argvScenario()
        case "odoc": await odocScenario()
        case "folder": await folderScenario()
        case "panel", "emptyfolder", "odocempty": await panelScenario()
        case "panelodoc": await panelOdocScenario()
        case "screen2": await screen2Scenario()
        case "corrupt": await corruptScenario()
        case "rapid": await rapidScenario()
        case "screenchange": await screenChangeScenario()
        case "escearly": await escEarlyScenario()
        case "edgeclick": await edgeClickScenario()
        case "opacity": await opacityScenario()
        case "index": await indexScenario()
        case "keys": await keysScenario()
        case "wheel": await wheelScenario()
        case "stale": await staleScenario()
        case "secondopen": await secondOpenScenario()
        case "zoomkeys": await zoomKeysScenario()
        case "zoompoint": await zoomPointScenario()
        case "zoommode": await zoomModeScenario()
        case "pan": await panScenario()
        case "rotate": await rotateScenario()
        case "dblclick": await doubleClickScenario()
        case "bar": await barScenario()
        case "slideshow": await slideshowScenario()
        case "autohide": await autoHideScenario()
        case "label": await labelScenario()
        case "strip": await stripScenario()
        case "thumbs": await thumbsScenario()
        case "fly": await flyScenario()
        case "flypng", "flypnghidden": await flyPNGScenario()
        case "gif": await gifScenario()
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
        // The full-resolution path turns the stored pixels itself: each orientation must come out as ImageIO's thumbnail
        // path turns it, in JPEG (EXIF), HEIC (irot/imir boxes) and RAW (DNG, through ImageIO's RAW engine), at full size
        // and scaled down as over the 400 MB cap (orient/o1–o8: one 300×200 picture, red, green over blue, yellow).
        func quadrants(_ d: Decoded?) -> [String] {
            guard let i = d?.image else { return [] }
            return [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)].map { classify(pixel(i, x: $0, yFromTop: $1)) }
        }
        for ext in ["jpg", "heic", "dng"] {
            var looks: Set<[String]> = []
            for o in 1...8 {
                let url = fixtures.appendingPathComponent("orient/o\(o).\(ext)")
                for size in [16384, 150] {
                    let (theirs, ours) = await Task.detached {
                        (ImageLoader.decode(url, maxPixelSize: size, colorSpace: nil),
                         ImageLoader.decode(url, maxPixelSize: size, colorSpace: nil, full: true))
                    }.value
                    let a = quadrants(theirs), b = quadrants(ours)
                    if size > 150 { looks.insert(a) }
                    check("o\(o).\(ext) \(size > 150 ? "full size" : "scaled"): full-resolution path \(b) "
                          + "\(ours.map { "\($0.image.width)x\($0.image.height)" } ?? "-") like ImageIO's",
                          a.count == 4 && a == b && Set(a).count == 4 && ours?.image.width == theirs?.image.width
                          && ours?.image.height == theirs?.image.height && ours?.pixelSize == theirs?.pixelSize
                          && ours.map { max($0.image.width, $0.image.height) } == min(size, 300), a)
                }
            }
            check("the 8 .\(ext) orientations all look different (each file carries its own)", looks.count == 8, looks.count)
        }
        let raw = CGImageSourceCreateWithURL(fixtures.appendingPathComponent("orient/o6.dng") as CFURL, nil).flatMap(CGImageSourceGetType)
        check("the .dng fixtures decode through ImageIO's RAW path", (raw as String?).flatMap(UTType.init)?.conforms(to: .rawImage) == true,
              raw)
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
        let screen = v.window.screen!, screenPixels = Int(max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor)
        for (name, size) in cases {
            guard await open(name, size: size), let image = currentImage(v) else { check("\(name) displays", false, nil); continue }
            let f = v.canvas.imageLayer.frame
            // 11-primary.heic: ImageIO's thumbnail of a HEIF primary that isn't item 0 stops at item 0's 800 px.
            let wanted = min(screenPixels, Int(max(size.width, size.height)))
            check("\(name): decoded at full screen size (long edge \(wanted))", max(image.width, image.height) == wanted,
                  "\(image.width)x\(image.height)")
            check("\(name): decoded \(image.width)x\(image.height), shown \(Int(f.width))x\(Int(f.height)) pt",
                  image.width > 0 && f.width > 0 && abs(f.width / f.height - size.width / size.height) < 0.01, nil)
            check("\(name): through the pipeline (the cached screen-size decode is what is shown)",
                  v.shown != nil && v.shown === v.loader.cache.object(forKey: v.currentURL! as NSURL) && v.shown?.image === image, nil)
            checkBands(image, name)
        }
        // RAW (no fixture): a file named with any camera-raw type's extension that ImageIO decodes is listed.
        let raws = (CGImageSourceCopyTypeIdentifiers() as? [String] ?? []).compactMap { UTType($0) }.filter { $0.conforms(to: .rawImage) }
        let exts = Set(raws.flatMap { $0.tags[.filenameExtension] ?? [] })
        let dir = outDir.appendingPathComponent("formats-raw-names")
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for ext in exts { FileManager.default.createFile(atPath: dir.appendingPathComponent("x.\(ext)").path, contents: Data()) }
        let listed = Set(FolderIndex.images(in: dir).map(\.pathExtension))
        values["rawExtensions"] = exts.sorted()
        check("RAW: ImageIO reports camera-raw types (\(raws.count))", raws.count > 10 && exts.isSuperset(of: ["cr2", "cr3", "nef", "arw", "dng", "raf"]),
              raws.map(\.identifier))
        check("RAW: every one of their \(exts.count) extensions is listed", listed == exts, exts.subtracting(listed).sorted())
        try? FileManager.default.removeItem(at: dir)
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

        // E4: zoomed in to 100%, the full-resolution decode is swapped in off the main thread and stays.
        let c = v.canvas, w = v.window, screenDecode = v.shown
        v.controls.hide()
        await sleep(0.4)
        startHeartbeat()
        let t0 = now
        press(18, "1", [], w)
        let swapped = await wait(5) { (currentImage(v)?.width ?? 0) == 12000 }
        values["fullResolutionAfter"] = now - t0
        check("E4 at 100% the full-resolution decode is swapped in (12000 wide)", swapped && currentImage(v)?.height == 8000,
              currentImage(v).map { "\($0.width)x\($0.height)" })
        values["memoryWithFullResolution"] = "resident \(memory().resident / 1e6) MB, peak \(memory().peak / 1e6) MB"
        check("E4 while it is wanted the cache keeps half its budget", v.loader.cache.totalCostLimit == v.loader.costLimit / 2,
              v.loader.cache.totalCostLimit)
        check("E4 the swap keeps the layout: 100%, centered", c.scale == 1 && abs(c.imageLayer.frame.midX - c.bounds.midX) < 0.5
              && c.imageLayer.frame.width == 12000, NSStringFromRect(c.imageLayer.frame))
        for k in 0..<12 { // trackpad pans across it, then further zoom in and back
            w.sendEvent(scroll(k < 6 ? 120 : -120, 40, precise: true, phase: 2, inverted: true, w))
            await sleep(0.03)
        }
        press(24, "=", [], w)
        await sleep(0.3)
        press(18, "1", [], w)
        await sleep(0.3)
        let beat = stopHeartbeat()
        values["heartbeat"] = beat
        check("E4 main thread never blocked > 50 ms (zoom, full decode, swap, pans)", beat.max < 0.05, beat)
        check("E4 still the full-resolution pixels after panning and zooming", currentImage(v)?.width == 12000, currentImage(v)?.width)
        // Crisp: at 100% the full decode's glyph edges are far sharper than the screen-size decode stretched there.
        let region = NSRect(x: c.bounds.midX - 500, y: c.bounds.midY - 300, width: 1000, height: 600)
        guard let full = v.shown, let screenDecode, let crisp = screenshot("large-100") else { return }
        c.setPixels(screenDecode)
        await sleep(0.3)
        let soft = screenshot("large-100-screen-decode")
        c.setPixels(full)
        let sharp = sharpness(crisp, region, w), blurred = soft.map { sharpness($0, region, w) } ?? -1
        values["edgeStep"] = "full \(sharp), screen-size decode \(blurred)"
        check("E4 crisp: full-resolution edge steps > 2 × the screen-size decode's", blurred > 0 && sharp > 2 * blurred, values["edgeStep"])
        press(29, "0", [], w)
        check("E4 back to fit keeps the full-resolution pixels", c.isFit && currentImage(v)?.width == 12000, currentImage(v)?.width)
        press(123, left, arrow, w)
        guard await displayed(v) else { return check("previous image displayed", false, nil) }
        press(124, right, arrow, w)
        check("E4 the full decode is never cached: back on the image, the screen-size decode", currentImage(v)?.width == image.width
              && v.loader.cache.object(forKey: v.currentURL! as NSURL)?.longEdge == longEdge, currentImage(v)?.width)
        check("E4 moving on gives the cache its whole budget back", v.loader.cache.totalCostLimit == v.loader.costLimit,
              v.loader.cache.totalCostLimit)
    }

    /// The largest step in brightness between horizontal neighbors in a window-coordinates region of a capture.
    private static func sharpness(_ shot: CGImage, _ region: NSRect, _ window: NSWindow) -> Double {
        let k = CGFloat(shot.width) / window.frame.width
        let rect = CGRect(x: region.minX * k, y: (window.frame.height - region.maxY) * k, width: region.width * k, height: region.height * k)
        guard let crop = shot.cropping(to: rect.integral) else { return -1 }
        let w = crop.width, h = crop.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        buffer.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                .draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var best = 0
        for y in 0..<h {
            var previous = -1
            for x in 0..<w {
                let i = (y * w + x) * 4
                let luma = (Int(buffer[i]) * 3 + Int(buffer[i + 1]) * 6 + Int(buffer[i + 2])) / 10
                if previous >= 0 { best = max(best, abs(luma - previous)) }
                previous = luma
            }
        }
        return Double(best) / 255
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
        sendKey(event)
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
        // A key from the event queue, as the owner's real keys arrive: the real-input filter drops it.
        NSApp.postEvent(self.key(53, "\u{1b}", [], v.window), atStart: false)
        await sleep(0.3)
        check("a queued (real-input) Esc is filtered out", v.window.isVisible && v.window.alphaValue == 1, Double(v.window.alphaValue))
        expectQuit(v, fade: true)
        sendKey(self.key(53, "\u{1b}", [], v.window))
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
        check("no open panel created", !NSApp.windows.contains { $0 is NSOpenPanel }, NSApp.windows.map { "\(type(of: $0))" })
        check("no modal session", NSApp.modalWindow == nil, NSApp.modalWindow.map { "\(type(of: $0))" })
    }

    /// B7: a folder argument (the nav fixtures) opens its first image in Finder order.
    private static func folderScenario() async {
        guard let v = await ready() else { return }
        await sleep(0.5)
        values["appkitOpenCalls"] = openCalls
        check("folder opens its first image (\(expectedNav.first ?? "?"))", v.currentURL?.lastPathComponent == expectedNav.first,
              v.currentURL?.path ?? "nil")
        check("index 0 of the folder's images", v.index == 0 && v.images.map(\.lastPathComponent) == expectedNav,
              "\(v.index) \(v.images.map(\.lastPathComponent))")
        check("first image displayed", await displayed(v), shownURL?.lastPathComponent)
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
        p.arguments = ["-g", "-a", Bundle.main.bundlePath, env["PICASSO_ODOC_FILE"] ?? ""]
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
        // A second open while visible follows the cursor to its screen: same window, no re-open fade.
        guard multi else { return }
        let first = NSScreen.screens[0]
        fakeMouse = NSPoint(x: first.frame.midX, y: first.frame.midY)
        app?.application(NSApp, open: [fixtures.appendingPathComponent("02-portrait.jpg")])
        check("second open moves the window to the cursor's screen", v.window.frame == first.frame && v.window.screen == first,
              NSStringFromRect(v.window.frame))
        check("second open displayed", await displayed(v) && v.currentURL?.lastPathComponent == "02-portrait.jpg",
              shownURL?.lastPathComponent)
        checkFit(v, "on the cursor's screen", CGSize(width: 3000, height: 4000))
        check("same single window, no fade", viewerWindowCount == 1 && v.window.alphaValue == 1, Double(v.window.alphaValue))
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

    /// Esc during the open fade (alpha < 1) still fades out and quits.
    private static func escEarlyScenario() async {
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

    /// B9a: clicks just inside the image edges keep the viewer, and so does a press inside released just outside
    /// (or the reverse), and so does a press on the image when a smaller image swaps in before the release;
    /// a click 2 pt outside (in the padding) closes it.
    private static func edgeClickScenario() async {
        guard let v = await ready() else { return }
        v.controls.hide() // the bar overlaps the image's bottom edge; this is about the canvas (hidden controls take no clicks)
        let f = v.canvas.imageLayer.frame
        let edges: [(inside: NSPoint, outside: NSPoint)] = [
            (NSPoint(x: f.minX + 1.5, y: f.midY), NSPoint(x: f.minX - 1.5, y: f.midY)),
            (NSPoint(x: f.maxX - 1.5, y: f.midY), NSPoint(x: f.maxX + 1.5, y: f.midY)),
            (NSPoint(x: f.midX, y: f.minY + 1.5), NSPoint(x: f.midX, y: f.minY - 1.5)),
            (NSPoint(x: f.midX, y: f.maxY - 1.5), NSPoint(x: f.midX, y: f.maxY + 1.5)),
        ]
        for e in edges { click(e.inside, v.window) }
        await sleep(0.4)
        check("clicks 1.5 pt inside every edge keep the viewer", v.window.alphaValue == 1, Double(v.window.alphaValue))
        // 3 pt apart: still a click (not a drag), so only the press-point test keeps these open.
        for e in edges { click(e.inside, v.window, to: e.outside) }
        await sleep(0.4)
        check("press inside, release just outside keeps the viewer", v.window.alphaValue == 1, Double(v.window.alphaValue))
        for e in edges { click(e.outside, v.window, to: e.inside) }
        await sleep(0.4)
        check("press just outside, release inside keeps the viewer", v.window.alphaValue == 1, Double(v.window.alphaValue))
        // A press on the image counts as on the image even if a smaller image is swapped in before the release.
        let p = NSPoint(x: f.minX + 20, y: f.midY)
        mouse(.leftMouseDown, p, v.window)
        guard await open("03-small.png", size: CGSize(width: 300, height: 200)) else { return }
        let s = v.canvas.imageLayer.frame
        check("swap during the press: the press point is now outside the image", !s.contains(p), NSStringFromRect(s))
        mouse(.leftMouseUp, p, v.window)
        await sleep(0.4)
        check("press on the image, swapped before the release, keeps the viewer", v.window.alphaValue == 1, Double(v.window.alphaValue))
        expectQuit(v, fade: true)
        click(NSPoint(x: s.minX - 2, y: s.midY), v.window)
        await sleep(2)
        check("click 2 pt outside the image closes", false, "still running")
    }

    /// Launched with `-backdropOpacity 0.1`: out-of-range values are clamped to 0.3...1.0.
    private static func opacityScenario() async {
        guard let v = await ready() else { return }
        let alpha = Double(v.backdrop.layer?.backgroundColor?.alpha ?? -1)
        check("backdrop alpha clamped to 0.3", abs(alpha - 0.3) < 0.001, alpha)
    }

    /// B1/B2: launched with nav/img1.jpg. Finder order, exclusions, a text file named .jpg, files outside the listing.
    private static func indexScenario() async {
        guard let v = await ready() else { return }
        let names = v.images.map(\.lastPathComponent)
        values["index"] = names
        let fixtureSet: Set = ["éclair.heic", "fake.jpg", "IMG_0003.JPG", "img1.jpg", "img2.jpg", "img10.jpg",
                               "Photo (2).png", "Photo (10).png", "Zebra.webp"]
        check("expectation = listing minus hidden/non-image/subfolder", Set(expectedNav) == fixtureSet, expectedNav)
        check("B1 order == FileManager listing sorted by localizedStandardCompare", names == expectedNav, names)
        let pos = { (name: String) in names.firstIndex(of: name) ?? -1 }
        check("B1 img1 < img2 < img10", pos("img1.jpg") >= 0 && pos("img1.jpg") < pos("img2.jpg") && pos("img2.jpg") < pos("img10.jpg"),
              "\(pos("img1.jpg")) \(pos("img2.jpg")) \(pos("img10.jpg"))")
        check("opened file is the current index", v.index == pos("img1.jpg") && v.currentURL?.lastPathComponent == "img1.jpg",
              "\(v.index) \(v.currentURL?.lastPathComponent ?? "nil")")
        for name in [".hidden.jpg", "flagged.jpg", "notes.txt", "sub", "inner.jpg"] {
            check("B2 \(name) excluded", !names.contains(name), nil)
        }
        check("B2 nothing from the subfolder", v.images.allSatisfy { $0.deletingLastPathComponent().path == nav.path },
              v.images.map(\.path))

        // fake.jpg (text): the can't-open message, and the keys keep working across it in both directions.
        let w = v.window, fake = pos("fake.jpg")
        check("fake.jpg is listed right after the first image", fake == 1, fake)
        press(115, home, .function, w)
        press(124, right, arrow, w)
        check("on fake.jpg", v.index == fake, v.index)
        let message = await wait(5) { shownURL == v.currentURL && !v.message.isHidden }
        check("B2 fake.jpg shows the can't-open message", message && v.message.stringValue.contains("fake.jpg")
              && v.canvas.imageLayer.contents == nil, v.message.stringValue)
        screenshot("index-fake")
        uncache(v.images[fake + 1])
        press(124, right, arrow, w)
        check("B2 → past fake.jpg moves on", v.index == fake + 1, v.index)
        check("B2 the can't-open message hides on moving on, before the next decode lands", v.message.isHidden && shownURL != v.currentURL,
              v.message.stringValue)
        check("B2 next image displayed, message hidden", await displayed(v) && v.message.isHidden, shownURL?.lastPathComponent)
        press(123, left, arrow, w)
        press(123, left, arrow, w)
        check("B2 ← back over fake.jpg reaches the first", v.index == 0, v.index)
        check("B2 first image displayed after fake.jpg", await displayed(v) && v.message.isHidden, shownURL?.lastPathComponent)

        // The top fixtures folder: its nav subfolder and hidden .stamp are not images to show.
        app?.application(NSApp, open: [fixtures.appendingPathComponent("01-landscape.jpg")])
        let top = v.images.map(\.lastPathComponent)
        check("B2 fixtures folder: the 11 images, no subfolder or hidden file", top.count == 11 && top.first == "01-landscape.jpg"
              && !top.contains("nav") && !top.contains(".stamp"), top)
        // A file the listing skips still opens, slotted in by name.
        app?.application(NSApp, open: [nav.appendingPathComponent(".hidden.jpg")])
        let withHidden = v.images.map(\.lastPathComponent)
        check("a hidden file opened directly is shown in its folder", v.currentURL?.lastPathComponent == ".hidden.jpg"
              && withHidden == (expectedNav + [".hidden.jpg"]).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
              && v.images[v.index] == v.currentURL, withHidden)
        check("hidden file displayed", await displayed(v), shownURL?.lastPathComponent)
        // A wrong-case path (case-insensitive volume) is the listed file, not a second entry for it.
        app?.application(NSApp, open: [nav.appendingPathComponent("IMG1.JPG")])
        check("wrong-case IMG1.JPG opens the listed img1.jpg, no duplicate", v.images.map(\.lastPathComponent) == expectedNav
              && v.currentURL?.lastPathComponent == "img1.jpg", "\(v.currentURL?.lastPathComponent ?? "nil") \(v.images.map(\.lastPathComponent))")
        check("img1.jpg displayed", await displayed(v), shownURL?.lastPathComponent)
        // A symlink to a folder (argv, open -a) is the folder: its resource values describe the link, not the target.
        app?.application(NSApp, open: [fixtures.deletingLastPathComponent().appendingPathComponent("nav-link", isDirectory: false)])
        check("symlink to the nav folder opens its first image", v.images.map(\.lastPathComponent) == expectedNav && v.index == 0
              && v.currentURL?.lastPathComponent == expectedNav.first, "\(v.currentURL?.path ?? "nil") \(v.images.map(\.lastPathComponent))")
        check("first image displayed via the symlink", await displayed(v), shownURL?.lastPathComponent)
    }

    /// B3: launched with the nav folder (index 0). Real key events into the window, including key repeats.
    private static func keysScenario() async {
        guard let v = await ready() else { return }
        let w = v.window, last = v.images.count - 1
        func expect(_ name: String, _ index: Int) { check(name, v.index == index, "index \(v.index), want \(index)") }
        check("nav folder has 9 images", v.images.count == 9, v.images.count)
        expect("starts at 0", 0)
        press(123, left, arrow, w); expect("← at the first stays at 0", 0)
        press(124, right, arrow, w); expect("→ from the first goes to 1", 1)
        press(49, " ", [], w); expect("Space = next", 2)
        press(123, left, arrow, w); expect("← = previous", 1)
        // Home/End keys and Fn+←/Fn+→ produce the same events: keyCode 115/119 with the function flag.
        press(119, end, .function, w); expect("End = last", last)
        let loads = loadCount
        press(124, right, arrow, w); expect("→ at the last stays at the last", last)
        press(49, " ", [], w); expect("Space at the last stays", last)
        check("staying at the last does not decode again", loadCount == loads, loadCount - loads)
        press(115, home, .function, w); expect("Home = 0", 0)
        press(124, right, arrow, w)
        for _ in 0..<3 { press(124, right, arrow, w, repeat: true) }
        expect("key-repeat → events navigate (1 + 3 repeats)", 4)
        for _ in 0..<2 { press(49, " ", [], w, repeat: true) }
        expect("key-repeat Space navigates", 6)
        // Holding ←: auto-repeat at ~30 Hz, decodes landing between repeats, flies back and stops at the start.
        // (Frames actually shown while holding is a performance measure, not checked here.)
        for _ in 0..<12 { press(123, left, arrow, w, repeat: true); await sleep(0.033) }
        expect("holding ← flies back and stops at 0", 0)
        press(119, end, .function, w)
        check("last image displayed after the run", await displayed(v), shownURL?.lastPathComponent)
        screenshot("keys")
    }

    /// B4: launched with the nav folder. Wheel notches, smooth-mouse scrolls and trackpad gestures through
    /// window.sendEvent (momentum tails straight to the canvas, see swipe()).
    private static func wheelScenario() async {
        guard let v = await ready() else { return }
        let w = v.window
        values["windowFrame"] = NSStringFromRect(w.frame)
        func expect(_ name: String, _ index: Int) { check(name, v.index == index, "index \(v.index), want \(index)") }
        // The synthesized events are what they claim to be.
        let probe = [scroll(0, -1, w), scroll(-10, 0, precise: true, phase: 2, inverted: true, w),
                     scroll(-10, 0, precise: true, momentum: 2, w)]
        check("synthesized: wheel notch is not precise, no phase", !probe[0].hasPreciseScrollingDeltas && probe[0].phase.isEmpty
              && probe[0].scrollingDeltaY == -1, "\(probe[0])")
        check("synthesized: trackpad event precise, phase .changed, inverted", probe[1].hasPreciseScrollingDeltas
              && probe[1].phase == .changed && probe[1].isDirectionInvertedFromDevice && probe[1].scrollingDeltaX == -10, "\(probe[1])")
        check("synthesized: momentum event", probe[2].phase.isEmpty && probe[2].momentumPhase == .changed, "\(probe[2])")

        // Wheel: down/right = next whatever the scrolling direction setting (natural inverts the deltas).
        func wheel(_ dx: Int32, _ dy: Int32, precise: Bool = false, inverted: Bool = false, command: Bool = false) {
            w.sendEvent(scroll(dx, dy, precise: precise, inverted: inverted, command: command, w))
            sentScrolls += 1
        }
        for _ in 0..<3 { wheel(0, -1) }
        expect("3 notches down → +3", 3)
        for _ in 0..<3 { wheel(0, 1) }
        expect("3 notches up → back to 0", 0)
        for _ in 0..<2 { wheel(0, 1, inverted: true) }
        expect("natural scrolling: 2 notches down → +2", 2)
        for _ in 0..<2 { wheel(0, -1, inverted: true) }
        expect("natural scrolling: 2 notches up → back to 0", 0)
        wheel(-1, 0); expect("notch right → next", 1)
        wheel(1, 0); expect("notch left → previous", 0)
        wheel(0, 1); expect("notch up at the first stays (no wrap)", 0)
        for _ in 0..<3 { wheel(0, -1, command: true) }
        expect("Cmd+wheel does not navigate", 0)

        // Trackpad: one image per gesture (momentum included), fingers moving left = next.
        swipe(-20, 0, inverted: false, v); expect("swipe fingers left → +1", 1)
        swipe(-20, 0, inverted: true, v); expect("swipe fingers left, natural scrolling → +1", 2)
        swipe(20, 0, inverted: true, v); expect("swipe fingers right, natural scrolling → -1", 1)
        swipe(20, 0, inverted: false, v); expect("swipe fingers right → -1", 0)
        swipe(20, 0, inverted: true, v); expect("swipe right at the first stays (no wrap)", 0)
        swipe(-20, 0, inverted: true, v); expect("swipe left → +1", 1)
        // Mid-folder, so a wrong step either way shows. Only the momentum guard stops these tails navigating.
        swipe(-5, 0, inverted: true, v); expect("short swipe left (30 pt) + 60 pt momentum does not navigate", 1)
        swipe(5, 0, inverted: false, v); expect("short swipe right (30 pt) + 60 pt momentum does not navigate", 1)
        swipe(-8, 30, inverted: true, v); expect("vertical-dominant swipe does not navigate", 1)
        swipe(-20, 0, inverted: true, command: true, v); expect("Cmd+swipe does not navigate", 1)
        swipe(-40, 0, steps: 20, inverted: true, v); expect("long swipe (840 pt + momentum) is still one image", 2)

        // Smooth-scrolling mice: precise deltas without phases. Like the wheel, one image per 50 pt, down/right = next.
        for _ in 0..<6 { wheel(0, -10, precise: true) }
        expect("smooth mouse: 60 pt down → next", 3)
        for _ in 0..<4 { wheel(0, -10, precise: true) }
        expect("smooth mouse: 40 pt more does not navigate yet", 3)
        for _ in 0..<2 { wheel(0, -10, precise: true) }
        expect("smooth mouse: 20 pt more does (one image per 50 pt)", 4)
        for _ in 0..<6 { wheel(0, 10, precise: true) }
        expect("smooth mouse: 60 pt up → previous", 3)
        for _ in 0..<4 { wheel(0, -10, precise: true) }
        for _ in 0..<6 { wheel(10, 0, precise: true) }
        expect("smooth mouse: 40 pt down then 60 pt left → previous (a new axis starts over)", 2)
        for _ in 0..<6 { wheel(-10, 0, precise: true) }
        expect("smooth mouse: 60 pt right → next", 3)

        // D8b: a gesture's unfinished swipe is not a head start for a smooth-mouse run.
        swipe(5, 0, inverted: false, v); expect("short swipe right (30 pt): no navigation", 3)
        for _ in 0..<3 { wheel(-10, 0, precise: true) }
        expect("D8b then 30 pt smooth-mouse right: no navigation (with the swipe's 30 pt it would)", 3)
        for _ in 0..<3 { wheel(-10, 0, precise: true) }
        expect("smooth mouse: 30 pt more → next", 4)
        // D8b: a gesture begun with ⌘ starts over too. After a swipe that navigated: ⌘ at the start, released mid-way.
        swipe(-20, 0, inverted: true, v); expect("swipe left → next", 5)
        func gesture(_ dx: Int32, phase: Int64, command: Bool) {
            w.sendEvent(scroll(dx, 0, precise: true, phase: phase, inverted: true, command: command, w))
            sentScrolls += 1
        }
        gesture(0, phase: 128, command: true) // mayBegin
        gesture(-20, phase: 1, command: true)
        gesture(-20, phase: 2, command: true)
        for _ in 0..<5 { gesture(-20, phase: 2, command: false) }
        gesture(0, phase: 4, command: false)
        expect("D8b a gesture begun with ⌘, ⌘ released mid-way, 100 pt left → next", 6)

        values["scrollEvents"] = "\(scrollEvents) received, \(sentScrolls) sent"
        check("every synthesized scroll event reached scrollWheel (momentum included)",
              scrollEvents == sentScrolls, values["scrollEvents"])
        check("displayed after scrolling", await displayed(v), shownURL?.lastPathComponent)
    }

    /// B6: launched with 01-landscape.jpg. Rapid navigation never shows a stale decode; the last one wins.
    private static func staleScenario() async {
        guard let v = await ready() else { return }
        let w = v.window, huge = v.images.firstIndex { $0.lastPathComponent == "10-huge.jpg" } ?? -1
        press(119, end, .function, w)
        check("End: 11-primary.heic displayed, 10-huge.jpg just before it", await displayed(v) && huge == v.index - 1,
              "\(v.index) \(huge)")
        await sleep(0.4) // the next press is a single step, not flying
        uncache(v.images[huge]) // else its preload has it ready
        staleShown = []
        var callbacks = decodeCallbacks, shows = shownCount, dropped = staleDropped
        // 5 × ←: the first starts the slow 12000×8000 decode, the other 4 fly on while it runs.
        press(123, left, arrow, w)
        check("← to 10-huge.jpg: its decode is in flight", v.currentURL == v.images[huge] && v.displayedURL != v.currentURL,
              v.displayedURL?.lastPathComponent)
        await sleep(0.02)
        for _ in 0..<4 { press(123, left, arrow, w) }
        check("5 ← presses reach index 5", v.index == 5, v.index)
        check("burst: the last index's image is displayed", await displayed(v), shownURL?.lastPathComponent)
        await sleep(0.5) // nothing late may replace it
        check("burst: still the last index's image", shownURL == v.images[5] && v.canvas.imageSize == orientedSize(v.images[5]),
              "\(shownURL?.lastPathComponent ?? "nil") \(v.canvas.imageSize)")
        values["burstDecodes"] = decodeCallbacks - callbacks
        values["burstShows"] = shownCount - shows
        check("burst: the huge decode arrived stale and was dropped", staleDropped > dropped && shownURL != v.images[huge],
              "\(staleDropped - dropped) dropped")
        // Spaced presses, flying: cached images show at once, the others' fast thumbnails; nothing late wins.
        callbacks = decodeCallbacks; shows = shownCount
        for _ in 0..<5 { press(124, right, arrow, w); await sleep(0.004) }
        check("spaced: at the last index again", v.index == 10, v.index)
        check("spaced: its image is displayed", await displayed(v), shownURL?.lastPathComponent)
        await sleep(0.5)
        check("spaced: still the last index's image", shownURL == v.images[10] && v.canvas.imageSize == orientedSize(v.images[10]),
              "\(shownURL?.lastPathComponent ?? "nil") \(v.canvas.imageSize)")
        values["spacedDecodes"] = decodeCallbacks - callbacks
        values["spacedShows"] = shownCount - shows
        check("no stale image was ever put on screen", staleShown.isEmpty, staleShown)
    }

    /// B5: launched with 01-landscape.jpg. Finder opens while visible replace the folder in the same window.
    private static func secondOpenScenario() async {
        guard let v = await ready() else { return }
        await sleep(0.3)
        let w = v.window
        check("starts in the fixtures folder", v.images.count == 11 && v.index == 0, "\(v.images.count) \(v.index)")
        app?.application(NSApp, open: [nav.appendingPathComponent("img2.jpg")])
        var minAlpha = 1.0, sawOpenAnim = false
        let ok = await wait(5) {
            minAlpha = min(minAlpha, Double(w.alphaValue))
            if v.canvas.imageLayer.animation(forKey: "open") != nil { sawOpenAnim = true }
            return shownURL?.lastPathComponent == "img2.jpg"
        }
        check("second open displayed img2.jpg", ok, shownURL?.lastPathComponent)
        check("same controller and window", app?.viewer === v && v.window === w, nil)
        check("window count still 1", viewerWindowCount == 1, viewerWindowCount)
        check("folder replaced by nav, at img2.jpg", v.images.map(\.lastPathComponent) == expectedNav
              && v.images[v.index].lastPathComponent == "img2.jpg", "\(v.index) \(v.images.map(\.lastPathComponent))")
        check("alpha stayed 1 during the swap", minAlpha == 1, minAlpha)
        check("no open zoom on the swap", !sawOpenAnim, nil)
        // A folder replaces it too, at its first image; navigation continues there.
        app?.application(NSApp, open: [fixtures])
        check("folder open: fixtures folder at index 0", v.images.count == 11 && v.index == 0
              && v.currentURL?.lastPathComponent == "01-landscape.jpg", "\(v.images.count) \(v.index)")
        press(124, right, arrow, w)
        check("→ continues in the new folder", v.currentURL?.lastPathComponent == "02-portrait.jpg", v.currentURL?.lastPathComponent)
        check("displayed", await displayed(v), shownURL?.lastPathComponent)
        // Re-opening the file already shown decodes it again (it may have been rewritten or half-saved before).
        let loads = loadCount, callbacks = decodeCallbacks
        app?.application(NSApp, open: [fixtures.appendingPathComponent("02-portrait.jpg")])
        let decoded = await wait(5) { decodeCallbacks > callbacks }
        check("re-opening the shown file decodes it again", loadCount == loads + 1 && decoded,
              "\(loadCount - loads) loads, \(decodeCallbacks - callbacks) decodes")
        check("re-opened file displayed", await displayed(v) && v.currentURL?.lastPathComponent == "02-portrait.jpg",
              shownURL?.lastPathComponent)
        check("still one window, still visible", viewerWindowCount == 1 && w.isVisible && w.alphaValue == 1, viewerWindowCount)
    }

    // MARK: Step 3: controls

    /// C1: launched with 01-landscape.jpg. + = - zoom ×1.25 about the center, clamped to [min, max]; 0 fits, 1 is 100%.
    private static func zoomKeysScenario() async {
        guard let v = await ready() else { return }
        let c = v.canvas, w = v.window, fit = c.fitScale
        values["fitScale"] = Double(fit)
        values["minZoom"] = Double(c.minZoom)
        check("starts at fit 1000/3000", c.isFit && abs(fit - 1000.0 / 3000) < 1e-9, c.scale)
        check("min zoom = fit / 2, max zoom 16", abs(c.minZoom - fit / 2) < 1e-12 && ImageCanvasView.maxZoom == 16, c.minZoom)
        func step(_ name: String, _ code: UInt16, _ chars: String, _ mods: NSEvent.ModifierFlags, _ ratio: CGFloat) {
            let before = c.scale
            press(code, chars, mods, w)
            check("\(name): ×\(ratio)", abs(c.scale / before - ratio) < 1e-9, c.scale / before)
            let f = c.imageLayer.frame
            check("\(name): about the center", abs(f.midX - c.bounds.midX) < 0.01 && abs(f.midY - c.bounds.midY) < 0.01, NSStringFromRect(f))
        }
        step("+", 24, "+", .shift, 1.25)
        step("=", 24, "=", [], 1.25)
        step("keypad +", 69, "+", .numericPad, 1.25)
        step("-", 27, "-", [], 0.8)
        step("keypad -", 78, "-", .numericPad, 0.8)
        for _ in 0..<30 { press(24, "+", .shift, w, repeat: true) }
        check("held + stops at 16×", c.scale == 16, c.scale)
        check("16×: 64000 pt wide", abs(c.imageLayer.frame.width - 64000) < 0.01, c.imageLayer.frame.width)
        for _ in 0..<40 { press(27, "-", [], w, repeat: true) }
        check("held - stops at the min zoom", c.scale == c.minZoom, "\(c.scale) vs \(c.minZoom)")
        press(29, "0", [], w)
        check("0 → fit", c.isFit && c.scale == fit, c.scale)
        checkFit(v, "after 0", CGSize(width: 4000, height: 3000))
        press(18, "1", [], w)
        let f = c.imageLayer.frame
        check("1 → 100%", c.scale == 1 && f.size == CGSize(width: 4000, height: 3000), NSStringFromRect(f))
        check("1 → centered", abs(f.midX - c.bounds.midX) <= 0.5 && abs(f.midY - c.bounds.midY) <= 0.5, NSStringFromRect(f))
        press(29, "0", [], w)
        check("0 from 100% → fit", c.isFit, c.scale)

        // + then - lands exactly on fit, so the fit toggle offers 100% and a swipe navigates instead of panning.
        guard await open("06-photo.webp", size: CGSize(width: 1600, height: 1200)) else { return }
        let fit6 = c.fitScale
        check("06-photo.webp: (fit × 1.25) × 0.8 is not exactly fit (the check discriminates)", fit6 * 1.25 * (1 / 1.25) != fit6, fit6)
        press(24, "=", [], w)
        press(27, "-", [], w)
        check("06-photo.webp: + then - is exactly fit", c.isFit && c.scale == fit6, "\(c.scale) vs \(fit6)")
        check("and the fit toggle offers actual size", v.controls.fit.toolTip == "Actual Size", v.controls.fit.toolTip)
        let i = v.index
        swipe(-20, 0, inverted: true, v)
        check("a swipe after + then - navigates", v.index == i + 1, v.index)
        // 07-photo.tiff (1500×1000) fits at 100%. A pinch ending just above that leaves it inside the view: nothing to
        // pan, so a swipe still navigates.
        guard await displayed(v) else { return check("07-photo.tiff displayed", false, shownURL?.lastPathComponent) }
        pinch(0.01, at: NSPoint(x: c.bounds.midX, y: c.bounds.midY), w)
        check("pinched just above fit, the image still inside the view", c.scale > c.fitScale && !c.canPan
              && c.bounds.contains(c.imageLayer.frame), "\(c.scale) \(NSStringFromRect(c.imageLayer.frame))")
        swipe(-20, 0, inverted: true, v)
        check("a swipe then navigates", v.index == i + 2, v.index)
    }

    /// Measures how far the image point under `p` drifts across `action`, in view points.
    private static func drift(_ c: ImageCanvasView, at p: NSPoint, _ action: () -> Void) -> CGFloat {
        let f0 = c.imageLayer.frame
        let u = CGPoint(x: (p.x - f0.minX) / f0.width, y: (p.y - f0.minY) / f0.height)
        action()
        let f1 = c.imageLayer.frame
        return hypot(f1.minX + u.x * f1.width - p.x, f1.minY + u.y * f1.height - p.y)
    }

    /// C2: launched with 01-landscape.jpg. Cmd+wheel, Cmd+trackpad scroll and the pinch path zoom at an off-center
    /// cursor, keeping the image point under it fixed. At 100% the image overflows the view on both axes, so the
    /// pan limits (which center an axis that fits) don't take part.
    private static func zoomPointScenario() async {
        guard let v = await ready() else { return }
        let c = v.canvas, w = v.window
        press(18, "1", [], w)
        let p = NSPoint(x: c.bounds.width * 0.3, y: c.bounds.height * 0.35)
        values["cursor"] = NSStringFromPoint(p)
        func measure(_ name: String, ratio: CGFloat, _ action: () -> Void) {
            let before = c.scale
            let d = drift(c, at: p, action)
            values["\(name) drift"] = Double(d)
            check("\(name): ×\(ratio)", abs(c.scale / before - ratio) < 1e-6, c.scale / before)
            check("\(name): image point under the cursor stays within 1 pt", d <= 1, d)
            check("\(name): image still overflows the view", c.imageLayer.frame.contains(c.bounds), NSStringFromRect(c.imageLayer.frame))
        }
        measure("Cmd+wheel up", ratio: 1.25) { w.sendEvent(scroll(0, 1, command: true, at: p, w)) }
        measure("Cmd+wheel down", ratio: 0.8) { w.sendEvent(scroll(0, -1, command: true, at: p, w)) }
        measure("Cmd+trackpad scroll", ratio: exp(0.1)) {
            w.sendEvent(scroll(0, -20, precise: true, phase: 2, inverted: true, command: true, at: p, w))
        }
        measure("pinch +0.3", ratio: 1.3) { pinch(0.3, at: p, w) }
        measure("pinch -0.2", ratio: 0.8) { pinch(-0.2, at: p, w) }
        // Over the bar too: the controls get the gesture first and it reaches the zoom through the controller.
        let o = v.controls, overBar = center(o.bar)
        move(overBar, v)
        check("the pinch point is on the bar", o.hitTest(overBar)?.isDescendant(of: o.bar) == true, nil)
        let before = c.scale
        let d = drift(c, at: overBar) { pinch(0.25, at: overBar, w) }
        check("pinch over the bar zooms ×1.25 at the fingers", abs(c.scale / before - 1.25) < 1e-6 && d <= 1, "\(c.scale / before) \(d) pt")
        // The same zoom about the view center would have moved that point by (k - 1) × its distance from the center.
        let wouldBe = hypot(p.x - c.bounds.midX, p.y - c.bounds.midY) * 0.25
        check("a center-anchored zoom would drift > 50 pt here (the check discriminates)", wouldBe > 50, wouldBe)
        check("Cmd+wheel did not navigate", v.index == 0, v.index)
    }

    /// Settings zoom mode, launched with `-scrollWheelAction zoom` and 01-landscape.jpg: a plain wheel zooms at the cursor
    /// instead of navigating; trackpad swipes still navigate at fit.
    private static func zoomModeScenario() async {
        guard let v = await ready() else { return }
        let c = v.canvas, w = v.window
        check("setting read", Settings.scrollWheelAction == "zoom", Settings.scrollWheelAction)
        let fit = c.scale
        w.sendEvent(scroll(0, 1, w))
        check("wheel up zooms in ×1.25", abs(c.scale / fit - 1.25) < 1e-9, c.scale / fit)
        w.sendEvent(scroll(0, -1, w))
        check("wheel down zooms back out", abs(c.scale - fit) < 1e-9, c.scale)
        check("plain wheel does not navigate", v.index == 0, v.index)
        press(18, "1", [], w)
        let p = NSPoint(x: c.bounds.width * 0.7, y: c.bounds.height * 0.6)
        let d = drift(c, at: p) { w.sendEvent(scroll(0, 1, at: p, w)) }
        values["drift"] = Double(d)
        check("wheel zoom at an off-center cursor: point stays within 1 pt", d <= 1 && c.scale == 1.25, "\(d) pt, scale \(c.scale)")
        let d2 = drift(c, at: p) { w.sendEvent(scroll(0, 1, precise: true, at: p, w)) }
        check("smooth-mouse scroll zooms too, at the cursor", c.scale > 1.25 && d2 <= 1, "\(c.scale) \(d2)")
        w.sendEvent(scroll(0, 1, command: true, at: p, w))
        check("Cmd+wheel still zooms", c.scale > 1.25 * 1.2, c.scale)
        press(29, "0", [], w)
        swipe(-20, 0, inverted: true, v)
        check("trackpad swipe still navigates", v.index == 1, v.index)
    }

    /// C3: launched with 01-landscape.jpg. Drag pans by the drag delta when the image exceeds the view, never past its
    /// edges; at fit a drag does nothing and doesn't close; two-finger scrolling pans when zoomed; an axis that
    /// fits stays centered.
    private static func panScenario() async {
        guard let v = await ready() else { return }
        let c = v.canvas, w = v.window, b = c.bounds
        let mid = NSPoint(x: b.midX, y: b.midY)
        let atFit = c.imageLayer.frame
        drag(mid, NSPoint(x: mid.x + 200, y: mid.y + 120), w)
        check("at fit: dragging the image moves nothing", c.imageLayer.frame == atFit, NSStringFromRect(c.imageLayer.frame))
        drag(NSPoint(x: 100, y: 300), NSPoint(x: 260, y: 500), w)
        await sleep(0.3)
        check("at fit: dragging (image, backdrop) does not close", w.isVisible && w.alphaValue == 1, Double(w.alphaValue))

        press(18, "1", [], w)
        var f0 = c.imageLayer.frame
        drag(mid, NSPoint(x: mid.x + 150, y: mid.y - 80), w)
        var f = c.imageLayer.frame
        check("100%: drag (150, -80) moves the image by (150, -80)",
              abs(f.minX - f0.minX - 150) < 0.01 && abs(f.minY - f0.minY + 80) < 0.01 && f.size == f0.size,
              "moved \(f.minX - f0.minX), \(f.minY - f0.minY)")
        drag(mid, NSPoint(x: mid.x + 5000, y: mid.y + 5000), w)
        f = c.imageLayer.frame
        check("dragged far right/up: left and bottom edges stop at the view's", f.minX == 0 && f.minY == 0, NSStringFromRect(f))
        drag(mid, NSPoint(x: mid.x - 10000, y: mid.y - 10000), w)
        f = c.imageLayer.frame
        check("dragged far left/down: right and top edges stop at the view's", f.maxX == b.width && f.maxY == b.height, NSStringFromRect(f))
        check("drags while zoomed do not close", w.isVisible && w.alphaValue == 1, nil)

        // Trackpad: scrolling deltas follow the content (natural scrolling: the fingers), momentum included.
        press(18, "1", [], w)
        f0 = c.imageLayer.frame
        let index = v.index
        w.sendEvent(scroll(0, 0, precise: true, phase: 1, inverted: true, w))
        for _ in 0..<3 { w.sendEvent(scroll(30, -20, precise: true, phase: 2, inverted: true, w)) }
        w.sendEvent(scroll(0, 0, precise: true, phase: 4, inverted: true, w))
        f = c.imageLayer.frame
        check("two-finger scroll pans by the deltas (90, -60) → image (+90, +60)",
              abs(f.minX - f0.minX - 90) < 0.01 && abs(f.minY - f0.minY - 60) < 0.01, "\(f.minX - f0.minX), \(f.minY - f0.minY)")
        c.scrollWheel(with: scroll(10, 0, precise: true, momentum: 2, inverted: true, w)) // momentum, as swipe() sends it
        check("momentum keeps panning", abs(c.imageLayer.frame.minX - f.minX - 10) < 0.01, c.imageLayer.frame.minX - f.minX)
        check("panning does not navigate", v.index == index, v.index)

        // 3000×4000 at 1.25³ × fit: narrower than the view, taller than it.
        guard await open("02-portrait.jpg", size: CGSize(width: 3000, height: 4000)) else { return }
        for _ in 0..<3 { press(24, "=", [], w) }
        f0 = c.imageLayer.frame
        check("portrait zoomed: fits horizontally, overflows vertically", f0.width < b.width && f0.height > b.height, NSStringFromRect(f0))
        drag(mid, NSPoint(x: mid.x + 300, y: mid.y + 200), w)
        f = c.imageLayer.frame
        check("the axis that fits stays centered, the other pans", abs(f.midX - b.midX) < 0.01 && abs(f.minY - f0.minY - 200) < 0.01,
              "midX \(f.midX), moved y \(f.minY - f0.minY)")
        // A press on the backdrop beside it that pans 300 pt and comes back to where it started is a drag, not a click.
        // (Watched at the canvas's close callback: it decides, whether or not a fade can run.)
        let side = NSPoint(x: f.minX / 2, y: mid.y), close = c.onBackdropClick
        var backdropClicks = 0
        c.onBackdropClick = { backdropClicks += 1 }
        mouse(.leftMouseDown, side, w)
        mouse(.leftMouseDragged, NSPoint(x: side.x, y: side.y - 300), w)
        let panned = c.imageLayer.frame.minY - f.minY
        mouse(.leftMouseDragged, side, w)
        mouse(.leftMouseUp, side, w)
        check("backdrop press panned 300 pt away and back, released where it started: not a click",
              abs(panned + 300) < 0.01 && backdropClicks == 0, "panned \(panned), backdrop clicks \(backdropClicks)")
        click(side, w)
        check("a plain click there is a backdrop click (the check discriminates)", backdropClicks == 1, backdropClicks)
        c.onBackdropClick = close
    }

    /// C4: launched with 01-landscape.jpg. R / Shift+R rotate the view (portrait, refit), the rotation is remembered
    /// per file while navigating, nothing is persisted, and a relaunch starts upright. (test.sh proves no file changes.)
    private static func rotateScenario() async {
        guard let v = await ready() else { return }
        let c = v.canvas, w = v.window
        if env["PICASSO_RELAUNCHED"] == "1" {
            check("relaunched: upright, landscape", c.rotation == 0 && c.imageLayer.frame.width > c.imageLayer.frame.height,
                  "\(c.rotation) \(NSStringFromRect(c.imageLayer.frame))")
            return
        }
        v.controls.hide() // the bar would cover the bottom-edge color probe
        let domain = Bundle.main.bundleIdentifier!
        let defaultsBefore = UserDefaults.standard.persistentDomain(forName: domain) as NSDictionary?
        check("starts upright", c.rotation == 0, c.rotation)
        func checkTurn(_ name: String, _ degrees: Int, redAt: String) async {
            let f = c.imageLayer.frame, b = c.bounds
            let portrait = degrees % 180 != 0
            check("\(name): rotation \(degrees)", c.rotation == degrees, c.rotation)
            check("\(name): displayed \(portrait ? "portrait" : "landscape")", portrait ? f.height > f.width : f.width > f.height,
                  NSStringFromRect(f))
            let expectedFit = portrait ? 1000.0 / 4000 : 1000.0 / 3000
            check("\(name): refit to \(expectedFit), centered", c.isFit && abs(c.scale - expectedFit) < 1e-9
                  && abs(f.midX - b.midX) < 0.01 && abs(f.midY - b.midY) < 0.01, "\(c.scale) \(NSStringFromRect(f))")
            await sleep(0.4) // the turn animates
            guard let shot = screenshot("rotate-\(degrees)") else { return }
            // The red band marks the image's top: after a clockwise quarter turn it is on the right.
            let probes = ["right": NSPoint(x: f.maxX - 12, y: f.midY), "left": NSPoint(x: f.minX + 12, y: f.midY),
                          "top": NSPoint(x: f.midX, y: f.maxY - 12), "bottom": NSPoint(x: f.midX, y: f.minY + 12)]
            let colors = probes.mapValues { pixel(shot, at: $0, w) }
            let red = colors[redAt]!, opposite = colors[["right": "left", "left": "right", "top": "bottom", "bottom": "top"][redAt]!]!
            check("\(name): capture shows the red (top) band on the \(redAt)", red.r > 0.8 && red.g < 0.25 && red.b < 0.25, red)
            check("\(name): and the blue (bottom) band opposite", opposite.b > 0.8 && opposite.r < 0.25, opposite)
        }
        press(15, "r", [], w)
        await checkTurn("R", 90, redAt: "right")
        press(15, "R", .shift, w)
        await checkTurn("Shift+R back", 0, redAt: "top")
        press(15, "R", .shift, w)
        await checkTurn("Shift+R", 270, redAt: "left")
        for _ in 0..<4 { press(15, "r", [], w) }
        check("4 × R is a full turn", c.rotation == 270, c.rotation)
        press(15, "r", [], w)
        press(15, "r", [], w)
        check("R from 270 → 0 → 90", c.rotation == 90, c.rotation)

        press(124, right, arrow, w)
        check("next image displayed", await displayed(v), shownURL?.lastPathComponent)
        check("the next image starts upright (rotation is per file)", c.rotation == 0 && c.imageLayer.frame.height > c.imageLayer.frame.width,
              "\(c.rotation) \(NSStringFromRect(c.imageLayer.frame))")
        press(123, left, arrow, w)
        check("back: first image displayed", await displayed(v), shownURL?.lastPathComponent)
        check("back: its rotation is remembered (90, portrait)", c.rotation == 90 && c.imageLayer.frame.height > c.imageLayer.frame.width,
              "\(c.rotation) \(NSStringFromRect(c.imageLayer.frame))")
        // Shift+R while the next decode is in flight turns the image being opened, not the one still on screen.
        await sleep(0.3) // landed (its preloads done), so → is a single step: flying would show the strip's thumbnail at once
        uncache(v.images[v.index + 1])
        press(124, right, arrow, w)
        let inFlight = v.displayedURL != v.currentURL
        press(15, "R", .shift, w)
        check("Shift+R during the next decode leaves the image on screen alone", inFlight && c.rotation == 90,
              "in flight \(inFlight), rotation \(c.rotation)")
        check("next image displayed again", await displayed(v), shownURL?.lastPathComponent)
        check("it lands turned (270, landscape)", c.rotation == 270 && c.imageLayer.frame.width > c.imageLayer.frame.height,
              "\(c.rotation) \(NSStringFromRect(c.imageLayer.frame))")
        press(123, left, arrow, w)
        check("back: the first image is still at 90", await displayed(v) && c.rotation == 90, c.rotation)

        let defaultsAfter = UserDefaults.standard.persistentDomain(forName: domain) as NSDictionary?
        check("nothing saved to preferences", defaultsBefore == defaultsAfter, defaultsAfter)
        // Relaunch with the same file while this run still has it rotated.
        let childOut = outDir.appendingPathComponent("rotate-relaunch")
        try? FileManager.default.removeItem(at: childOut)
        let child = Process()
        child.executableURL = Bundle.main.executableURL
        child.arguments = [CommandLine.arguments[1]]
        child.environment = env.merging(["PICASSO_RELAUNCHED": "1", "PICASSO_SELFTEST_OUT": childOut.path]) { $1 }
        try? child.run()
        let exited = await wait(15) { !child.isRunning }
        if !exited { child.terminate() } // never leave its full-screen window over the display
        let result = (try? Data(contentsOf: childOut.appendingPathComponent("rotate.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        check("relaunch starts upright (child run passed)", exited && child.terminationStatus == 0 && result?["pass"] as? Bool == true,
              "exited \(exited), status \(exited ? child.terminationStatus : -1), \(result?["checks"] ?? "no result")")
    }

    /// C5: launched with 01-landscape.jpg. Double-click on the image toggles fit ⇄ 100% at the click point; single
    /// clicks on the bar, the pill and a button don't close; a single backdrop click still does.
    private static func doubleClickScenario() async {
        guard let v = await ready() else { return }
        let c = v.canvas, w = v.window, o = v.controls
        let f = c.imageLayer.frame, fit = c.scale
        let p = NSPoint(x: f.midX + 200, y: f.midY + 100)
        let d = drift(c, at: p) { doubleClick(p, w) }
        values["doubleClickDrift"] = Double(d)
        check("double-click at fit → 100%", c.scale == 1, c.scale)
        check("100% at the click point (the image point under it stays within 1 pt)", d <= 1, d)
        await sleep(0.4)
        check("double-click does not close", w.isVisible && w.alphaValue == 1, Double(w.alphaValue))
        doubleClick(p, w)
        check("double-click again → fit, centered", c.scale == fit && c.imageLayer.frame == f, NSStringFromRect(c.imageLayer.frame))
        // Double-clicking the backdrop is not a zoom (its first click closes, so only the second press is sent here).
        mouse(.leftMouseDown, NSPoint(x: 20, y: 20), w, clickCount: 2)
        mouse(.leftMouseUp, NSPoint(x: 20, y: 20), w, clickCount: 2)
        check("second click of a backdrop double-click: no zoom, no close", c.scale == fit && w.alphaValue == 1, c.scale)

        move(center(o.bar), v)
        click(NSPoint(x: o.bar.frame.minX + 4, y: o.bar.frame.midY), w) // bar background
        click(center(o.pill), w)
        postClick(center(o.rotateRight), w)
        await sleep(0.5)
        check("the button click worked", c.rotation == 90, c.rotation)
        check("clicks on the bar, the pill and a button do not close", w.isVisible && w.alphaValue == 1, Double(w.alphaValue))
        expectQuit(v, fade: true)
        click(NSPoint(x: 20, y: 20), w)
        await sleep(2)
        check("single backdrop click closes", false, "still running")
    }

    /// C6: launched with 01-landscape.jpg (11 images). Every bar button and edge arrow works when clicked at its
    /// on-screen location through the event queue; the slider drives the zoom and follows it.
    private static func barScenario() async {
        guard let v = await ready() else { return }
        let c = v.canvas, w = v.window, o = v.controls
        let buttons = ["previous": o.previous, "next": o.next, "rotateLeft": o.rotateLeft, "rotateRight": o.rotateRight,
                       "fit": o.fit, "play": o.play, "leftArrow": o.leftArrow, "rightArrow": o.rightArrow]
        check("every button has its SF Symbol", buttons.values.allSatisfy { $0.image?.isTemplate == true },
              buttons.filter { $0.value.image == nil }.keys.sorted())
        check("no button or the slider takes keyboard focus", buttons.values.allSatisfy(\.refusesFirstResponder)
              && o.zoomSlider.refusesFirstResponder, nil)
        func tap(_ view: NSView) async {
            move(center(view), v) // the pointer gets there first, which also keeps the controls up
            postClick(center(view), w)
            await sleep(0.25)
        }
        check("previous disabled at the first image", !o.previous.isEnabled && o.next.isEnabled, nil)
        await tap(o.previous)
        check("previous at the first image: stays", v.index == 0, v.index)
        await tap(o.next)
        check("next → 1", v.index == 1, v.index)
        await tap(o.previous)
        check("previous → 0", v.index == 0, v.index)
        check("first image displayed", await displayed(v), shownURL?.lastPathComponent)

        check("fit button at fit offers actual size, enabled", o.fit.toolTip == "Actual Size" && o.fit.isEnabled, o.fit.toolTip)
        let fitIcon = o.fit.image
        await tap(o.fit)
        check("fit button → 100%", c.scale == 1, c.scale)
        check("its icon and tip switch to fit", o.fit.toolTip == "Fit to Screen" && o.fit.image !== fitIcon, o.fit.toolTip)
        await tap(o.fit)
        check("fit button → fit", c.isFit && o.fit.toolTip == "Actual Size", c.scale)

        await tap(o.rotateRight)
        check("rotate right → 90", c.rotation == 90, c.rotation)
        await tap(o.rotateLeft)
        await tap(o.rotateLeft)
        check("rotate left ×2 → 270", c.rotation == 270, c.rotation)
        await tap(o.rotateRight)
        check("rotate right → 0", c.rotation == 0, c.rotation)

        await tap(o.play)
        check("play starts the slideshow, icon becomes pause", v.slideshow != nil && o.play.toolTip == "Pause Slideshow", o.play.toolTip)
        await tap(o.play)
        check("pause stops it, icon becomes play", v.slideshow == nil && o.play.toolTip == "Play Slideshow", o.play.toolTip)

        // Slider: clicking 80% along the track zooms there (log scale); zooming moves the knob.
        // Not covered: dragging the knob. NSSlider's knob tracking reads global pointer state (pressedMouseButtons,
        // the real cursor), not only the synthesized events, so a synthesized knob drag doesn't track reliably.
        let s = o.zoomSlider, track = s.convert(s.bounds, to: nil)
        move(center(s), v)
        postClick(NSPoint(x: track.minX + track.width * 0.8, y: track.midY), w)
        await sleep(0.25)
        values["sliderAfterClick"] = s.doubleValue
        let expected = c.minZoom * pow(ImageCanvasView.maxZoom / c.minZoom, s.doubleValue)
        check("slider click moved it to ~0.8", abs(s.doubleValue - 0.8) < 0.08, s.doubleValue)
        check("slider sets the zoom (log between min and max)", abs(c.scale - expected) / expected < 1e-9, "\(c.scale) vs \(expected)")
        press(29, "0", [], w)
        check("0: the slider follows to the fit position", abs(s.doubleValue - c.zoomPosition) < 1e-9
              && abs(c.zoomPosition - log(c.fitScale / c.minZoom) / log(16 / c.minZoom)) < 1e-9, "\(s.doubleValue) \(c.zoomPosition)")
        let atFit = s.doubleValue
        press(24, "=", [], w)
        check("+: the slider moves up with the zoom", s.doubleValue > atFit && abs(s.doubleValue - c.zoomPosition) < 1e-9, s.doubleValue)
        press(29, "0", [], w)

        // Edge arrows appear near their edge; with no image that way they stay up, dimmed, and absorb the click.
        let b = c.bounds
        move(NSPoint(x: 40, y: b.midY), v)
        check("left edge at the first image: left arrow shown, disabled", o.leftCircle.alphaValue == 1 && !o.leftArrow.isEnabled,
              "\(o.leftCircle.alphaValue) \(o.leftArrow.isEnabled)")
        await sleep(0.35)
        await tap(o.leftArrow)
        check("clicking the disabled arrow: no navigation, no close", v.index == 0 && w.isVisible && w.alphaValue == 1, v.index)
        move(NSPoint(x: b.width - 40, y: b.midY), v)
        check("right edge: right arrow", o.rightCircle.alphaValue == 1, Double(o.rightCircle.alphaValue))
        await sleep(0.35)
        await tap(o.rightArrow)
        check("right arrow → 1", v.index == 1, v.index)
        move(NSPoint(x: 40, y: b.midY), v)
        await sleep(0.35)
        check("left edge: left arrow", o.leftCircle.alphaValue == 1, Double(o.leftCircle.alphaValue))
        await tap(o.leftArrow)
        check("left arrow → 0", v.index == 0, v.index)
        check("back at the first image the left arrow dims in place", o.leftCircle.alphaValue == 1 && !o.leftArrow.isEnabled
              && o.leftArrow.alphaValue < 0.5, "\(o.leftCircle.alphaValue) \(o.leftArrow.alphaValue)")
        check("no control click closed the viewer", w.isVisible && w.alphaValue == 1, nil)

        // D8a: for a 300×200 image fit is 100%, so the toggle has nothing to switch to until zoomed in.
        guard await open("03-small.png", size: CGSize(width: 300, height: 200)) else { return }
        let small = c.imageLayer.frame
        check("D8a 300x200 at fit == 100%: the fit button is disabled", c.fitScale == 1 && c.isFit && !o.fit.isEnabled,
              "\(c.fitScale) \(o.fit.isEnabled)")
        await tap(o.fit)
        doubleClick(NSPoint(x: small.minX + 30, y: small.maxY - 20), w)
        await sleep(0.3)
        check("D8a clicking it, and double-clicking the image off-center, change nothing", c.scale == 1 && c.imageLayer.frame == small
              && w.alphaValue == 1, "\(c.scale) \(NSStringFromRect(c.imageLayer.frame))")
        press(24, "=", [], w)
        check("zoomed in: enabled, offers fit", o.fit.isEnabled && o.fit.toolTip == "Fit to Screen", o.fit.toolTip)
        await tap(o.fit)
        check("its click fits again, and it is disabled again", c.isFit && c.scale == 1 && !o.fit.isEnabled, c.scale)
    }

    /// C7: launched with the nav folder (9 images). The slideshow advances every interval, a manual step restarts the
    /// countdown, it loops from the last image to the first, pause stops it, and Esc still closes.
    private static func slideshowScenario() async {
        guard let v = await ready() else { return }
        let w = v.window, interval = 0.4
        check("default interval 3 s", v.slideshowInterval == 3, v.slideshowInterval)
        v.slideshowInterval = interval
        /// Seconds until the index next changes (nil: not within 3 s).
        func nextChange() async -> Double? {
            let i = v.index, start = now
            return await wait(3) { v.index != i } ? now - start : nil
        }
        v.toggleSlideshow()
        let first = await nextChange()
        check("advances after one interval (0 → 1)", v.index == 1 && first.map { abs($0 - interval) < 0.15 } == true, first)
        let second = await nextChange()
        check("and again (1 → 2)", v.index == 2 && second.map { abs($0 - interval) < 0.15 } == true, second)
        let held = assertions()
        values["assertionsWhilePlaying"] = held
        check("E7 playing keeps the display awake (activity held, PreventUserIdleDisplaySleep asserted)",
              v.slideshowActivity != nil && held.contains("PreventUserIdleDisplaySleep"), held)
        await sleep(interval / 2)
        press(124, right, arrow, w)
        let afterManual = await nextChange()
        values["afterManualStep"] = afterManual ?? -1
        check("a manual step keeps it running and restarts the countdown", v.index == 4
              && afterManual.map { $0 > interval - 0.05 && $0 < interval + 0.15 } == true, "\(v.index) \(afterManual ?? -1)")
        press(119, end, .function, w)
        check("End → last", v.index == 8, v.index)
        let loop = await nextChange()
        check("loops from the last image to the first", v.index == 0 && loop != nil, "\(v.index) \(loop ?? -1)")
        v.toggleSlideshow()
        let i = v.index
        await sleep(interval * 3)
        check("pause stops it", v.slideshow == nil && v.index == i, v.index)
        let released = assertions()
        check("E7 paused: the activity is released", v.slideshowActivity == nil && !released.contains("PreventUserIdleDisplaySleep"), released)
        v.toggleSlideshow()
        check("playing again holds it again", v.slideshowActivity != nil, nil)
        expectQuit(v, fade: true)
        let quit = onTerminate
        onTerminate = {
            quit?()
            check("E7 closing releases it", v.slideshow == nil && v.slideshowActivity == nil, nil)
        }
        press(53, "\u{1b}", [], w)
        await sleep(2)
        check("Esc closes during a slideshow", false, "still running")
    }

    /// C8 + C10: launched with 02-portrait.jpg (a neighbor each way). Controls show at open and hide together (cursor too) 3 s after the last
    /// mouse movement, come back on movement, stay while the pointer rests on the bar; edge arrows follow the pointer.
    private static func autoHideScenario() async {
        guard let v = await ready() else { return }
        let o = v.controls, w = v.window, b = v.canvas.bounds
        let elements = ["pill": o.pill, "bar": o.bar, "strip": o.stripSurface, "leftCircle": o.leftCircle, "rightCircle": o.rightCircle]
        let mid = NSPoint(x: b.midX, y: b.midY)
        check("shown at open (pill, bar and strip)", o.isShown && o.pill.alphaValue == 1 && o.bar.alphaValue == 1
              && o.stripSurface.alphaValue == 1, nil)
        let hidden = await wait(5) { o.bar.alphaValue == 0 }
        let idle = now - presentTime
        values["hiddenAfterOpen"] = idle
        check("hidden 3 s after opening without mouse movement", hidden && idle > 2.95 && idle < 3.5, idle)
        check("all controls alpha 0", elements.values.allSatisfy { $0.alphaValue == 0 }, elements.mapValues(\.alphaValue))
        check("the cursor hides with them", cursorHides == 1, cursorHides)
        check("hidden controls take no clicks", o.hitTest(center(o.bar)) == nil && o.hitTest(center(o.pill)) == nil
              && o.hitTest(center(o.stripSurface)) == nil, nil)
        // move() below calls the handler directly; real motion reaches it through this area.
        check("the overlay owns an always-active mouseMoved tracking area", o.trackingAreas.contains {
            $0.owner === o && $0.options.isSuperset(of: [.mouseMoved, .activeAlways, .inVisibleRect]) }, o.trackingAreas.map(\.options.rawValue))

        move(mid, v)
        check("mouse move shows them again (alpha 1)", o.isShown && o.bar.alphaValue == 1 && o.pill.alphaValue == 1
              && o.stripSurface.alphaValue == 1, nil)
        check("visible controls take clicks", o.hitTest(center(o.next))?.isDescendant(of: o.bar) == true, nil)
        check("away from the controls the overlay takes no clicks", o.hitTest(mid) == nil, nil)
        move(NSPoint(x: b.width * 0.05, y: b.midY), v)
        check("left edge: left arrow only", o.leftCircle.alphaValue == 1 && o.rightCircle.alphaValue == 0, nil)
        move(mid, v)
        check("center: no edge arrows", o.leftCircle.alphaValue == 0 && o.rightCircle.alphaValue == 0, nil)
        move(NSPoint(x: b.width * 0.95, y: b.midY), v)
        check("right edge: right arrow only", o.rightCircle.alphaValue == 1 && o.leftCircle.alphaValue == 0, nil)
        await sleep(0.4)
        let shown = screenshot("controls")
        // Leaving the window from inside the arrow (another screen): it is no longer hovered, so it hides.
        o.mouseExited(with: NSEvent.enterExitEvent(with: .mouseExited, location: center(o.rightArrow), modifierFlags: [],
                                                   timestamp: now, windowNumber: w.windowNumber, context: nil,
                                                   eventNumber: synthetic, trackingNumber: 0, userData: nil)!)
        check("pointer leaves the window: edge arrow hides, the rest stays", o.rightCircle.alphaValue == 0 && o.bar.alphaValue == 1, nil)

        move(center(o.bar), v)
        await sleep(3.6)
        check("the pointer resting on the bar keeps them up", o.isShown && o.bar.alphaValue == 1, Double(o.bar.alphaValue))
        // A drag is movement: 3.5 s after the last mouseMoved, 1.5 s after a drag of the image, they are still up.
        move(mid, v)
        mouse(.leftMouseDown, mid, w)
        await sleep(2)
        mouse(.leftMouseDragged, NSPoint(x: mid.x + 40, y: mid.y), w)
        await sleep(1.5)
        check("dragging keeps them up", o.isShown && o.bar.alphaValue == 1, Double(o.bar.alphaValue))
        mouse(.leftMouseUp, NSPoint(x: mid.x + 40, y: mid.y), w)
        // With the pointer on another screen they still hide, but the cursor there stays visible.
        let hides = cursorHides
        fakeMouse = NSPoint(x: w.frame.maxX + 50, y: w.frame.midY)
        o.hide()
        check("pointer off the viewer: controls hide, the cursor does not", !o.isShown && cursorHides == hides, cursorHides)
        fakeMouse = NSPoint(x: w.frame.midX, y: w.frame.midY)
        move(mid, v)
        let start = now
        let hidAgain = await wait(5) { o.bar.alphaValue == 0 }
        values["hiddenAfterMove"] = now - start
        check("hidden again 3 s after the last movement", hidAgain && now - start > 2.95 && now - start < 3.5, now - start)
        await sleep(0.4)
        if let shown, let gone = screenshot("controls-hidden") {
            let probe = NSPoint(x: o.bar.frame.minX + 6, y: o.bar.frame.midY)
            let a = pixel(shown, at: probe, w), z = pixel(gone, at: probe, w)
            check("captures differ at the bar (HUD drawn, then gone)", abs(a.r - z.r) + abs(a.g - z.g) + abs(a.b - z.b) + abs(a.a - z.a) > 0.1,
                  "\(a) vs \(z)")
        }
        // Hidden controls are not there for the mouse: where the pill was is backdrop again.
        expectQuit(v, fade: true)
        click(center(o.pill), w)
        await sleep(2)
        check("a click where the hidden pill was closes like the backdrop", false, "still running")
    }

    /// C9: launched with the nav folder. The pill shows "name  i / N" and follows navigation at once.
    private static func labelScenario() async {
        guard let v = await ready() else { return }
        let w = v.window, n = expectedNav.count
        func expect(_ name: String, _ i: Int) {
            check(name, v.controls.label.stringValue == "\(expectedNav[i])  \(i + 1) / \(n)", v.controls.label.stringValue)
        }
        expect("first image", 0)
        press(124, right, arrow, w); expect("→ updates it (before the decode lands)", 1)
        press(124, right, arrow, w); expect("→ again", 2)
        press(119, end, .function, w); expect("End", n - 1)
        press(124, right, arrow, w); expect("→ at the end: unchanged", n - 1)
        press(115, home, .function, w); expect("Home", 0)
        app?.application(NSApp, open: [fixtures.appendingPathComponent("02-portrait.jpg")])
        check("another folder: its name and count", v.controls.label.stringValue == "02-portrait.jpg  2 / 11", v.controls.label.stringValue)
    }

    // MARK: Step 4: thumbnail strip

    /// D1–D3, D6: launched with the 1200-image folder. The strip has an item per image, but only images in or near view
    /// get cells and decodes, also while it scrolls; the current image stays centered (animated for a step, instantly
    /// when flying or jumping); clicking a thumbnail goes there; the wheel scrolls the strip only while over it.
    private static func stripScenario() async {
        guard let v = await ready() else { return }
        let s = v.controls.strip, o = v.controls, w = v.window, pitch = ThumbnailStrip.pitch
        let perView = Int(ceil(s.bounds.width / pitch))
        values["stripFrame"] = NSStringFromRect(o.stripSurface.frame)
        values["cellsPerView"] = perView
        check("showThumbnails on, strip not hidden", Settings.showThumbnails && !o.stripSurface.isHidden, nil)
        check("D1 an item per image (1200), in viewer order", s.images.count == 1200 && s.images == v.images, s.images.count)
        let sf = o.stripSurface.frame
        check("as wide as 60% of the screen (the thumbnails would need more)", abs(sf.width - o.bounds.width * 0.6) < 0.5
              && s.frame.size == o.stripSurface.bounds.size, NSStringFromRect(sf))
        check("centered, 10 pt above the bar", abs(sf.midX - o.bounds.midX) < 0.5 && abs(sf.minY - o.bar.frame.maxY - 10) < 0.5,
              "\(NSStringFromRect(sf)) bar \(NSStringFromRect(o.bar.frame))")
        // Cells and decodes stay O(visible): sampled after every step below.
        var maxCells = 0, maxPending = 0, strays: [String] = []
        func sample(_ stage: String) {
            let layers = s.content.sublayers?.count ?? 0
            maxCells = max(maxCells, layers)
            maxPending = max(maxPending, s.pending.count)
            let inView = Set(s.cells.keys.map { s.images[$0] })
            // A decode for a file out of view may still be running (it only fills the cache), but never waiting.
            let queuedOut = s.pending.contains { !inView.contains($0.key) && !$0.value.isExecuting && !$0.value.isFinished }
            if layers != s.cells.count || queuedOut { strays.append(stage) }
        }
        let loaded = { s.cells.values.allSatisfy { $0.contents != nil } }
        sample("open")
        values["cellsAtOpen"] = s.cells.count
        check("D1 at open: cells only in or near view (< 80)", s.cells.count < 80 && s.cells.count <= perView + 5,
              "\(s.cells.count) cells, \(perView) per view")
        check("D1 at open: one decode request per cell", thumbRequests == s.cells.count, "\(thumbRequests) requests")
        check("thumbnails in view load", await wait(5, loaded), s.cells.values.filter { $0.contents == nil }.count)
        checkOwnThumbs(s, "at open")
        check("D3 at index 0 the strip is at its start", v.index == 0 && s.offset == 0 && s.cellFrame(0).minX == ThumbnailStrip.inset,
              s.offset)
        check("the current cell is highlighted (white border, larger)", s.cells[0].map { $0.borderWidth == 2
              && $0.affineTransform().a == 1.1 } == true && s.cells[1]?.borderWidth == 0, nil)

        /// A thumbnail's center in window coordinates.
        func thumb(_ k: Int) -> NSPoint { s.convert(NSPoint(x: s.cellFrame(k).midX, y: s.cellFrame(k).midY), to: nil) }
        move(thumb(5), v)
        check("thumbnail 5 is what the pointer hits", o.hitTest(thumb(5)) === s, o.hitTest(thumb(5)).map { "\(type(of: $0))" })
        click(thumb(5), w)
        check("D2 clicking thumbnail 5 shows image 5", v.index == 5 && v.currentURL == v.images[5], v.index)
        check("image 5 displayed", await displayed(v), shownURL?.lastPathComponent)
        click(s.convert(NSPoint(x: s.cellFrame(2).maxX + ThumbnailStrip.gap / 2, y: s.cellFrame(2).midY), to: nil), w)
        click(s.convert(NSPoint(x: 3, y: s.bounds.midY), to: nil), w) // the end padding
        await sleep(0.3)
        check("clicks between thumbnails: no navigation, no close", v.index == 5 && w.isVisible && w.alphaValue == 1, v.index)

        let onStrip = center(s)
        // Hover: the thumbnail under the resting pointer is lit, also after the strip scrolls under it.
        move(onStrip, v, into: s)
        let under = { s.cells.keys.filter { s.cellFrame($0).contains(s.convert(onStrip, from: nil)) } }
        let lit = { s.cells.filter { $0.value.opacity == 1 }.keys.filter { $0 != s.current }.sorted() }
        func hoverOK() -> Bool { under().count == 1 && lit() == under().filter { $0 != s.current } }
        let hoveredBefore = under()
        check("the thumbnail under the pointer is lit", hoverOK(), "lit \(lit()) under \(under())")
        w.sendEvent(scroll(0, -1, at: onStrip, w))
        check("a wheel notch over the strip scrolls it one thumbnail, no navigation", s.offset == pitch && v.index == 5,
              "\(s.offset) \(v.index)")
        check("the highlight moves to the thumbnail now under the pointer", hoverOK() && under() != hoveredBefore,
              "lit \(lit()) under \(under())")
        w.sendEvent(scroll(0, 1, at: onStrip, w))
        check("and back", s.offset == 0 && v.index == 5 && hoverOK() && under() == hoveredBefore, "\(s.offset) lit \(lit())")
        w.sendEvent(scroll(0, -1, at: NSPoint(x: o.bounds.midX, y: o.bounds.midY), w))
        check("a wheel notch over the image still navigates", v.index == 6, v.index)

        // A two-finger scroll over the strip at a trackpad's ~120 events/s, 400 pt each.
        let before = thumbRequests
        w.sendEvent(scroll(0, 0, precise: true, phase: 1, at: onStrip, w))
        for k in 0..<40 {
            w.sendEvent(scroll(-400, 0, precise: true, phase: 2, at: onStrip, w))
            sample("scroll \(k)")
            await sleep(0.008)
        }
        w.sendEvent(scroll(0, 0, precise: true, phase: 4, at: onStrip, w))
        let passed = Int(16000 / pitch)
        values["requestsWhileScrolling"] = thumbRequests - before
        values["maxCells"] = maxCells
        values["maxPending"] = maxPending
        check("two-finger scroll over the strip moves it 16000 pt, no navigation", s.offset == 16000 && v.index == 6,
              "\(s.offset) \(v.index)")
        check("D1 scrolling past \(passed) thumbnails: never 80 cells", maxCells < 80, maxCells)
        check("D1 decode requests only for thumbnails that came into view (<= \(passed) + \(perView + 5))",
              thumbRequests - before <= passed + perView + 5, thumbRequests - before)
        check("D1 pending decodes stay O(visible)", maxPending <= maxCells + 8, "\(maxPending) pending, \(maxCells) cells")
        check("D1 no queued decode for a file out of view, no stray cell", strays.isEmpty, strays)
        check("thumbnails load where it was scrolled to", await wait(5, loaded), s.cells.values.filter { $0.contents == nil }.count)
        checkOwnThumbs(s, "after scrolling")

        // In-flight de-duplication: into a part not decoded yet, away and straight back, all in one main-thread turn (so no
        // result arrives in between). Decodes already running are not asked for again; only the cancelled ones are.
        w.sendEvent(scroll(-3000, 0, precise: true, at: onStrip, w))
        let fresh = Set(s.cells.keys.map { s.images[$0] })
        w.sendEvent(scroll(-5000, 0, precise: true, at: onStrip, w))
        let running = s.pending.keys.filter(fresh.contains).count
        let r = thumbRequests
        w.sendEvent(scroll(5000, 0, precise: true, at: onStrip, w))
        values["dedup"] = "\(fresh.count) cells, \(running) still decoding, \(thumbRequests - r) asked again"
        check("D1 back in view: only the cancelled decodes are asked for again", Set(s.cells.keys.map { s.images[$0] }) == fresh
              && running > 0 && thumbRequests - r == fresh.count - running, values["dedup"])
        sample("dedup")
        check("those thumbnails load", await wait(5, loaded), nil)
        checkOwnThumbs(s, "after away and back")

        v.go(to: 600)
        check("D3 a jump to 600: centered within half a cell", abs(s.cellFrame(600).midX - s.bounds.midX) <= pitch / 2,
              s.cellFrame(600).midX - s.bounds.midX)
        check("a jump scrolls instantly", s.content.animationKeys() == nil, s.content.animationKeys())
        await sleep(0.35)
        check("D3 after the jump the cells are drawn where cellFrame says", drawnOff(s).isEmpty, drawnOff(s))
        press(124, right, arrow, w)
        let step = s.content.animation(forKey: "bounds")
        check("a single step: centered, animated over 0.2 s", v.index == 601 && step?.duration == 0.2
              && abs(s.cellFrame(601).midX - s.bounds.midX) <= pitch / 2, "\(v.index) \(String(describing: s.content.animationKeys()))")
        // While the step still slides, a click near the right edge of where 603 is drawn: by the target position
        // that is 604 (or the gap), so this needs hit-testing by the drawn position.
        move(center(o.bar), v)
        await sleep(0.03)
        let lag = s.offset - (s.content.presentation() ?? s.content).bounds.origin.x
        let sliding = !drawnOff(s).isEmpty
        click(s.convert(NSPoint(x: s.cellFrame(603).maxX + lag - 5, y: s.cellFrame(603).midY), to: nil), w)
        values["lagAtClick"] = lag
        check("D2 a click while a step slides picks the thumbnail drawn there", lag > 6 && sliding && v.index == 603,
              "index \(v.index), drawn \(lag) pt behind the target")
        // Holding →: key repeat at 30 Hz.
        var animated = 0, offCenter = 0
        for _ in 0..<30 {
            press(124, right, arrow, w, repeat: true)
            if s.content.animationKeys() != nil { animated += 1 }
            if abs(s.cellFrame(v.index).midX - s.bounds.midX) > pitch / 2 { offCenter += 1 }
            sample("flying")
            await sleep(0.033)
        }
        check("held → reaches 633", v.index == 633, v.index)
        check("D3 flying: the current image centered at every step", offCenter == 0, offCenter)
        check("flying scrolls instantly, never animated", animated == 0, animated)
        check("D1 flying: never 80 cells, no queued decode out of view", maxCells < 80 && strays.isEmpty, "\(maxCells) \(strays)")
        check("633 displayed", await displayed(v), shownURL?.lastPathComponent)
        check("D3 after flying the cells are drawn where cellFrame says", drawnOff(s).isEmpty, drawnOff(s))
        move(center(o.bar), v)
        check("thumbnails around 633 load", await wait(5, loaded), nil)
        checkOwnThumbs(s, "at 633")
        await sleep(0.4)
        screenshot("strip-1200")

        press(119, end, .function, w)
        check("End: the strip at its end", v.index == 1199 && abs(s.cellFrame(1199).maxX - (s.bounds.width - ThumbnailStrip.inset)) < 0.01,
              s.cellFrame(1199).maxX)
        press(115, home, .function, w)
        check("D3 Home: back at the start", v.index == 0 && s.offset == 0, s.offset)
        sample("end and home")
        o.hide()
        w.sendEvent(scroll(0, -1, at: onStrip, w))
        check("controls hidden: a wheel notch where the strip was navigates", v.index == 1, v.index)
        check("D1 overall: never 80 cells, no queued decode out of view", maxCells < 80 && strays.isEmpty, "\(maxCells) \(strays)")
    }

    /// D4–D6: launched with 01-landscape.jpg (the 11 mixed-format fixtures, all in view). Each thumbnail decodes once,
    /// off the main thread (ImageLoader.preview's dispatchPrecondition stops the app otherwise), small and upright;
    /// reopening the folder serves them all from the cache. The showThumbnails default hides and shows the strip, live.
    private static func thumbsScenario() async {
        defer { UserDefaults.standard.removeObject(forKey: "showThumbnails") }
        guard let v = await ready() else { return }
        let s = v.controls.strip, o = v.controls, w = v.window
        let start = now
        let loaded = await wait(5) { s.cells.count == 11 && s.cells.values.allSatisfy { $0.contents != nil } }
        values["thumbnailsLoadedAfterReady"] = now - start
        check("all 11 in view (the strip as wide as its thumbnails), each loaded", loaded && s.images.count == 11
              && s.bounds.width == s.intrinsicContentSize.width && s.offset == 0, "\(s.cells.count) \(s.bounds.width)")
        await sleep(0.2)
        check("D4 one decode per thumbnail (11 requests, 11 delivered)", thumbRequests == 11 && thumbLoads == 11 && thumbHits == 0,
              "\(thumbRequests) \(thumbLoads) \(thumbHits)")
        let decodeMs = (lastThumbLoad - firstThumbRequest) * 1000
        values["decodeAll11Ms"] = decodeMs
        let maxPixel = Int(ThumbnailStrip.cellSize.width * w.backingScaleFactor * 1.2)
        for (i, url) in s.images.enumerated() {
            let name = url.lastPathComponent, size = orientedSize(url)
            guard let thumb = s.cache.object(forKey: url as NSURL), let cell = s.cells[i] else { check("\(name): cached", false, nil); continue }
            let t = thumb.image
            check("\(name): cached with its image's full size", thumb.pixelSize == size, thumb.pixelSize)
            check("\(name): thumbnail \(t.width)x\(t.height), \(maxPixel) px long edge, the image's aspect",
                  max(t.width, t.height) == maxPixel && abs(Double(t.width) / Double(t.height) - size.width / size.height) < 0.02, nil)
            checkBands(t, "\(name) thumbnail")
            let b = cell.bounds
            check("\(name): cell aspect-fit in its 80x64 slot", b.width <= 80 && b.height <= 64 && (b.width == 80 || b.height == 64)
                  && abs(b.width / b.height - size.width / size.height) < 0.05, NSStringFromRect(b))
        }
        checkOwnThumbs(s, "loaded")
        move(center(o.bar), v)
        await sleep(0.4)
        screenshot("strip-mixed")

        // A second request for each: reopen the folder.
        let requests = thumbRequests, loads = thumbLoads, hits = thumbHits, t0 = now
        app?.application(NSApp, open: [fixtures.appendingPathComponent("03-small.png")])
        let reopenMs = (now - t0) * 1000
        values["reopenMs"] = reopenMs
        check("D4 reopening: all 11 thumbnails from the cache at once, no decode", s.images.count == 11 && thumbHits - hits == 11
              && thumbRequests == requests && s.cells.count == 11 && s.cells.values.allSatisfy { $0.contents != nil },
              "\(thumbHits - hits) hits, \(thumbRequests - requests) requests")
        checkOwnThumbs(s, "reopened")
        check("D4 measured: the cached reopen (folder listing included) beats decoding them", reopenMs < decodeMs,
              "reopen \(reopenMs) ms vs decode \(decodeMs) ms")
        check("the opened file is highlighted", v.index == 2 && s.current == 2 && s.cells[2]?.borderWidth == 2 && s.cells[0]?.borderWidth == 0,
              v.index)
        await sleep(0.3)
        check("and no decode arrives later", thumbLoads == loads, thumbLoads - loads)

        // D5: the default, live.
        move(center(o.bar), v)
        UserDefaults.standard.set(false, forKey: "showThumbnails")
        let stripPoint = center(o.stripSurface)
        let hid = await wait(0.2) { o.stripSurface.isHidden }
        check("D5 showThumbnails = false hides the strip (next turn)", hid && o.hitTest(stripPoint) == nil, nil)
        await sleep(0.4)
        check("the rest of the controls stay", o.isShown && o.bar.alphaValue == 1 && o.stripSurface.alphaValue == 0, nil)
        w.sendEvent(scroll(0, -1, at: stripPoint, w))
        check("a wheel notch where the strip was navigates", v.index == 3, v.index)
        let r = thumbRequests
        app?.application(NSApp, open: [nav.appendingPathComponent("img2.jpg")])
        check("hidden: another folder still gets its cells and thumbnail decodes (they stand in while flying), out of sight",
              s.images.count == 9 && s.cells.count == 9 && thumbRequests - r == 9 && o.stripSurface.isHidden
              && o.hitTest(stripPoint) == nil, "\(s.cells.count) \(thumbRequests - r)")
        move(center(o.bar), v)
        UserDefaults.standard.set(true, forKey: "showThumbnails")
        let shown = await wait(1) { !o.stripSurface.isHidden && o.stripSurface.alphaValue == 1 }
        check("D5 showThumbnails = true shows it again, live, with the new folder's cells", shown && s.cells.count == 9
              && s.current == v.index && o.hitTest(center(s)) === s, "\(s.cells.count) \(s.current) \(v.index)")
        let settled = await wait(5) { s.pending.isEmpty }
        let empty = s.cells.filter { $0.value.contents == nil }.map { s.images[$0.key].lastPathComponent }
        check("its thumbnails load (the text file named fake.jpg keeps the placeholder)", settled && empty == ["fake.jpg"], empty)
        checkOwnThumbs(s, "shown again")
        let failedAsks = thumbRequests
        app?.application(NSApp, open: [nav.appendingPathComponent("img1.jpg")])
        check("reopening it decodes nothing: fake.jpg's failure is remembered, not retried", s.images.count == 9
              && s.cells.count == 9 && thumbRequests == failedAsks, thumbRequests - failedAsks)

        // From another process (`defaults write` in a terminal) too.
        func defaults(_ args: String...) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            p.arguments = [args[0], Bundle.main.bundleIdentifier!] + args.dropFirst()
            try? p.run()
            p.waitUntilExit()
        }
        defaults("write", "showThumbnails", "-bool", "false")
        let hidOutside = await wait(3) { o.stripSurface.isHidden }
        check("D5 `defaults write … showThumbnails -bool false` from outside hides it, live", hidOutside, nil)
        defaults("delete", "showThumbnails")
        let backOutside = await wait(3) { !o.stripSurface.isHidden }
        check("D5 `defaults delete` from outside (back to the default, on) shows it again", backOutside, nil)
    }

    // MARK: Step 5: performance

    /// E1–E3: launched with the 1200-photo folder. Holding → at 30 Hz from the first image to the last: the main thread
    /// stays free, each key is cheap, something of the current image is on screen within a step, and the last image is
    /// sharp soon after. Then preloading where the user stops (at both ends and in the middle), and memory.
    private static func flyScenario() async {
        guard let v = await ready() else { return }
        let w = v.window, n = v.images.count, loader = v.loader
        check("1200 images", n == 1200, n)
        func cached(_ range: ClosedRange<Int>) -> [Int] { range.filter { loader.cache.object(forKey: v.images[$0] as NSURL) == nil } }
        await sleep(1)
        startHeartbeat()
        await sleep(1)
        values["heartbeatIdle"] = stopHeartbeat()
        // E2 at the start: the first image and the two after it.
        check("E2 at the first image: 0...2 cached", cached(0...2).isEmpty, cached(0...2))

        let decodes = decodeCallbacks, shownPreviews = previews
        startHeartbeat()
        let flight = await fly(v)
        let sharp = await wait(2) { shownURL == v.images[n - 1] && v.shown?.longEdge == 2400 }
        let settle = now - flight.end
        let beat = stopHeartbeat()
        let mean = flight.handling.reduce(0, +) / Double(flight.handling.count)
        values["flightSeconds"] = flight.end - flight.start
        values["heartbeat"] = beat
        values["keyDownMs"] = "mean \(mean * 1000), max \((flight.handling.max() ?? 0) * 1000)"
        values["maxBehind"] = flight.maxBehind
        values["shownAtOnce"] = flight.atOnce
        values["previewsShown"] = previews - shownPreviews
        values["decodesWhileFlying"] = decodeCallbacks - decodes
        values["lastImageSharpAfter"] = settle
        check("E1 held → reaches the last image", v.index == n - 1, v.index)
        check("E1 1199 keys at 30 Hz (~40 s)", abs(flight.end - flight.start - Double(n - 2) / 30) < 1.5, flight.end - flight.start)
        check("E1 heartbeat max gap < 50 ms", beat.max < 0.05, beat)
        check("E1 heartbeat p95 < 20 ms", beat.p95 < 0.02, beat)
        check("E1 keyDown handling mean < 3 ms", mean < 0.003, values["keyDownMs"])
        check("E1 the image on screen is never more than 1 behind", flight.maxBehind <= 1, flight.maxBehind)
        check("E1 flying decodes only where it stops (fast thumbnails meanwhile)", decodeCallbacks - decodes < 20
              && previews - shownPreviews > n / 2, "\(decodeCallbacks - decodes) decodes, \(previews - shownPreviews) thumbnails")
        check("E1 the last image's screen-size decode is shown within 1 s of the last key", sharp && settle < 1, settle)
        screenshot("fly-end")

        // E2: stopped, the in-range neighbors preload; the next step then comes straight from the cache.
        await sleep(2)
        check("E2 at the last image: 1197...1199 cached", cached(1197...1199).isEmpty, cached(1197...1199))
        v.go(to: 600)
        await sleep(2)
        check("E2 at 600 after 2 s: 598...602 cached", cached(598...602).isEmpty, cached(598...602))
        let callbacks = decodeCallbacks, t0 = now
        press(124, right, arrow, w)
        CATransaction.flush() // the frame commit included
        let step = now - t0
        values["cachedStepMs"] = step * 1000
        check("E2 → shows 601 from the cache in < 16 ms, no decode wait", step < 0.016 && v.index == 601 && shownURL == v.images[601]
              && v.shown === loader.cache.object(forKey: v.images[601] as NSURL) && decodeCallbacks == callbacks, step)
        press(115, home, .function, w)
        await sleep(2)
        check("E2 Home, after 2 s: 0...2 cached", cached(0...2).isEmpty, cached(0...2))
        // In-flight de-duplication: a preload of 900 and then landing on it, in one main-thread turn, decode it once.
        let far = v.images[900]
        loader.preload([far], maxPixelSize: 3840)
        v.go(to: 900)
        check("landing on 900 while its preload is pending: displayed", await displayed(v), shownURL?.lastPathComponent)
        await sleep(0.5)
        check("and decoded once", screenDecodes[far] == 1, screenDecodes[far])
        // A decode cached for a smaller screen (as before moving to a bigger one) is not reused soft: it decodes again.
        let small = v.images[910]
        loader.preload([small], maxPixelSize: 1200)
        await wait(5) { screenDecodes[small] == 1 }
        v.go(to: 910)
        let redecoded = await wait(5) { shownURL == small && v.shown?.longEdge == 2400 }
        check("a decode cached for a smaller screen (1200 px) is decoded again for this one", redecoded && screenDecodes[small] == 2,
              "\(v.shown?.longEdge ?? 0) px, \(screenDecodes[small] ?? 0) decodes")

        // E3. phys_footprint leaves ImageIO's decoded images out (it read under 100 MB with 1 GB of them cached), so
        // resident memory is bounded too, with the cache overfilled: 140 more decodes of 15 MB, twice its budget. (The
        // lifetime peak is only reported: resident size counts decode buffers ImageIO keeps for reuse, ~470 MB of them
        // with the cache emptied in a standalone probe, and none of the cache's own bitmaps, so it doesn't track the
        // cache. The cache's budget is enforced by its cost: checked below, also at the moment full resolution is asked.)
        let limit = Int(min(1 << 30, ProcessInfo.processInfo.physicalMemory / 8))
        values["cacheLimitMB"] = loader.cache.totalCostLimit >> 20
        check("E3 cache cost limit = min(1 GB, RAM / 8)", loader.cache.totalCostLimit == limit, loader.cache.totalCostLimit)
        func cacheCost() -> Int { v.images.compactMap { loader.cache.object(forKey: $0 as NSURL)?.cost }.reduce(0, +) }
        let flood = Array(v.images[100..<240])
        loader.preload(flood, maxPixelSize: 3840)
        let filled = await wait(30) { flood.allSatisfy { screenDecodes[$0] != nil } }
        var memory = self.memory()
        values["floodedCacheMB"] = cacheCost() >> 20
        values["flooded"] = "resident \(memory.resident / 1e6) MB, phys_footprint \(memory.footprint / 1e6) MB"
        check("E3 overfilled, the cache stays within its limit (and is full)", filled && cacheCost() <= limit && cacheCost() > limit * 8 / 10,
              cacheCost() >> 20)
        check("E3 resident memory with the cache full < 1.5 GB", memory.resident > 0 && memory.resident < 1.5e9, values["flooded"])
        check("E3 phys_footprint < 1.5 GB", memory.footprint > 0 && memory.footprint < 1.5e9, values["flooded"])
        // On top, a 12000×8000 full-resolution decode (384 MB): the cache gives up half its budget while it is wanted.
        var full: Decoded?
        loader.loadFullResolution(fixtures.appendingPathComponent("10-huge.jpg")) { full = $0 }
        let trimmed = cacheCost()
        check("E3 asking for full resolution trims the cache to half its limit at once, before the decode allocates",
              trimmed <= limit / 2 && trimmed > limit * 4 / 10, trimmed >> 20)
        let got = await wait(10) { full != nil }
        memory = self.memory()
        values["withFullResolution"] = "cache \(cacheCost() >> 20) MB, resident \(memory.resident / 1e6) MB, peak \(memory.peak / 1e6) MB"
        check("E3 + a full-resolution decode held: cache within half its limit, resident < 1.5 GB", got && full?.image.width == 12000
              && cacheCost() <= limit / 2 && memory.resident < 1.5e9, values["withFullResolution"])
        full = nil
        loader.moved(to: v.currentURL!)
        check("moving on gives the cache its whole budget back", loader.cache.totalCostLimit == limit, loader.cache.totalCostLimit)
    }

    /// E1 over files with no embedded preview (fixtures/plain: 90 PNGs of 6000×4000, whose fast thumbnail means
    /// downsampling the whole image, longer than a key repeat). Flying shows the strip's cached thumbnail of each image
    /// at once, so the image on screen keeps up as with camera JPEGs. flypnghidden: the same with the strip turned off
    /// in Settings (its thumbnails still decode, out of sight).
    private static func flyPNGScenario() async {
        guard let v = await ready() else { return }
        let n = v.images.count, s = v.controls.strip, url = v.images[n - 1], hidden = scenario == "flypnghidden"
        check("90 PNGs", n == 90, n)
        check(hidden ? "the strip is turned off" : "the strip is on", v.controls.stripSurface.isHidden == hidden
              && Settings.showThumbnails != hidden, v.controls.stripSurface.isHidden)
        let previewMs = await Task.detached { () -> Double in
            let t = ProcessInfo.processInfo.systemUptime
            _ = ImageLoader.preview(url, maxPixelSize: 384)
            return (ProcessInfo.processInfo.systemUptime - t) * 1000
        }.value
        values["fastThumbnailMs"] = previewMs
        check("no embedded preview: a fast thumbnail takes longer than a key repeat (33 ms)", previewMs > 33, previewMs)
        check("the strip's first thumbnails load", await wait(10) { s.pending.isEmpty && s.cache.object(forKey: v.images[1] as NSURL) != nil }, nil)
        startHeartbeat()
        let flight = await fly(v)
        let screen = v.window.screen!, screenPixels = Int(max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor)
        let sharp = await wait(2) { shownURL == url && v.shown?.longEdge == min(screenPixels, 6000) }
        let settle = now - flight.end, beat = stopHeartbeat()
        let mean = flight.handling.reduce(0, +) / Double(flight.handling.count)
        values["heartbeat"] = beat
        values["keyDownMs"] = "mean \(mean * 1000), max \((flight.handling.max() ?? 0) * 1000)"
        values["maxBehind"] = flight.maxBehind
        values["shownAtOnce"] = "\(flight.atOnce) of \(n - 1)"
        values["lastImageSharpAfter"] = settle
        check("held → reaches the last image", v.index == n - 1, v.index)
        check("the image on screen is never more than 1 behind", flight.maxBehind <= 1, flight.maxBehind)
        check("most steps show the strip's thumbnail before the key returns", flight.atOnce >= (n - 1) * 9 / 10, values["shownAtOnce"])
        check("heartbeat max gap < 50 ms, keyDown mean < 3 ms", beat.max < 0.05 && mean < 0.003, "\(beat) \(values["keyDownMs"] ?? "")")
        check("the last image's screen-size decode is shown within 1 s of the last key", sharp && settle < 1, settle)
        screenshot("\(scenario)-end")
    }

    /// Holds → at 30 Hz from the current image to the last, sampling at each key and heartbeat how far the image on screen
    /// lags behind the index. Returns each keyDown's handling time, that lag's maximum, the keys whose image was on screen
    /// when they returned, and when the flight started and ended.
    private static func fly(_ v: ViewerController) async -> (handling: [Double], maxBehind: Int, atOnce: Int, start: Double, end: Double) {
        let position = Dictionary(uniqueKeysWithValues: v.images.enumerated().map { ($1, $0) })
        func behind() -> Int { v.index - (v.displayedURL.flatMap { position[$0] } ?? -1000) }
        var handling: [Double] = [], maxBehind = 0, atOnce = 0
        onBeat = { maxBehind = max(maxBehind, behind()) }
        let first = v.index, start = now
        var end = start
        for k in first + 1..<v.images.count {
            let due = start + Double(k - first - 1) / 30
            if due > now { await sleep(due - now) }
            maxBehind = max(maxBehind, behind())
            let t0 = now
            press(124, right, arrow, v.window, repeat: k > first + 1)
            end = now
            handling.append(end - t0)
            if v.displayedURL == v.currentURL { atOnce += 1 }
        }
        onBeat = nil
        return (handling, maxBehind, atOnce, start, end)
    }

    /// E5: launched with gif/anim.gif (frames red, green, blue, yellow for 0.1, 0.25, 0.5 and 0.01 → 0.1 s). It plays
    /// on a loop with each frame's delay; a 1-frame GIF is still; 30 frames of 2000×1200 are shrunk under 256 MB; an
    /// animation shrunk below the fast thumbnail shown while flying onto it still replaces that thumbnail.
    private static func gifScenario() async {
        guard let v = await ready() else { return }
        let layer = v.canvas.imageLayer, w = v.window
        v.controls.hide()
        func playing() -> CAKeyframeAnimation? { layer.animation(forKey: "frames") as? CAKeyframeAnimation }
        guard let a = playing() else { return check("E5 anim.gif: a keyframe animation on contents", false, layer.animationKeys()) }
        let times = (a.keyTimes ?? []).map(\.doubleValue), expected = [0, 0.1, 0.35, 0.85, 0.95].map { $0 / 0.95 }
        values["keyTimes"] = times
        check("E5 4 frames, discrete, looping forever", a.keyPath == "contents" && a.values?.count == 4 && a.calculationMode == .discrete
              && a.repeatCount == .infinity, "\(a.values?.count ?? 0) \(a.calculationMode.rawValue) \(a.repeatCount)")
        check("E5 total 0.95 s; frames start at 0, 0.1, 0.35, 0.85 s (0.01 s plays as 0.1)", abs(a.duration - 0.95) < 1e-9
              && times.count == 5 && zip(times, expected).allSatisfy { abs($0 - $1) < 1e-9 }, "\(a.duration) \(times)")
        let colors = (a.values as? [CGImage] ?? []).map { classify(pixel($0, x: 0.1, yFromTop: 0.5)) }
        check("E5 the frames are red, green, blue, yellow", colors == ["R", "G", "B", "Y"], colors)
        // On screen, captures over a second or so catch more than one frame.
        let f = layer.frame
        var seen: [String] = []
        for _ in 0..<6 {
            if let shot = screenshot("gif") { seen.append(classify(pixel(shot, at: NSPoint(x: f.minX + 20, y: f.midY), w))) }
            await sleep(0.07)
        }
        values["framesSeen"] = seen
        check("E5 it plays: captures show several frames, all of them its own", Set(seen).count >= 2
              && Set(seen).isSubset(of: ["R", "G", "B", "Y"]), seen)

        press(124, right, arrow, w)
        guard await displayed(v, timeout: 10) else { return check("big.gif displayed", false, nil) }
        let big = playing(), frames = big?.values as? [CGImage] ?? []
        let bytes = frames.reduce(0) { $0 + $1.bytesPerRow * $1.height }
        values["bigGIF"] = "\(frames.count) frames of \(frames.first.map { "\($0.width)x\($0.height)" } ?? "-"), \(bytes >> 20) MB"
        let pixels = frames.reduce(0) { $0 + $1.width * $1.height * 4 }
        check("E5 big.gif (288 MB at full size): all 30 frames, shrunk to frames × w × h × 4 within 256 MB", frames.count == 30
              && pixels <= 256 << 20 && pixels > 240 << 20 && frames.allSatisfy { $0.width < 2000 } && abs((big?.duration ?? 0) - 1.5) < 1e-9,
              values["bigGIF"])
        check("E5 big.gif laid out at its full size", v.canvas.imageSize == CGSize(width: 2000, height: 1200), v.canvas.imageSize)
        press(119, end, .function, w) // still.gif, past long.gif
        guard await displayed(v) else { return check("still.gif displayed", false, nil) }
        check("E5 a 1-frame GIF is still: no animation, its picture", playing() == nil && layer.animationKeys()?.contains("frames") != true
              && currentImage(v).map { classify(pixel($0, x: 0.1, yFromTop: 0.5)) } == "G", layer.animationKeys())
        press(115, home, .function, w)
        check("back on anim.gif (cached): playing again", v.index == 0 && shownURL == v.images[0] && playing()?.values?.count == 4, nil)

        // Flying onto long.gif (500 frames of 800×800, shrunk under 256 MB to less than the 384 px fast thumbnail) with no
        // strip thumbnail and no decode cached: the fast thumbnail stands in, then the animation replaces it and plays.
        let long = v.images[2]
        await wait(10) { screenDecodes[long] != nil } // its preload from launch
        v.controls.strip.cache.removeAllObjects()
        uncache(long)
        press(124, right, arrow, w) // big.gif, from the cache
        press(124, right, arrow, w, repeat: true)
        let still = await wait(2) { v.displayedURL == long && v.shown?.frames.isEmpty == true }
        let stand = v.shown?.longEdge ?? 0
        let plays = await wait(10) { playing()?.values?.count == 500 }
        values["longGIF"] = "still \(stand) px, then \(v.shown.map { "\($0.frames.count) frames of \($0.longEdge) px" } ?? "-")"
        check("E5 flying onto long.gif: its fast thumbnail, then its 500 smaller frames replace it and play", still && plays
              && v.index == 2 && shownURL == long && (v.shown?.longEdge ?? .max) < stand
              && v.canvas.imageSize == CGSize(width: 800, height: 800), values["longGIF"])
    }

    private static func classify(_ c: (r: Double, g: Double, b: Double, a: Double)) -> String {
        switch (c.r > 0.6, c.g > 0.6, c.b > 0.6) {
        case (true, false, false) where c.g < 0.4 && c.b < 0.4: return "R"
        case (false, true, false) where c.r < 0.4 && c.b < 0.4: return "G"
        case (false, false, true) where c.r < 0.4 && c.g < 0.4: return "B"
        case (true, true, false) where c.b < 0.4: return "Y"
        default: return String(format: "?%.2f,%.2f,%.2f", c.r, c.g, c.b)
        }
    }

    /// This process's power assertions, from `pmset -g assertions`.
    private static func assertions() -> String {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g", "assertions"]
        p.standardOutput = pipe
        try? p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return out.split(separator: "\n").filter { $0.contains("pid \(getpid())(") }.joined(separator: "\n")
    }

    /// Main-thread heartbeat: a 4 ms timer whose gaps show how long the main thread was busy.
    private static var beats: [Double] = []
    private static var beatTimer: Timer?
    private static var onBeat: (() -> Void)?

    private static func startHeartbeat() {
        beats = []
        let timer = Timer(timeInterval: 0.004, repeats: true) { _ in
            MainActor.assumeIsolated {
                beats.append(now)
                onBeat?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        beatTimer = timer
    }

    private static func stopHeartbeat() -> (max: Double, p95: Double, beats: Int) {
        beatTimer?.invalidate()
        let gaps = zip(beats.dropFirst(), beats).map { $0 - $1 }.sorted()
        guard !gaps.isEmpty else { return (1, 1, 0) }
        return (gaps.last!, gaps[Int(Double(gaps.count - 1) * 0.95)], beats.count)
    }

    /// This process's phys_footprint, resident size and peak resident size (getrusage), in bytes.
    private static func memory() -> (footprint: Double, resident: Double, peak: Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        guard result == KERN_SUCCESS else { return (-1, -1, -1) }
        return (Double(info.phys_footprint), Double(info.resident_size), Double(usage.ru_maxrss))
    }

    /// Cells whose drawn center (presentation layers, through the scrolled content) is off cellFrame, the model that
    /// the centering checks use.
    private static func drawnOff(_ s: ThumbnailStrip) -> [Int] {
        let c = s.content.presentation() ?? s.content
        return s.cells.filter { i, cell in
            let p = (cell.presentation() ?? cell).position, f = s.cellFrame(i)
            let x = c.position.x - c.bounds.width / 2 + p.x - c.bounds.minX
            let y = c.position.y - c.bounds.height / 2 + p.y - c.bounds.minY
            return abs(x - f.midX) > 0.5 || abs(y - f.midY) > 0.5
        }.keys.sorted()
    }

    /// Every cell with a picture shows the cached thumbnail of its own file: a late result never lands in another cell.
    private static func checkOwnThumbs(_ s: ThumbnailStrip, _ stage: String) {
        let wrong = s.cells.filter { i, cell in
            cell.contents.map { $0 as AnyObject !== s.cache.object(forKey: s.images[i] as NSURL)?.image } ?? false
        }.keys.sorted()
        check("\(stage): every cell shows its own file's thumbnail", wrong.isEmpty, wrong)
    }

    /// A click as a control's tracking loop sees it: the mouse-up waits in the event queue, then the mouse-down goes
    /// to the window, so the loop it starts reads that release. (Posting both raced: the loop could end without it.)
    private static func postClick(_ point: NSPoint, _ window: NSWindow) {
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: now, windowNumber: window.windowNumber,
                               context: nil, eventNumber: synthetic, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
        }
        NSApp.postEvent(event(.leftMouseUp), atStart: false)
        window.sendEvent(event(.leftMouseDown))
    }

    // MARK: Helpers

    private static var viewer: ViewerController? { app?.viewer }
    /// eventNumber of synthesized mouse events, which the real-input filter lets through.
    private static let synthetic = 0x5e1f
    private static var nav: URL { fixtures.appendingPathComponent("nav") }
    /// What the nav folder must list: the FileManager listing minus its hidden files, non-images and subfolder,
    /// sorted the way Finder sorts names.
    private static var expectedNav: [String] {
        let excluded: Set = [".hidden.jpg", "flagged.jpg", "notes.txt", "sub"]
        return ((try? FileManager.default.contentsOfDirectory(atPath: nav.path)) ?? [])
            .filter { !excluded.contains($0) }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
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

    /// Waits until the image at the current index is on screen (laid out at its size; unreadable files: no size).
    private static func displayed(_ v: ViewerController, timeout: Double = 5) async -> Bool {
        await wait(timeout) {
            v.images.indices.contains(v.index) && shownURL == v.images[v.index] && shownURL == v.currentURL
                && v.canvas.imageSize == orientedSize(v.images[v.index])
        }
    }

    /// Drops a file's screen-size decode, so the next visit decodes it (preloading would otherwise have it ready).
    private static func uncache(_ url: URL) { viewer?.loader.cache.removeObject(forKey: url as NSURL) }

    private static func orientedSize(_ url: URL) -> CGSize {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap(ImageLoader.orientedSize) ?? .zero
    }

    /// Opens a fixture through the Finder path and waits until its decode (not a fast thumbnail) is on screen.
    private static func open(_ name: String, size: CGSize) async -> Bool {
        let shows = shownCount
        app?.application(NSApp, open: [fixtures.appendingPathComponent(name)])
        let ok = await wait(5) {
            shownCount > shows && shownURL?.lastPathComponent == name && viewer?.currentURL?.lastPathComponent == name
                && viewer?.canvas.imageSize == size && viewer.flatMap(currentImage) != nil
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

    private static func key(_ code: UInt16, _ chars: String, _ modifiers: NSEvent.ModifierFlags, _ window: NSWindow,
                            repeat isARepeat: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: now,
                         windowNumber: window.windowNumber, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: isARepeat, keyCode: code)!
    }

    // Characters and flags AppKit gives the arrow, Home and End keys.
    private static let left = "\u{F702}", right = "\u{F703}", home = "\u{F729}", end = "\u{F72B}"
    private static let arrow: NSEvent.ModifierFlags = [.numericPad, .function]

    private static func press(_ code: UInt16, _ chars: String, _ modifiers: NSEvent.ModifierFlags, _ window: NSWindow,
                              repeat isARepeat: Bool = false) {
        window.sendEvent(key(code, chars, modifiers, window, repeat: isARepeat))
    }

    /// While set, key-downs pass the real-input filter (NSApp.sendEvent runs local monitors; window.sendEvent doesn't).
    private static var sendingKey = false

    /// A key through NSApp, the path real keystrokes take.
    private static func sendKey(_ event: NSEvent) {
        sendingKey = true
        NSApp.sendEvent(event)
        sendingKey = false
    }

    /// A scroll event like the window server's: line units for a wheel notch, pixels plus phases for a trackpad.
    /// `inverted` sets isDirectionInvertedFromDevice (natural scrolling) through its undocumented CGEvent field 137.
    private static func scroll(_ dx: Int32, _ dy: Int32, precise: Bool = false, phase: Int64 = 0, momentum: Int64 = 0,
                               inverted: Bool = false, command: Bool = false, at point: NSPoint? = nil, _ window: NSWindow) -> NSEvent {
        let e = CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line, wheelCount: 2,
                        wheel1: dy, wheel2: dx, wheel3: 0)!
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: precise ? 1 : 0)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        e.setIntegerValueField(CGEventField(rawValue: 137)!, value: inverted ? 1 : 0)
        e.flags = command ? .maskCommand : []
        // The event has no window, so sendEvent hit-tests its screen location as window coordinates: aim at `point`
        // (default: the window's center) in the window's own coordinates (CG global space has a top-left origin).
        let size = window.frame.size, p = point ?? NSPoint(x: size.width / 2, y: size.height / 2)
        e.location = CGPoint(x: p.x, y: NSScreen.screens[0].frame.maxY - p.y)
        return NSEvent(cgEvent: e)!
    }

    /// A trackpad pinch like the window server's, into the window: began, one changed step of `magnification`, ended.
    /// A gesture CGEvent (type 29) with HID type 8 (zoom) in field 110, the magnification in field 113 and the phase in
    /// field 132 becomes an NSEvent of type .magnify. The window picks the target view at .began (a lone .changed is
    /// dropped). Aimed like scroll().
    private static func pinch(_ magnification: Double, at p: NSPoint, _ window: NSWindow) {
        for (phase, m) in [(1, 0), (2, magnification), (4, 0)] as [(Int64, Double)] {
            let e = CGEvent(source: nil)!
            e.type = CGEventType(rawValue: 29)!
            e.setIntegerValueField(CGEventField(rawValue: 110)!, value: 8)
            e.setDoubleValueField(CGEventField(rawValue: 113)!, value: m)
            e.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase)
            e.location = CGPoint(x: p.x, y: NSScreen.screens[0].frame.maxY - p.y)
            window.sendEvent(NSEvent(cgEvent: e)!)
        }
    }

    /// A two-finger swipe: physical finger motion per event (right/down positive) over began + `steps` changed + ended,
    /// then a momentum tail of 4 × 3 × the finger step. Deltas follow the content, which is the finger direction only
    /// with natural scrolling. window.sendEvent silently drops synthesized momentum events, so the tail goes straight
    /// to the canvas, the view the gesture hit (scrollEvents vs sentScrolls proves every event arrived).
    private static func swipe(_ fx: Int32, _ fy: Int32, steps: Int = 5, inverted: Bool, command: Bool = false,
                              _ v: ViewerController) {
        let s: Int32 = inverted ? 1 : -1
        func send(_ dx: Int32, _ dy: Int32, phase: Int64 = 0, momentum: Int64 = 0) {
            let e = scroll(dx * s, dy * s, precise: true, phase: phase, momentum: momentum, inverted: inverted, command: command, v.window)
            if momentum == 0 { v.window.sendEvent(e) } else { v.canvas.scrollWheel(with: e) }
            sentScrolls += 1
        }
        send(0, 0, phase: 128) // mayBegin
        send(fx, fy, phase: 1) // began
        for _ in 0..<steps { send(fx, fy, phase: 2) } // changed
        send(0, 0, phase: 4) // ended
        send(fx * 3, fy * 3, momentum: 1)
        for _ in 0..<3 { send(fx * 3, fy * 3, momentum: 2) }
        send(0, 0, momentum: 3)
    }

    /// Mouse down at `point`, up at `to` (a drag when they differ), window coordinates.
    private static func click(_ point: NSPoint, _ window: NSWindow, to: NSPoint? = nil) {
        mouse(.leftMouseDown, point, window)
        mouse(.leftMouseUp, to ?? point, window)
    }

    private static func mouse(_ type: NSEvent.EventType, _ point: NSPoint, _ window: NSWindow, clickCount: Int = 1) {
        window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: now,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: synthetic,
                                            clickCount: clickCount, pressure: type == .leftMouseUp ? 0 : 1)!)
    }

    private static func doubleClick(_ point: NSPoint, _ window: NSWindow) {
        for n in 1...2 {
            mouse(.leftMouseDown, point, window, clickCount: n)
            mouse(.leftMouseUp, point, window, clickCount: n)
        }
    }

    /// Press at `from`, drag in steps to `to`, release there.
    private static func drag(_ from: NSPoint, _ to: NSPoint, _ window: NSWindow) {
        mouse(.leftMouseDown, from, window)
        for i in 1...4 {
            let t = CGFloat(i) / 4
            mouse(.leftMouseDragged, NSPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t), window)
        }
        mouse(.leftMouseUp, to, window)
    }

    /// Pointer motion to `point` (window coordinates). The overlay hears motion through an always-active tracking
    /// area, which AppKit only feeds from window-server events, so the synthesized event goes to its handler directly
    /// (or to `view`'s, e.g. the strip's, which passes it on to the overlay).
    private static func move(_ point: NSPoint, _ v: ViewerController, into view: NSView? = nil) {
        (view ?? v.controls).mouseMoved(with: NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: now,
                                                       windowNumber: v.window.windowNumber, context: nil, eventNumber: synthetic,
                                                       clickCount: 0, pressure: 0)!)
    }

    /// A view's center in window coordinates.
    private static func center(_ view: NSView) -> NSPoint {
        view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    }

    /// The captured window's color at a point in window coordinates.
    private static func pixel(_ shot: CGImage, at p: NSPoint, _ window: NSWindow) -> (r: Double, g: Double, b: Double, a: Double) {
        let k = CGFloat(shot.width) / window.frame.width
        let one = shot.cropping(to: CGRect(x: floor(p.x * k), y: floor((window.frame.height - p.y) * k), width: 1, height: 1))
        return one.map { pixel($0, x: 0, yFromTop: 0) } ?? (-1, -1, -1, -1)
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
