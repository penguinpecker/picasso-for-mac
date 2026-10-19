import AppKit
import SwiftUI

/// UserDefaults-backed preferences. Reading never writes; only the settings window sets values.
enum Settings {
    private static let defaults = UserDefaults.standard

    static func register() {
        defaults.register(defaults: [
            "backdropOpacity": 0.75,
            "backdropStyle": "dim",
            "scrollWheelAction": "navigate",
            "showThumbnails": true,
        ])
    }

    static var backdropOpacity: Double { min(max(defaults.double(forKey: "backdropOpacity"), 0.3), 1.0) }
    static var backdropStyle: String { defaults.string(forKey: "backdropStyle") ?? "dim" }
    /// "navigate" (wheel = next/previous) or "zoom" (wheel zooms at the cursor).
    static var scrollWheelAction: String { defaults.string(forKey: "scrollWheelAction") ?? "navigate" }
    static var showThumbnails: Bool { defaults.bool(forKey: "showThumbnails") }

    private static var window: NSWindow?

    /// Opens (or focuses) the settings window, above the full-screen viewer.
    @MainActor static func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Settings"
            w.styleMask = [.titled, .closable]
            w.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            w.isReleasedWhenClosed = false
            window = w
        }
        window?.center()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    @AppStorage("backdropOpacity") private var opacity = 0.75
    @AppStorage("backdropStyle") private var style = "dim"
    @AppStorage("scrollWheelAction") private var wheel = "navigate"
    @AppStorage("showThumbnails") private var thumbnails = true

    var body: some View {
        Form {
            Slider(value: $opacity, in: 0.3...1) {
                Text("Backdrop opacity")
            } minimumValueLabel: { Text("30%") } maximumValueLabel: { Text("100%") }
            Picker("Backdrop style", selection: $style) {
                Text("Dim").tag("dim")
                Text("Blur").tag("blur")
            }
            .pickerStyle(.segmented)
            Picker("Scroll wheel", selection: $wheel) {
                Text("Next / previous").tag("navigate")
                Text("Zoom").tag("zoom")
            }
            Toggle("Show thumbnail strip", isOn: $thumbnails)
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize()
    }
}

extension UserDefaults {
    // Named like their keys, for KVO (which also hears `defaults write` from other processes).
    @objc dynamic var showThumbnails: Bool { bool(forKey: "showThumbnails") }
    @objc dynamic var backdropOpacity: Double { double(forKey: "backdropOpacity") }
    @objc dynamic var backdropStyle: String? { string(forKey: "backdropStyle") }
}
