import Foundation

public enum Channel: String, Sendable, Codable, CaseIterable, Hashable {
    case me, them, room
    public var label: String {
        switch self { case .me: "Me"; case .them: "Them"; case .room: "Room" }
    }
}

public struct TranscriptSegment: Sendable, Equatable {
    public var channel: Channel
    public var start: TimeInterval   // seconds from session start
    public var end: TimeInterval
    public var text: String
    public init(channel: Channel, start: TimeInterval, end: TimeInterval, text: String) {
        self.channel = channel; self.start = start; self.end = end; self.text = text
    }
}

extension TranscriptSegment {
    /// Marks a segment an engine yields in place of speech when its own result stream fails.
    /// `TranscriptionEngine` gains no separate error channel for this: an engine reports the
    /// failure on the stream it already owns, and `SessionController` recognises the prefix and
    /// writes the segment as a note line rather than a speaker turn.
    public static let engineErrorPrefix = "(transcription stopped:"

    /// A pseudo-segment carrying `message`, stamped at `time` in that channel's analyzer clock so
    /// the note lands where transcription stopped instead of at the start of the session.
    public static func engineError(channel: Channel, at time: TimeInterval, message: String) -> TranscriptSegment {
        TranscriptSegment(channel: channel, start: time, end: time, text: "\(engineErrorPrefix) \(message))")
    }

    public var isEngineError: Bool { text.hasPrefix(Self.engineErrorPrefix) }

    /// The engine-error text without the parentheses the note renderer adds back.
    public var engineErrorNoteText: String {
        var stripped = text
        if stripped.hasPrefix("(") { stripped.removeFirst() }
        if stripped.hasSuffix(")") { stripped.removeLast() }
        return stripped
    }
}

public struct ScreenshotEvent: Sendable, Equatable {
    public var index: Int
    public var time: TimeInterval
    public var relativePath: String   // "shots/001.png"
    public init(index: Int, time: TimeInterval, relativePath: String) {
        self.index = index; self.time = time; self.relativePath = relativePath
    }
}

public struct NoteEvent: Sendable, Equatable {
    public var time: TimeInterval
    public var text: String
    public init(time: TimeInterval, text: String) { self.time = time; self.text = text }
}

public enum TranscriptEvent: Sendable, Equatable {
    case turn(TranscriptSegment)
    case shot(ScreenshotEvent)
    case note(NoteEvent)

    public var time: TimeInterval {
        switch self {
        case .turn(let s): s.start
        case .shot(let e): e.time
        case .note(let n): n.time
        }
    }
}
