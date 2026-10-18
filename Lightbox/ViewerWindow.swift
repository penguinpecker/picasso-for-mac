import AppKit

/// Borderless windows refuse key status by default; the viewer needs it for keyboard input.
final class ViewerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
