import Foundation

public struct RecordingShortcut: Sendable, Equatable {
    public let keyCode: UInt32
    public let modifiers: UInt32
    public init(keyCode: UInt32, modifiers: UInt32) throws {
        // Carbon modifier bits. Exclude caps lock and function flags from the stored combination.
        let command: UInt32 = 1 << 8, shift: UInt32 = 1 << 9
        let option: UInt32 = 1 << 11, control: UInt32 = 1 << 12
        let clean = modifiers & (command | shift | option | control)
        guard keyCode <= 127, keyCode != 53,
              clean & (command | control) != 0, clean.nonzeroBitCount >= 2 else { throw InvalidShortcut() }
        self.keyCode = keyCode
        self.modifiers = clean
    }

    public struct InvalidShortcut: LocalizedError {
        public var errorDescription: String? {
            "Use Command or Control together with another modifier and a key. Escape cancels."
        }
    }
}
