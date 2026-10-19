// Draws the app icon and writes Picasso/AppIcon.icns + docs/icon.png.
//   swiftc -O Scripts/make-icon.swift -o /tmp/make-icon && /tmp/make-icon <repo root>
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func gradient(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

/// A photo print: white border, sunset landscape inside.
func photo(_ ctx: CGContext, center: CGPoint, size: CGSize, angle: CGFloat, dim: Bool) {
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: angle * .pi / 180)
    let card = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: color(0x000000, 0.55))
    ctx.addPath(CGPath(roundedRect: card, cornerWidth: 26, cornerHeight: 26, transform: nil))
    ctx.setFillColor(color(dim ? 0xC9CCE0 : 0xFBFAF7))
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0)
    let pic = card.insetBy(dx: 26, dy: 26)
    ctx.addPath(CGPath(roundedRect: pic, cornerWidth: 12, cornerHeight: 12, transform: nil))
    ctx.clip()
    if dim {
        gradient(ctx, [color(0x5B6BB5), color(0x2E3A78)], from: CGPoint(x: 0, y: pic.maxY), to: CGPoint(x: 0, y: pic.minY))
    } else {
        // Sky
        gradient(ctx, [color(0xFFB35C), color(0xFF6F7D), color(0x8C5BE8)],
                 from: CGPoint(x: 0, y: pic.minY), to: CGPoint(x: 0, y: pic.maxY))
        // Sun
        let sun = CGRect(x: pic.midX + 40, y: pic.minY + pic.height * 0.38, width: 120, height: 120)
        ctx.setFillColor(color(0xFFE3A3))
        ctx.fillEllipse(in: sun)
        ctx.setFillColor(color(0xFFE3A3, 0.25))
        ctx.fillEllipse(in: sun.insetBy(dx: -26, dy: -26))
        // Mountains, far then near
        func ridge(_ pts: [(CGFloat, CGFloat)], _ c: CGColor) {
            ctx.beginPath()
            ctx.move(to: CGPoint(x: pic.minX - 10, y: pic.minY - 10))
            for (x, y) in pts { ctx.addLine(to: CGPoint(x: pic.minX + pic.width * x, y: pic.minY + pic.height * y)) }
            ctx.addLine(to: CGPoint(x: pic.maxX + 10, y: pic.minY - 10))
            ctx.closePath()
            ctx.setFillColor(c)
            ctx.fillPath()
        }
        ridge([(0, 0.42), (0.18, 0.62), (0.34, 0.47), (0.55, 0.70), (0.78, 0.44), (1, 0.56)], color(0x6A3F8F))
        ridge([(0, 0.20), (0.22, 0.40), (0.42, 0.24), (0.66, 0.46), (0.86, 0.28), (1, 0.34)], color(0x2B1E52))
    }
    ctx.restoreGState()
}

func drawIcon(px: Int) -> CGImage {
    let s = CGFloat(px) / 1024
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s, y: s)
    ctx.interpolationQuality = .high
    // macOS icon grid: 824 pt body, 100 pt margin, soft drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(squircle); ctx.setFillColor(color(0x10142B)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    // The viewer's translucent dark backdrop, with a faint glow behind the photo.
    gradient(ctx, [color(0x262C55), color(0x0B0E1F)], from: CGPoint(x: 0, y: body.maxY), to: CGPoint(x: 0, y: body.minY))
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [color(0xFF8A7A, 0.45), color(0xFF8A7A, 0)] as CFArray, locations: nil)!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 540), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 540), endRadius: 420, options: [])
    photo(ctx, center: CGPoint(x: 540, y: 560), size: CGSize(width: 520, height: 390), angle: 9, dim: true)
    photo(ctx, center: CGPoint(x: 500, y: 530), size: CGSize(width: 560, height: 420), angle: -5, dim: false)
    // Thumbnail-strip hint along the bottom.
    for i in 0..<5 {
        let r = CGRect(x: 302 + CGFloat(i) * 86, y: 196, width: 70, height: 50)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 10, cornerHeight: 10, transform: nil))
        ctx.setFillColor(color(0xFFFFFF, i == 2 ? 0.92 : 0.22))
        ctx.fillPath()
    }
    // Top sheen + hairline edge.
    gradient(ctx, [color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)], from: CGPoint(x: 0, y: body.maxY), to: CGPoint(x: 0, y: body.midY))
    ctx.restoreGState()
    ctx.addPath(squircle); ctx.setStrokeColor(color(0xFFFFFF, 0.12)); ctx.setLineWidth(3); ctx.strokePath()
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, _ url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    writePNG(drawIcon(px: base), iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(drawIcon(px: base * 2), iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
writePNG(drawIcon(px: 1024), root.appendingPathComponent("docs/icon.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Picasso/AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "ok" : "iconutil failed")
