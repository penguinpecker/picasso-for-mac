// Generates deterministic test images: make-fixtures <out-dir> <scratch-dir>
// Every image has a red band at its visual top and a blue band at its visual bottom,
// plus a large "↑ N" label, so tests and screenshots can tell which image shows and which way is up.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let scratch = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
for dir in [out, scratch] { try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }

func context(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func draw(_ w: Int, _ h: Int, _ label: String, _ caption: String, hue: CGFloat) -> CGImage {
    let ctx = context(w, h)
    ctx.setFillColor(NSColor(hue: hue, saturation: 0.45, brightness: 0.5, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let band = max(6, h / 12)
    ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: h - band, width: w, height: band)) // top (CG is y-up)
    ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: band))

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let big = CGFloat(min(w, h)) / 3.2
    let title = NSAttributedString(string: "↑ \(label)", attributes: [
        .font: NSFont.systemFont(ofSize: big, weight: .heavy), .foregroundColor: NSColor.white])
    let sub = NSAttributedString(string: caption, attributes: [
        .font: NSFont.systemFont(ofSize: big / 4.5, weight: .semibold), .foregroundColor: NSColor(white: 1, alpha: 0.85)])
    let ts = title.size(), ss = sub.size()
    let top = (CGFloat(h) + ts.height + ss.height) / 2
    title.draw(at: CGPoint(x: (CGFloat(w) - ts.width) / 2, y: top - ts.height))
    sub.draw(at: CGPoint(x: (CGFloat(w) - ss.width) / 2, y: top - ts.height - ss.height))
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}

func write(_ images: [CGImage], _ name: String, _ type: UTType, in dir: URL = out,
           file: [CFString: Any] = [:], frame: [CFString: Any] = [:]) {
    let url = dir.appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, images.count, nil)!
    CGImageDestinationSetProperties(dest, file as CFDictionary)
    for image in images { CGImageDestinationAddImage(dest, image, frame as CFDictionary) }
    precondition(CGImageDestinationFinalize(dest), "failed to write \(name)")
}

let jpeg: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]

write([draw(4000, 3000, "1", "4000×3000 JPEG", hue: 0.58)], "01-landscape.jpg", .jpeg, frame: jpeg)
write([draw(3000, 4000, "2", "3000×4000 JPEG", hue: 0.33)], "02-portrait.jpg", .jpeg, frame: jpeg)
write([draw(300, 200, "3", "300×200 PNG", hue: 0.08)], "03-small.png", .png)

// EXIF orientation 6 = "rotate 90° CW to display": store the upright portrait rotated 90° CCW.
let upright = draw(3000, 4000, "4", "EXIF 6 (stored 4000×3000)", hue: 0.75)
let stored = context(4000, 3000)
stored.translateBy(x: 4000, y: 0)
stored.rotate(by: .pi / 2)
stored.draw(upright, in: CGRect(x: 0, y: 0, width: 3000, height: 4000))
write([stored.makeImage()!], "04-exif6.jpg", .jpeg, frame: jpeg.merging([kCGImagePropertyOrientation: 6]) { $1 })

write([draw(2400, 1600, "5", "2400×1600 HEIC", hue: 0.95)], "05-photo.heic", .heic, frame: jpeg)

// ImageIO can't encode WebP; go through cwebp (fixture generation only).
func writeWebP(_ image: CGImage, _ name: String, in dir: URL = out) {
    let png = (name as NSString).deletingPathExtension + ".png"
    write([image], png, .png, in: scratch)
    let cwebp = Process()
    cwebp.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/cwebp")
    cwebp.arguments = ["-quiet", "-q", "85", scratch.appendingPathComponent(png).path, "-o", dir.appendingPathComponent(name).path]
    try! cwebp.run()
    cwebp.waitUntilExit()
    precondition(cwebp.terminationStatus == 0, "cwebp failed")
}
writeWebP(draw(1600, 1200, "6", "1600×1200 WebP", hue: 0.15), "06-photo.webp")

