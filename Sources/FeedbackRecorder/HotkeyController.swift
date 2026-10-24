import Carbon.HIToolbox
import Foundation

/// One global hotkey through Carbon; needs no Accessibility permission.
final class HotkeyController {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void
    private let identifier: EventHotKeyID
    private static var nextID: UInt32 = 1
    var isEnabled = true
    var onDisabledPress: (() -> Void)?

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) throws {
        self.action = action
        identifier = EventHotKeyID(signature: 0x4642_524B, id: Self.nextID)
        Self.nextID &+= 1
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<HotkeyController>.fromOpaque(userData).takeUnretainedValue()
            var pressed = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed) == noErr,
                  pressed.signature == owner.identifier.signature, pressed.id == owner.identifier.id else {
                return OSStatus(eventNotHandledErr)
            }
            if owner.isEnabled { owner.action() } else { owner.onDisabledPress?() }
            return noErr
        }, 1, &eventType, selfPointer, &handlerRef)
        guard installStatus == noErr else { throw NSError(domain: "Hotkey", code: Int(installStatus)) }
        let registerStatus = RegisterEventHotKey(keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registerStatus == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            handlerRef = nil
            throw NSError(domain: "Hotkey", code: Int(registerStatus), userInfo: [NSLocalizedDescriptionKey:
                "That shortcut is unavailable or already in use. Your previous shortcut is unchanged."])
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    static func describe(keyCode: UInt32, modifiers: UInt32, displayKey: String? = nil) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        let names: [UInt32: String] = [UInt32(kVK_ANSI_R): "R", UInt32(kVK_ANSI_F): "F", UInt32(kVK_ANSI_S): "S", UInt32(kVK_Space): "Space"]
        return s + (displayKey ?? names[keyCode] ?? "Key \(keyCode)")
    }
}
