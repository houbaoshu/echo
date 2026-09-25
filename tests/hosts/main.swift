import AppKit

// Test hosts start an AppKit event loop without creating application stores,
// reading credentials, registering hot keys, or opening user windows.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.run()
