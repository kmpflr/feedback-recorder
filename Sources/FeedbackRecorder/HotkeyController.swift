import Carbon.HIToolbox
import Foundation

/// One global hotkey through Carbon; needs no Accessibility permission.
final class HotkeyController {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) throws {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData -> OSStatus in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            Unmanaged<HotkeyController>.fromOpaque(userData).takeUnretainedValue().action()
            return noErr
        }, 1, &eventType, selfPointer, &handlerRef)
        guard installStatus == noErr else { throw NSError(domain: "Hotkey", code: Int(installStatus)) }
        let hotKeyID = EventHotKeyID(signature: 0x4642_524B /* FBRK */, id: 1)
        let registerStatus = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registerStatus == noErr else { throw NSError(domain: "Hotkey", code: Int(registerStatus)) }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    static func describe(keyCode: UInt32, modifiers: UInt32) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        let names: [UInt32: String] = [UInt32(kVK_ANSI_R): "R", UInt32(kVK_ANSI_F): "F", UInt32(kVK_ANSI_S): "S", UInt32(kVK_Space): "Space"]
        return s + (names[keyCode] ?? "key\(keyCode)")
    }
}
