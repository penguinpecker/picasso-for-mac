import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Lists the images ImageIO can read in a folder, in Finder's name order.
enum FolderIndex {
    private static let readableTypes = Set(CGImageSourceCopyTypeIdentifiers() as? [String] ?? [])

    static func isSupported(_ url: URL) -> Bool {
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType else { return false }
        return type.conforms(to: .image) && readableTypes.contains(type.identifier)
    }

    static func images(in folder: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentTypeKey], options: [.skipsHiddenFiles])) ?? []
        return urls.filter(isSupported).sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }
}
