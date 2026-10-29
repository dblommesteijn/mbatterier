import AppKit

// LSUIElement in Info.plist keeps this out of the Dock and the app switcher;
// .accessory says the same thing at runtime, for the case where the binary is
// run directly out of the build directory rather than from the bundle.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
