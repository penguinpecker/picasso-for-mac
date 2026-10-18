import Foundation

/// UserDefaults-backed preferences. Reading never writes; only the settings window (later) sets values.
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
}
