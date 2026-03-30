import AppKit

// Skip app startup when running under XCTest to allow @testable import
if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
    let app = NSApplication.shared

    // Singleton guard: terminate if another instance is already running
    let bundleID = Bundle.main.bundleIdentifier ?? "com.meorthem.app"
    if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
        app.terminate(nil)
    }

    app.setActivationPolicy(.accessory)   // no Dock icon
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
