import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Lists the images ImageIO can read in a folder, in Finder's name order.
enum FolderIndex {
    private static let readableTypes = Set(CGImageSourceCopyTypeIdentifiers() as? [String] ?? [])

    /// A regular file whose extension names an image type ImageIO can decode (RAW included where supported).
    static func isSupported(_ url: URL) -> Bool {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
              let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) && readableTypes.contains(type.identifier)
    }

    /// Non-recursive, visible files only.
    static func images(in folder: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        // Names extracted once: URL.lastPathComponent inside the comparator was most of the sort time.
        return urls.filter(isSupported).map { ($0.lastPathComponent, $0) }.sorted { precedes($0.0, $1.0) }.map(\.1)
    }

    /// The images of a file's folder and the file's index in them; a folder starts at its first image (nil if empty).
    /// A file the listing skips (hidden, unknown type) is slotted in by name so it still opens.
    static func open(_ url: URL) -> (images: [URL], index: Int)? {
        // Resource values describe a symlink itself: follow it, so a link to a folder (argv, open -a) opens the folder.
        let url = url.resolvingSymlinksInPath()
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let images = Self.images(in: url)
            return images.isEmpty ? nil : (images, 0)
        }
        var images = Self.images(in: url.deletingLastPathComponent())
        // The on-disk name: a wrong-case path on a case-insensitive volume must match its listed file.
        let name = (try? url.resourceValues(forKeys: [.nameKey]))?.name ?? url.lastPathComponent
        if let i = images.firstIndex(where: { $0.lastPathComponent == name }) { return (images, i) }
        let i = images.firstIndex { precedes(name, $0.lastPathComponent) } ?? images.count
        images.insert(url, at: i)
        return (images, i)
    }

    private static func precedes(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedAscending
    }
}