write([draw(1500, 1000, "7", "1500×1000 TIFF", hue: 0.5)], "07-photo.tiff", .tiff)
write([draw(1200, 900, "8", "1200×900 BMP", hue: 0.66)], "08-photo.bmp", .bmp)

let frames = (1...3).map { draw(600, 400, "9", "GIF frame \($0)/3", hue: CGFloat($0) / 4) }
write(frames, "09-anim.gif", .gif,
      file: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]],
      frame: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.4]])

write([draw(12000, 8000, "10", "12000×8000 JPEG", hue: 0.02)], "10-huge.jpg", .jpeg, frame: jpeg)

// GIF playback (a subfolder, so the top folder's image count stays put): per-frame delays, including one under
// 0.02 s that plays as 0.1 s; a single-frame GIF; and 30 frames of 2000×1200 (288 MB decoded) that must be shrunk.
let gifs = out.appendingPathComponent("gif", isDirectory: true)
try! FileManager.default.createDirectory(at: gifs, withIntermediateDirectories: true)
func solid(_ w: Int, _ h: Int, _ color: CGColor, _ label: String) -> CGImage {
    let ctx = context(w, h)
    ctx.setFillColor(color)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let text = NSAttributedString(string: label, attributes: [
        .font: NSFont.systemFont(ofSize: CGFloat(h) / 3, weight: .heavy), .foregroundColor: NSColor.white])
    text.draw(at: CGPoint(x: (CGFloat(w) - text.size().width) / 2, y: (CGFloat(h) - text.size().height) / 2))
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}
func writeGIF(_ name: String, _ frames: [(CGImage, Double)]) {
    let dest = CGImageDestinationCreateWithURL(gifs.appendingPathComponent(name) as CFURL, UTType.gif.identifier as CFString,
                                               frames.count, nil)!
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for (image, delay) in frames {
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
    }
    precondition(CGImageDestinationFinalize(dest), "failed to write \(name)")
}
let primaries = [CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1),
                 CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1), CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)]
writeGIF("anim.gif", zip(primaries, [0.1, 0.25, 0.5, 0.01]).enumerated().map { (solid(600, 400, $1.0, "F\($0 + 1)"), $1.1) })
writeGIF("still.gif", [(solid(600, 400, primaries[1], "still"), 0.5)])
writeGIF("big.gif", (0..<30).map { (solid(2000, 1200, primaries[$0 % 4], "\($0 + 1)/30"), 0.05) })

// A long animation: 500 frames of 800×800 decode to 1.28 GB, so they are shrunk to ~366 px to fit 256 MB, smaller than
// the 384 px fast thumbnail shown while flying onto it.
let longFrames = primaries.enumerated().map { solid(800, 800, $1, "\($0 + 1)") }
writeGIF("long.gif", (0..<500).map { (longFrames[$0 % 4], 0.05) })

// Orientations 1–8 on one stored picture (red, green over blue, yellow), to check the full-resolution path turns each
// the way ImageIO's thumbnail path does: JPEG (EXIF), HEIC (ImageIO writes irot/imir boxes, as an iPhone does) and DNG
// (camera RAW, decoded by ImageIO's RAW engine).
let orient = out.appendingPathComponent("orient", isDirectory: true)
try! FileManager.default.createDirectory(at: orient, withIntermediateDirectories: true)
let quadrants = context(300, 200)
for (i, color) in primaries.enumerated() {
    quadrants.setFillColor(color)
    quadrants.fill(CGRect(x: i % 2 * 150, y: i < 2 ? 100 : 0, width: 150, height: 100)) // CG is y-up: red, green on top
}
for o in 1...8 {
    for (ext, type) in [("jpg", UTType.jpeg), ("heic", .heic)] {
        write([quadrants.makeImage()!], "o\(o).\(ext)", type, in: orient,
              frame: [kCGImagePropertyOrientation: o, kCGImageDestinationLossyCompressionQuality: 0.95])
    }
}

