import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate: AppDelegate
#if DEBUG
// A separately identified local QA bundle can isolate all support files. The
// production bundle never accepts this argument or changes its storage root.
if Bundle.main.bundleIdentifier == "com.felix.lamitype.localLiveQA" {
    let support = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("support", isDirectory: true)
    delegate = AppDelegate(appSupportDirectory: support)
} else { delegate = AppDelegate() }
#else
delegate = AppDelegate()
#endif
app.delegate = delegate
app.run()
