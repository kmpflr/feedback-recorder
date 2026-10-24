import Foundation
import Testing
@testable import FeedbackCore

@Test func chosenStorageCreatesMissingFolderWithoutLeavingProbeFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fr-storage-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let nested = root.appendingPathComponent("Reviews/Sessions")
    try SessionStorage.prepare(nested)
    #expect(try FileManager.default.contentsOfDirectory(atPath: nested.path).isEmpty)
}

@Test func choosingStoragePreservesExistingRecordings() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fr-storage-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let transcript = root.appendingPathComponent("transcript.md")
    try Data("A synthetic recording".utf8).write(to: transcript)
    try SessionStorage.prepare(root)
    #expect(try String(contentsOf: transcript, encoding: .utf8) == "A synthetic recording")
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["transcript.md"])
}

@Test func storageRejectsAFileInsteadOfADirectory() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("fr-storage-\(UUID())")
    defer { try? FileManager.default.removeItem(at: file) }
    try Data("Keep this file".utf8).write(to: file)
    #expect(throws: (any Error).self) { try SessionStorage.prepare(file) }
    #expect(try String(contentsOf: file, encoding: .utf8) == "Keep this file")
}