// ImageIO can't write RAW: a minimal DNG by hand. One IFD, uncompressed 16-bit LinearRaw RGB (the picture's rows,
// top first), a camera matrix of sRGB primaries, D65 white balance, and the orientation tag.
func writeDNG(_ name: String, rgba: UnsafePointer<UInt8>, width w: Int, height h: Int, bytesPerRow: Int, orientation: Int) {
    func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
    var tags: [(tag: UInt16, type: UInt16, count: Int, value: [UInt8])] = []
    func short(_ tag: UInt16, _ v: [Int]) { tags.append((tag, 3, v.count, v.flatMap { le(UInt16($0)) })) }
    func long(_ tag: UInt16, _ v: Int) { tags.append((tag, 4, 1, le(UInt32(v)))) }
    func bytes(_ tag: UInt16, _ v: [UInt8]) { tags.append((tag, 1, v.count, v)) }
    func ascii(_ tag: UInt16, _ s: String) { tags.append((tag, 2, s.utf8.count + 1, Array(s.utf8) + [0])) }
    func ratio(_ tag: UInt16, signed: Bool, _ v: [Double]) {
        tags.append((tag, signed ? 10 : 5, v.count, v.flatMap { le(Int32(($0 * 10000).rounded())) + le(Int32(10000)) }))
    }
    var pixels: [UInt8] = []
    for y in 0..<h { for x in 0..<w { for c in 0..<3 { pixels += le(UInt16(rgba[y * bytesPerRow + x * 4 + c]) * 100) } } }
    long(254, 0); long(256, w); long(257, h); short(258, [16, 16, 16]); short(259, [1]); short(262, [34892]) // LinearRaw
    long(273, 0) // strip offset, filled in below
    short(274, [orientation]); short(277, [3]); long(278, h); long(279, pixels.count); short(284, [1])
    bytes(50706, [1, 4, 0, 0]); ascii(50708, "Picasso Fixture")
    short(50717, [65535]) // white level
    ratio(50721, signed: true, [3.2406, -1.5372, -0.4986, -0.9689, 1.8758, 0.0415, 0.0557, -0.2040, 1.0570]) // XYZ → camera
    ratio(50728, signed: false, [1, 1, 1]); short(50778, [21]) // as-shot neutral, D65
    // Header, the IFD, then values over 4 bytes (word-aligned), then the pixels.
    let start = 8 + 2 + tags.count * 12 + 4
    var extra: [UInt8] = [], offsets: [Int] = []
    for t in tags {
        offsets.append(start + extra.count)
        if t.value.count > 4 { extra += t.value + (t.value.count % 2 == 1 ? [0] : []) }
    }
    var file: [UInt8] = Array("II".utf8) + le(UInt16(42)) + le(UInt32(8)) + le(UInt16(tags.count))
    for (t, offset) in zip(tags, offsets) {
        file += le(t.tag) + le(t.type) + le(UInt32(t.count))
        file += t.tag == 273 ? le(UInt32(start + extra.count))
            : t.value.count > 4 ? le(UInt32(offset)) : t.value + [UInt8](repeating: 0, count: 4 - t.value.count)
    }
    file += le(UInt32(0)) + extra + pixels
    try! Data(file).write(to: orient.appendingPathComponent(name))
}
for o in 1...8 {
    writeDNG("o\(o).dng", rgba: quadrants.data!.assumingMemoryBound(to: UInt8.self), width: 300, height: 200,
             bytesPerRow: quadrants.bytesPerRow, orientation: o)
}

// HEIF whose primary image is item 1 (as in some collections/bursts): item 0 is a decoy of another size.
let heif = CGImageDestinationCreateWithURL(out.appendingPathComponent("11-primary.heic") as CFURL,
                                           UTType.heic.identifier as CFString, 2, nil)!
