import Foundation

public enum SessionMode: String, Sendable, Codable {
    case call, room
    public var transcriptDescription: String {
        switch self {
        case .call: "call (Me = microphone, Them = system audio)"
        case .room: "room (single microphone, both voices)"
        }
    }
    public var channels: [Channel] { self == .call ? [.me, .them] : [.room] }
}

public struct SessionHeader: Sendable, Equatable {
    public var title: String        // "Feedback session 2026-09-02 14:30"
    public var mode: SessionMode
    public var inputName: String
    public var startedText: String  // "2026-09-02 14:30:12"
    public init(title: String, mode: SessionMode, inputName: String, startedText: String) {
        self.title = title; self.mode = mode; self.inputName = inputName; self.startedText = startedText
    }

    public static func make(startedAt: Date, mode: SessionMode, inputName: String, timeZone: TimeZone = .current) -> SessionHeader {
        let f = DateFormatter(); f.timeZone = timeZone; f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let title = "Feedback session \(f.string(from: startedAt))"
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return SessionHeader(title: title, mode: mode, inputName: inputName, startedText: f.string(from: startedAt))
    }
}
