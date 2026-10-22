import Foundation
import Testing
@testable import FeedbackCore

private func tempRoot() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("fr-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func folderNameHasNoSpaces() {
    let date = Date(timeIntervalSince1970: 1_756_830_612)  // 16:30:12Z
    #expect(SessionFolder.folderName(for: date, timeZone: TimeZone(identifier: "UTC")!) == "2025-09-02_1630")
}

@Test func createMakesSubfoldersAndSuffixesOnCollision() throws {
    let root = tempRoot()
    let date = Date(timeIntervalSince1970: 1_756_830_612)
    let utc = TimeZone(identifier: "UTC")!
    let first = try SessionFolder.create(root: root, startedAt: date, timeZone: utc)
    let second = try SessionFolder.create(root: root, startedAt: date, timeZone: utc)
    #expect(first.url.lastPathComponent == "2025-09-02_1630")
    #expect(second.url.lastPathComponent == "2025-09-02_1630_2")
    var isDir: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: first.shotsURL.path, isDirectory: &isDir) && isDir.boolValue)
    #expect(FileManager.default.fileExists(atPath: first.audioURL.path, isDirectory: &isDir) && isDir.boolValue)
    #expect(first.feedbackCommand == "/feedback \(first.url.path)")
    #expect(first.transcriptURL.lastPathComponent == "transcript.md")
    #expect(first.stateURL.lastPathComponent == "session.json")
}

@Test func feedbackCommandQuotesAPathContainingWhitespace() {
    let plain = SessionFolder(url: URL(fileURLWithPath: "/Users/x/FeedbackSessions/2026-09-02_1430"))
    #expect(plain.feedbackCommand == "/feedback /Users/x/FeedbackSessions/2026-09-02_1430")
    let spaced = SessionFolder(url: URL(fileURLWithPath: "/Users/x/Feedback Sessions/2026-09-02_1430"))
    #expect(spaced.feedbackCommand == "/feedback \"/Users/x/Feedback Sessions/2026-09-02_1430\"")
}
