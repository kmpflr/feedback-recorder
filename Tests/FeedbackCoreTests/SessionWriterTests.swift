import Foundation
import Testing
@testable import FeedbackCore

private func makeWriter(debounce: Duration = .zero) throws -> (SessionWriter, SessionFolder) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fr-writer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let started = Date(timeIntervalSince1970: 1_756_830_612)
    let folder = try SessionFolder.create(root: root, startedAt: started, timeZone: TimeZone(identifier: "UTC")!)
    let header = SessionHeader.make(startedAt: started, mode: .call, inputName: "Jabra", timeZone: TimeZone(identifier: "UTC")!)
    let state = SessionState(startedAt: started, mode: .call, input: InputDevice(name: "Jabra", uid: "u"), systemAudio: true,
                             engine: EngineInfo(name: "apple-speech", module: "SpeechTranscriber", locale: "en-US"), appVersion: "test")
    return (SessionWriter(folder: folder, header: header, state: state, debounce: debounce), folder)
}

@Test func startWritesHeaderOnlyTranscriptAndRecordingState() async throws {
    let (writer, folder) = try makeWriter()
    try await writer.start()
    let transcript = try String(contentsOf: folder.transcriptURL, encoding: .utf8)
    #expect(transcript.hasPrefix("# Feedback session 2025-09-02 16:30\n"))
    #expect(!transcript.contains("["))
    let state = try SessionState.decoder.decode(SessionState.self, from: Data(contentsOf: folder.stateURL))
    #expect(state.state == .recording)
}

@Test func appendFlushesEventsAndCountsWithZeroDebounce() async throws {
    let (writer, folder) = try makeWriter()
    try await writer.start()
    await writer.append(.turn(TranscriptSegment(channel: .them, start: 12, end: 15, text: "Hello.")))
    await writer.append(.shot(ScreenshotEvent(index: 1, time: 20, relativePath: "shots/001.png")))
    try await writer.flush()
    let transcript = try String(contentsOf: folder.transcriptURL, encoding: .utf8)
    #expect(transcript.hasSuffix("[00:12] Them: Hello.\n[00:20] ![shot 001](shots/001.png)\n"))
    let state = try SessionState.decoder.decode(SessionState.self, from: Data(contentsOf: folder.stateURL))
    #expect(state.counts.segments == 1 && state.counts.shots == 1)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.url.path).filter { $0.contains("tmp") }
    #expect(leftovers.isEmpty)
}

@Test func debouncedFlushLandsWithoutExplicitFlush() async throws {
    let (writer, folder) = try makeWriter(debounce: .milliseconds(50))
    try await writer.start()
    await writer.append(.turn(TranscriptSegment(channel: .me, start: 1, end: 2, text: "One.")))
    await writer.append(.turn(TranscriptSegment(channel: .me, start: 2.5, end: 3, text: "Two.")))
    await waitUntil {
        (try? String(contentsOf: folder.transcriptURL, encoding: .utf8))?.hasSuffix("[00:01] Me: One. Two.\n") == true
    }
    let transcript = try String(contentsOf: folder.transcriptURL, encoding: .utf8)
    #expect(transcript.hasSuffix("[00:01] Me: One. Two.\n"))
}

@Test func stopWritesStoppedStateWithReasonAndDuration() async throws {
    let (writer, folder) = try makeWriter()
    try await writer.start()
    try await writer.stop(reason: .user, at: Date(timeIntervalSince1970: 1_756_830_612 + 90))
    let state = try SessionState.decoder.decode(SessionState.self, from: Data(contentsOf: folder.stateURL))
    #expect(state.state == .stopped && state.stopReason == .user && state.durationSeconds == 90)
}

@Test func continuousEventsStillReachDiskBeforeTheStreamStops() async throws {
    let (writer, folder) = try makeWriter(debounce: .milliseconds(100))
    defer { try? FileManager.default.removeItem(at: folder.url.deletingLastPathComponent()) }
    try await writer.start()
    let producer = Task {
        for n in 0..<150 {
            if Task.isCancelled { break }
            await writer.append(.note(NoteEvent(time: Double(n), text: "Continuous event")))
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
    let flushed = await waitUntil(.seconds(1)) {
        (try? String(contentsOf: folder.transcriptURL, encoding: .utf8))?.contains("Continuous event") == true
    }
    producer.cancel()
    await producer.value
    try await writer.stop(reason: .user, at: Date())
    #expect(flushed)
}
