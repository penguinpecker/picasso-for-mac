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
write([draw(1600, 1200, "6", "1600×1200 WebP", hue: 0.15)], "06-photo.png", .png, in: scratch)
let cwebp = Process()
cwebp.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/cwebp")
cwebp.arguments = ["-quiet", "-q", "85", scratch.appendingPathComponent("06-photo.png").path,
                   "-o", out.appendingPathComponent("06-photo.webp").path]
try! cwebp.run()
cwebp.waitUntilExit()
precondition(cwebp.terminationStatus == 0, "cwebp failed")

write([draw(1500, 1000, "7", "1500×1000 TIFF", hue: 0.5)], "07-photo.tiff", .tiff)
write([draw(1200, 900, "8", "1200×900 BMP", hue: 0.66)], "08-photo.bmp", .bmp)

let frames = (1...3).map { draw(600, 400, "9", "GIF frame \($0)/3", hue: CGFloat($0) / 4) }
write(frames, "09-anim.gif", .gif,
      file: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]],
      frame: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.4]])

write([draw(12000, 8000, "10", "12000×8000 JPEG", hue: 0.02)], "10-huge.jpg", .jpeg, frame: jpeg)

// HEIF whose primary image is item 1 (as in some collections/bursts): item 0 is a decoy of another size.
let heif = CGImageDestinationCreateWithURL(out.appendingPathComponent("11-primary.heic") as CFURL,
                                           UTType.heic.identifier as CFString, 2, nil)!
CGImageDestinationAddImage(heif, draw(800, 600, "✕", "decoy item 0", hue: 0.4), nil)
CGImageDestinationAddImage(heif, draw(1200, 1800, "11", "HEIC primary item 1", hue: 0.85),
                           [kCGImagePropertyPrimaryImage: true] as CFDictionary)
precondition(CGImageDestinationFinalize(heif), "failed to write 11-primary.heic")

print("fixtures written to \(out.path)")
