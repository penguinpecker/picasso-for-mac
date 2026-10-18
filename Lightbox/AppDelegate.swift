import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var viewer: ViewerController?
    private var didOpen = false
    private var panel: NSOpenPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        // Files from Finder arrive via application(_:open:) during launch; check on the next turn.
        // A run-loop perform (not GCD) so the open panel's modal loop still drains the main queue.
        perform(#selector(openArgumentOrPanel), with: nil, afterDelay: 0)
    }

    @objc private func openArgumentOrPanel() {
        guard !didOpen else { return }
        if let url = Self.argumentURL() { open(url) } else { showOpenPanel() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        #if SELFTEST
        SelfTest.openCalls.append(urls.map(\.path))
        #endif
        if let url = urls.first { open(url) }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Opens a file, or a folder at its first image. Reuses the one viewer window.
    func open(_ url: URL) {
        didOpen = true
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        guard let image = isFolder ? FolderIndex.images(in: url).first : url else {
            // Empty folder: ask again on a later turn. Never modally inside an odoc handler: at launch it runs
            // before applicationDidFinishLaunching (no main menu yet), and it would hold the sender's reply.
            if viewer == nil && panel == nil { perform(#selector(showOpenPanel), with: nil, afterDelay: 0) }
            return
        }
        // A Finder open can arrive while the no-file panel is up. End it, or its modal session keeps
        // swallowing the viewer's clicks and keys. Not a callout of the modal loop, so abort, not stop.
        if panel != nil { NSApp.abortModal() }
        if viewer == nil { viewer = ViewerController() }
        viewer?.show(image)
    }

    /// First existing path in argv, skipping flags and the values of -NS*/-Apple* flags.
    private static func argumentURL() -> URL? {
        var args = CommandLine.arguments.dropFirst().makeIterator()
        while let arg = args.next() {
            if arg.hasPrefix("-") {
                if arg.hasPrefix("-NS") || arg.hasPrefix("-Apple") { _ = args.next() }
                continue
            }
            if FileManager.default.fileExists(atPath: arg) { return URL(fileURLWithPath: arg).standardizedFileURL }
        }
        return nil
    }

    @objc private func showOpenPanel() {
        guard viewer == nil else { return } // a file arrived while this was queued
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image, .folder]
        panel.message = "Choose an image or a folder of images"
        #if !SELFTEST
        NSApp.activate()
        #endif
        self.panel = panel
        let response = panel.runModal()
        self.panel = nil
        if response == .OK, let url = panel.url { open(url) } else if viewer == nil { NSApp.terminate(nil) }
    }

    @objc private func closeViewer(_ sender: Any?) {
        if let viewer { viewer.close() } else { NSApp.terminate(nil) }
    }

    /// Never visible (accessory app), but provides the key equivalents.
    private func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close", action: #selector(closeViewer(_:)), keyEquivalent: "w")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Lightbox", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        // Edit items give the open panel's text fields (Go to Folder, search) ⌘X/⌘C/⌘V/⌘A.
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let menu = NSMenu()
        for submenu in [appMenu, editMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            menu.addItem(item)
        }
        return menu
    }
}
