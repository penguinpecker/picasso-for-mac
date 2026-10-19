import AppKit

MainActor.assumeIsolated {
    Settings.register()
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    #if SELFTEST
    SelfTest.install(delegate)
    #endif
    NSApplication.shared.run()
}