CGImageDestinationAddImage(heif, draw(800, 600, "✕", "decoy item 0", hue: 0.4), nil)
CGImageDestinationAddImage(heif, draw(1200, 1800, "11", "HEIC primary item 1", hue: 0.85),
                           [kCGImagePropertyPrimaryImage: true] as CFDictionary)
precondition(CGImageDestinationFinalize(heif), "failed to write 11-primary.heic")

// Folder navigation: Finder name order, hidden files, non-images, a text file named .jpg and a subfolder.
// Each image has its own size, so a test can tell from the layout alone which one is shown.
let nav = out.appendingPathComponent("nav", isDirectory: true)
try! FileManager.default.createDirectory(at: nav.appendingPathComponent("sub"), withIntermediateDirectories: true)
let navImages: [(String, UTType)] = [
    ("img1.jpg", .jpeg), ("img2.jpg", .jpeg), ("img10.jpg", .jpeg), ("IMG_0003.JPG", .jpeg), ("Photo (2).png", .png),
    ("Photo (10).png", .png), ("éclair.heic", .heic), ("Zebra.webp", .webP),
    (".hidden.jpg", .jpeg), ("flagged.jpg", .jpeg), ("sub/inner.jpg", .jpeg), // must not be listed
]
for (i, (name, type)) in navImages.enumerated() {
    let image = draw(1200 + 40 * i, 800 + 20 * i, "N\(i + 1)", name, hue: CGFloat(i) / CGFloat(navImages.count))
    if type == .webP { writeWebP(image, name, in: nav) } else { write([image], name, type, in: nav, frame: jpeg) }
}
var flagged = nav.appendingPathComponent("flagged.jpg")
var hidden = URLResourceValues()
hidden.isHidden = true // the Finder "hidden" flag (UF_HIDDEN), not a dot name
try! flagged.setResourceValues(hidden)
try! "notes\n".write(to: nav.appendingPathComponent("notes.txt"), atomically: false, encoding: .utf8)
try! "not an image\n".write(to: nav.appendingPathComponent("fake.jpg"), atomically: false, encoding: .utf8)

// 1200 photos for the thumbnail strip: 20 distinct 2400×1600 JPEGs with embedded EXIF previews (as from a camera),
// numbered 1–20, then APFS clones of them (no extra disk space) up to photo_1200.jpg.
let many = out.appendingPathComponent("many", isDirectory: true)
try! FileManager.default.createDirectory(at: many, withIntermediateDirectories: true)
for i in 1...1200 {
    let name = String(format: "photo_%04d.jpg", i)
    if i <= 20 {
        write([draw(2400, 1600, "\(i)", "photo \(i) of 20", hue: CGFloat(i) / 20)], name, .jpeg, in: many,
              frame: jpeg.merging([kCGImageDestinationEmbedThumbnail: true]) { $1 })
    } else {
        let source = many.appendingPathComponent(String(format: "photo_%04d.jpg", (i - 1) % 20 + 1))
        precondition(clonefile(source.path, many.appendingPathComponent(name).path, 0) == 0, "clonefile failed for \(name)")
    }
}

// 90 photos with no embedded preview: 6000×4000 PNGs, whose fast thumbnail means downsampling the whole image (~50 ms,
// longer than a key repeat). 10 distinct, then APFS clones.
let plain = out.appendingPathComponent("plain", isDirectory: true)
try! FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
for i in 1...90 {
    let name = String(format: "png_%02d.png", i)
    if i <= 10 {
        write([draw(6000, 4000, "P\(i)", "6000×4000 PNG \(i) of 10", hue: CGFloat(i) / 10)], name, .png, in: plain)
    } else {
        let source = plain.appendingPathComponent(String(format: "png_%02d.png", (i - 1) % 10 + 1))
        precondition(clonefile(source.path, plain.appendingPathComponent(name).path, 0) == 0, "clonefile failed for \(name)")
    }
}

print("fixtures written to \(out.path)")
