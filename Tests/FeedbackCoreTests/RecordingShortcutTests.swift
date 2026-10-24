import Testing
@testable import FeedbackCore

@Test func recordingShortcutRejectsTypingKeysAndEscape() throws {
    #expect(throws: RecordingShortcut.InvalidShortcut.self) { try RecordingShortcut(keyCode: 15, modifiers: 0) }
    #expect(throws: RecordingShortcut.InvalidShortcut.self) { try RecordingShortcut(keyCode: 15, modifiers: 1 << 8) }
    #expect(throws: RecordingShortcut.InvalidShortcut.self) { try RecordingShortcut(keyCode: 15, modifiers: (1 << 9) | (1 << 11)) }
    #expect(throws: RecordingShortcut.InvalidShortcut.self) { try RecordingShortcut(keyCode: 53, modifiers: (1 << 8) | (1 << 12)) }
    #expect(throws: RecordingShortcut.InvalidShortcut.self) { try RecordingShortcut(keyCode: 300, modifiers: (1 << 8) | (1 << 12)) }
}

@Test func recordingShortcutKeepsUsefulModifiersAndDiscardsCapsLock() throws {
    let flags: UInt32 = (1 << 8) | (1 << 11) | (1 << 12)
    let shortcut = try RecordingShortcut(keyCode: 15, modifiers: flags | (1 << 10))
    #expect(shortcut.keyCode == 15 && shortcut.modifiers == flags)
}
