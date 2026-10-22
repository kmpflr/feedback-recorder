import Foundation
import Testing
@testable import FeedbackCore

private func session(in root: URL, name: String, state: RecordingState, startedAt: Date) throws -> SessionFolder {
    let folder = SessionFolder(url: root.appendingPathComponent(name, isDirectory: true))
    try FileManager.default.createDirectory(at: folder.shotsURL, withIntermediateDirectories: true)
    var s = SessionState(startedAt: startedAt, mode: .call, input: InputDevice(name: "x", uid: "x"), systemAudio: true,
                         engine: EngineInfo(name: "apple-speech", module: "SpeechTranscriber", locale: "en-US"), appVersion: "t")
    if state == .stopped { s.stop(reason: .user, at: startedAt.addingTimeInterval(60)) }
    try SessionState.encoder.encode(s).write(to: folder.stateURL)
    return folder
}

@Test func marksRecordingSessionsAsCrashedAndLeavesStoppedOnesAlone() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fr-recover-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let orphan = try session(in: root, name: "2026-09-02_1000", state: .recording, startedAt: Date(timeIntervalSince1970: 1000))
    let done = try session(in: root, name: "2026-09-02_0900", state: .stopped, startedAt: Date(timeIntervalSince1970: 500))
    try Data("junk".utf8).write(to: root.appendingPathComponent("notes.txt"))   // non-session entry is ignored
    let now = Date(timeIntervalSince1970: 5000)
    let recovered = try SessionRecovery.recoverOrphans(root: root, now: now)
    #expect(recovered == [orphan.url])
    let s = try SessionState.decoder.decode(SessionState.self, from: Data(contentsOf: orphan.stateURL))
    #expect(s.state == .stopped && s.stopReason == .crash && s.stoppedAt == now)
    let d = try SessionState.decoder.decode(SessionState.self, from: Data(contentsOf: done.stateURL))
    #expect(d.stopReason == .user)
    #expect(SessionRecovery.newestSession(root: root)?.url == orphan.url)
}
