import Foundation
import Testing
@testable import FeedbackCore

private func savedSession(root: URL, at seconds: TimeInterval) throws -> SessionFolder {
    let folder = try SessionFolder.create(root: root, startedAt: Date(timeIntervalSince1970: seconds))
    var state = SessionState(startedAt: Date(timeIntervalSince1970: seconds), mode: .call,
        input: InputDevice(name: "Synthetic microphone", uid: "fixture"), systemAudio: true,
        engine: EngineInfo(name: "fixture", module: "fixture", locale: "en-US"), appVersion: "test")
    state.stop(reason: .user, at: state.startedAt.addingTimeInterval(60))
    try SessionState.encoder.encode(state).write(to: folder.stateURL)
    return folder
}

@Test func libraryFindsPreviousLocationsAndDeduplicatesRoots() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fr-library-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let previous = root.appendingPathComponent("previous"), current = root.appendingPathComponent("current")
    let old = try savedSession(root: previous, at: 1000)
    let new = try savedSession(root: current, at: 2000)
    let result = SessionLibrary.load(roots: [previous, current, previous, root.appendingPathComponent("missing")])
    #expect(result.sessions.map(\.folder) == [new, old])
    #expect(result.warnings.isEmpty)
}

@Test func renamingKeepsSessionPathsAndMetadataUnchanged() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fr-library-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = try savedSession(root: root, at: 1000)
    let original = try Data(contentsOf: folder.stateURL)
    let command = folder.feedbackCommand(for: .codex)
    try SessionLibrary.rename(folder, to: "  Checkout review  ")
    let session = try #require(SessionLibrary.load(roots: [root]).sessions.first)
    #expect(session.name == "Checkout review")
    #expect(try Data(contentsOf: folder.stateURL) == original)
    #expect(session.folder.feedbackCommand(for: .codex) == command)
    #expect(session.matches("checkout MICROPHONE"))
    #expect(!session.matches("checkout missing"))
    // Renaming does not open or require audio/transcript files.
    #expect(!FileManager.default.fileExists(atPath: folder.transcriptURL.path))
}

@Test func libraryReportsCorruptMetadataWithoutHidingValidSessions() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fr-library-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let valid = try savedSession(root: root, at: 1000)
    let corrupt = try savedSession(root: root, at: 2000)
    try Data("invalid json".utf8).write(to: corrupt.stateURL)
    let result = SessionLibrary.load(roots: [root])
    #expect(result.sessions.map(\.folder) == [valid])
    #expect(result.warnings.count == 1)
    #expect(throws: (any Error).self) { try SessionLibrary.rename(valid, to: "\n ") }
    #expect(throws: (any Error).self) { try SessionLibrary.rename(valid, to: String(repeating: "a", count: 121)) }
}
