import Cocoa

MainActor.assumeIsolated {
    let appDelegate = AppDelegate()

    autoreleasepool {
        let app = NSApplication.shared
        app.delegate = appDelegate
        app.run()
    }
}
