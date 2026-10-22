import Foundation

public struct SessionFolder: Sendable, Equatable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public var transcriptURL: URL { url.appendingPathComponent("transcript.md") }
    public var stateURL: URL { url.appendingPathComponent("session.json") }
    public var shotsURL: URL { url.appendingPathComponent("shots", isDirectory: true) }
    public var audioURL: URL { url.appendingPathComponent("audio", isDirectory: true) }
    public var vocabURL: URL { url.appendingPathComponent("vocab.txt") }
    /// Kept for callers using the original Claude Code integration.
    public var feedbackCommand: String { feedbackCommand(for: .claudeCode) }

    /// A prompt for the selected coding agent, ready to paste into its chat.
    public func feedbackCommand(for agent: FeedbackAgent) -> String {
        let path = url.path
        let needsQuotes = path.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
            || path.contains("\"") || path.contains("\\")
        let argument = needsQuotes
            ? "\"\(path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
            : path
        return "\(agent.skillInvocation) \(argument)"
    }

    public static func folderName(for date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter(); f.timeZone = timeZone; f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmm"
        return f.string(from: date)
    }

    /// Creates `<root>/<yyyy-MM-dd_HHmm>[_N]/` with `shots/` and `audio/`.
    public static func create(root: URL, startedAt: Date, timeZone: TimeZone = .current,
                              fileManager: FileManager = .default) throws -> SessionFolder {
        let base = folderName(for: startedAt, timeZone: timeZone)
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base)_\(n)", isDirectory: true); n += 1
        }
        let folder = SessionFolder(url: candidate)
        try fileManager.createDirectory(at: folder.shotsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: folder.audioURL, withIntermediateDirectories: true)
        return folder
    }
}
