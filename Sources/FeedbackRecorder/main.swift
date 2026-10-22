import AppKit

// Top-level code is nonisolated, so constructing the main-actor `AppDelegate` needs the isolation
// asserted. main.swift already runs on the main thread, so the assertion holds.
//
// The delegate is a global on purpose: `NSApplication.delegate` is a non-owning reference, so a
// local binding inside the run closure below would be the delegate's only owner. A global lives
// for the process, which outlives `app.run()`.
let delegate = MainActor.assumeIsolated { AppDelegate() }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
