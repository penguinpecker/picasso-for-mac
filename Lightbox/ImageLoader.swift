import AppKit
import ImageIO

/// ImageIO decoding. Read-only: sources are opened without caching and nothing is ever written back.
enum ImageLoader {
    struct Decoded {
        let image: CGImage
        /// Full-resolution size with EXIF orientation applied (may exceed `image` when downsampled).
        let pixelSize: CGSize
    }

    private static let queue = DispatchQueue(label: "com.penguinpecker.Lightbox.decode", qos: .userInitiated)
    @MainActor private static var pending: DispatchWorkItem?

    /// Decodes on a background queue, calls back on the main queue (nil if the file can't be read).
    /// A new request cancels the previous one if it hasn't started, so rapid requests never build a backlog.
    @MainActor
    static func load(_ url: URL, maxPixelSize: Int, completion: @escaping @MainActor (Decoded?) -> Void) {
        pending?.cancel()
        let work = DispatchWorkItem {
            let decoded = decode(url, maxPixelSize: maxPixelSize)
            DispatchQueue.main.async { completion(decoded) }
        }
        pending = work
        queue.async(execute: work)
    }

    /// Decodes at most `maxPixelSize` on the long edge, orientation applied.
    static func decode(_ url: URL, maxPixelSize: Int) -> Decoded? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let size = orientedSize(source) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixelSize, Int(max(size.width, size.height))),
        ]
        // ponytail: for a HEIF primary at index > 0, ImageIO caps this at item 0's long edge (soft, still the
        // right picture); add a CGImageSourceCreateImageAtIndex fallback if such files turn up.
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, CGImageSourceGetPrimaryImageIndex(source),
                                                              options as CFDictionary) else { return nil }
        return Decoded(image: image, pixelSize: size)
    }

    /// Pixel size of the primary image from the header, swapped for EXIF orientations 5–8 (90° rotations).
    /// Primary, not item 0: a HEIF collection or burst may put another picture first (other formats: 0).
    static func orientedSize(_ source: CGImageSource) -> CGSize? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0 else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }
}
