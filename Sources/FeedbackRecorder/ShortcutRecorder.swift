import AppKit
import SwiftUI
import FeedbackCore

struct ShortcutRecorder: NSViewRepresentable {
    let label: String
    let onChange: (RecordingShortcut, String?) throws -> Void
    let onCapture: (Bool) -> Void
    let onError: (String) -> Void

    func makeNSView(context: Context) -> ShortcutButton {
        let button = ShortcutButton()
        button.bezelStyle = .rounded
        button.target = button
        button.action = #selector(ShortcutButton.beginCapture(_:))
        button.setAccessibilityLabel("Recording shortcut. Click to change.")
        button.toolTip = "Click, then press a shortcut. Escape cancels."
        updateNSView(button, context: context)
        return button
    }
    func updateNSView(_ button: ShortcutButton, context: Context) {
        button.currentLabel = label
        button.onChange = onChange; button.onCapture = onCapture; button.onError = onError
        if !button.capturing { button.title = label }
    }
    static func dismantleNSView(_ button: ShortcutButton, coordinator: ()) { button.endCapture() }
}

final class ShortcutButton: NSButton {
    var onChange: ((RecordingShortcut, String?) throws -> Void)?
    var onCapture: ((Bool) -> Void)?
    var onError: ((String) -> Void)?
    var currentLabel = ""
    private(set) var capturing = false
    private var resignObserver: NSObjectProtocol?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        if let window {
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                object: window, queue: .main) { [weak self] _ in self?.endCapture() }
        } else { endCapture() }
    }
    deinit { if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) } }
    override var acceptsFirstResponder: Bool { true }

    @objc func beginCapture(_ sender: Any?) {
        guard !capturing, window?.makeFirstResponder(self) == true else { return }
        capturing = true
        title = "Press shortcut…"
        onCapture?(true)
    }
    func endCapture() {
        guard capturing else { return }
        capturing = false
        title = currentLabel
        onCapture?(false)
    }
    override func resignFirstResponder() -> Bool { endCapture(); return super.resignFirstResponder() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if capturing { capture(event); return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if capturing { capture(event) } else { super.keyDown(with: event) }
    }
    private func capture(_ event: NSEvent) {
        if event.keyCode == 53 { endCapture(); return }
        var carbon: UInt32 = 0
        if event.modifierFlags.contains(.command) { carbon |= 1 << 8 }
        if event.modifierFlags.contains(.shift) { carbon |= 1 << 9 }
        if event.modifierFlags.contains(.option) { carbon |= 1 << 11 }
        if event.modifierFlags.contains(.control) { carbon |= 1 << 12 }
        let special: [UInt16: String] = [36: "Return", 48: "Tab", 49: "Space", 51: "Delete",
                                        123: "←", 124: "→", 125: "↓", 126: "↑"]
        let key = special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased()
        defer { endCapture() }
        do {
            let shortcut = try RecordingShortcut(keyCode: UInt32(event.keyCode), modifiers: carbon)
            try onChange?(shortcut, key)
        } catch { onError?(error.localizedDescription) }
    }
}
