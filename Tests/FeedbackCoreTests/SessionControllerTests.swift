import AVFAudio
import Foundation
import Testing
@testable import FeedbackCore

// MARK: fakes

private let fmt = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

/// What the real speech engine asks for: 16 kHz mono signed 16-bit integer samples.
private let int16Fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!

private func chunk(_ ch: Channel, hostTime: UInt64, level: Float) -> AudioChunk {
    let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1600)!; b.frameLength = 1600
    for i in 0..<1600 { b.floatChannelData![0][i] = level }
    return AudioChunk(channel: ch, buffer: b, hostTime: hostTime)
}

private func int16Chunk(_ ch: Channel, hostTime: UInt64, sample: Int16) -> AudioChunk {
    let b = AVAudioPCMBuffer(pcmFormat: int16Fmt, frameCapacity: 1600)!; b.frameLength = 1600
    for i in 0..<1600 { b.int16ChannelData![0][i] = sample }
    return AudioChunk(channel: ch, buffer: b, hostTime: hostTime)
}

private func rawChunk(_ ch: Channel, format: AVAudioFormat, frameCount: AVAudioFrameCount, hostTime: UInt64, level: Float) -> AudioChunk {
    let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!; b.frameLength = frameCount
    if let data = b.floatChannelData {
        for channel in 0..<Int(format.channelCount) {
            for i in 0..<Int(frameCount) { data[channel][i] = level }
        }
    }
    return AudioChunk(channel: ch, buffer: b, hostTime: hostTime)
}

private final class FakeSource: AudioSource, @unchecked Sendable {
    let chunks: [AudioChunk]
    var stopped = false
    init(_ chunks: [AudioChunk]) { self.chunks = chunks }
    func start() async throws -> AsyncStream<AudioChunk> {
        AsyncStream { c in for ch in chunks { c.yield(ch) } }      // stream stays open until stop()
    }
    func stop() async { stopped = true }
}

private final class FakeEngine: TranscriptionEngine, @unchecked Sendable {
    var continuation: AsyncStream<TranscriptSegment>.Continuation?
    var fed: [Channel: Int] = [:]
    var framesFed: [Channel: Int] = [:]
    var finished = false
    var startedWithVocabulary: [String]?
    let format: AVAudioFormat
    init(format: AVAudioFormat = fmt) { self.format = format }
    func preferredFormat() async -> AVAudioFormat { format }
    func start(channels: [Channel], vocabulary: [String]) async throws -> AsyncStream<TranscriptSegment> {
        startedWithVocabulary = vocabulary
        return AsyncStream { self.continuation = $0 }
    }
    func feed(_ chunk: AudioChunk) async {
        fed[chunk.channel, default: 0] += 1
        framesFed[chunk.channel, default: 0] += Int(chunk.buffer.frameLength)
    }
    func finish() async throws {
        finished = true
        continuation?.yield(TranscriptSegment(channel: .them, start: 1, end: 2, text: "Final words."))
        continuation?.finish()
    }
}

/// Models a real `SpeechAnalyzer`: `feed` only enqueues the buffer for a worker thread that
/// consumes it later, on its own schedule, with no promise that the caller's copy stays readable
/// afterward. `handle` must be done reading a buffer — for the RMS level, for the track write —
/// before it calls `feed`, not after.
private final class BufferConsumingEngine: TranscriptionEngine, @unchecked Sendable {
    var continuation: AsyncStream<TranscriptSegment>.Continuation?
    let format: AVAudioFormat
    init(format: AVAudioFormat) { self.format = format }
    func preferredFormat() async -> AVAudioFormat { format }
    func start(channels: [Channel], vocabulary: [String]) async throws -> AsyncStream<TranscriptSegment> {
        AsyncStream { self.continuation = $0 }
    }
    func feed(_ chunk: AudioChunk) async { chunk.buffer.frameLength = 0 }
    func finish() async throws { continuation?.finish() }
}

/// `finish()` throws, which is how a real analyzer reports that it could not finalise.
private final class ThrowingFinishEngine: TranscriptionEngine, @unchecked Sendable {
    struct Failure: LocalizedError { var errorDescription: String? { "analyzer died" } }
    func preferredFormat() async -> AVAudioFormat { fmt }
    func start(channels: [Channel], vocabulary: [String]) async throws -> AsyncStream<TranscriptSegment> {
        AsyncStream { $0.finish() }   // no segments, and the stream ends so the drain does not time out
    }
    func feed(_ chunk: AudioChunk) async {}
    func finish() async throws { throw Failure() }
}

/// Yields whatever the test pushes, so a test can inject the pseudo-segment a real engine emits
/// when its result stream fails mid-session.
private final class PushEngine: TranscriptionEngine, @unchecked Sendable {
    var continuation: AsyncStream<TranscriptSegment>.Continuation?
    func preferredFormat() async -> AVAudioFormat { fmt }
    func start(channels: [Channel], vocabulary: [String]) async throws -> AsyncStream<TranscriptSegment> {
        AsyncStream { self.continuation = $0 }
    }
    func feed(_ chunk: AudioChunk) async {}
    func finish() async throws { continuation?.finish() }
}

private final class HangingEngine: TranscriptionEngine, @unchecked Sendable {
    func preferredFormat() async -> AVAudioFormat { fmt }
    func start(channels: [Channel], vocabulary: [String]) async throws -> AsyncStream<TranscriptSegment> {
        AsyncStream { _ in }   // never yields, never finishes
    }
    func feed(_ chunk: AudioChunk) async {}
    func finish() async throws {}   // returns without ending the segments stream
}

private final class HangingFinishEngine: TranscriptionEngine, @unchecked Sendable {
    func preferredFormat() async -> AVAudioFormat { fmt }
    func start(channels: [Channel], vocabulary: [String]) async throws -> AsyncStream<TranscriptSegment> {
        AsyncStream { _ in }   // never yields, never finishes
    }
    func feed(_ chunk: AudioChunk) async {}
    func finish() async throws { try await Task.sleep(for: .seconds(60)) }   // responds to cancellation
}

/// `finish()` suspends on a continuation and never checks `Task.isCancelled` or installs a
/// cancellation handler, so it models the worst case: an engine that ignores cancellation entirely.
/// Only the caller's own timeout can bound it. The continuation is parked in `pending` rather than
/// dropped so the test can `release()` it once the assertions are done — that keeps the suspended
/// task from outliving the test and keeps the run's output free of continuation-misuse warnings.
private final class BlockingFinishEngine: TranscriptionEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: CheckedContinuation<Void, Never>?

    func preferredFormat() async -> AVAudioFormat { fmt }
    func start(channels: [Channel], vocabulary: [String]) async throws -> AsyncStream<TranscriptSegment> {
        AsyncStream { _ in }   // never yields, never finishes
    }
    func feed(_ chunk: AudioChunk) async {}
    func finish() async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.withLock { pending = continuation }
        }
    }

    /// Resumes the suspended `finish()` exactly once. Waits for the continuation to appear: it is
    /// stored by a task the timeout deliberately does not synchronise with, so it may land a moment
    /// after `stop()` has returned.
    func release() async {
        for _ in 0..<100 {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                let taken = pending; pending = nil; return taken
            }
            if let continuation { continuation.resume(); return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class FakeTracks: TrackWriting, @unchecked Sendable {
    var started: [Channel] = []; var written = 0; var finished = false
    func start(channels: [Channel], format: AVAudioFormat, folder: SessionFolder) throws { started = channels }
    func write(_ chunk: AudioChunk) throws { written += 1 }
    func finish() async throws { finished = true }
}

/// A source the test drives buffer by buffer, so it can deliver some audio and then stop.
private final class PushSource: AudioSource, @unchecked Sendable {
    var continuation: AsyncStream<AudioChunk>.Continuation?
    var stopped = false
    /// Every device this source was asked to switch to, in order, and an optional failure.
    var switches: [String?] = []
    var switchError: Error?
    func start() async throws -> AsyncStream<AudioChunk> { AsyncStream { self.continuation = $0 } }
    func stop() async { stopped = true; continuation?.finish() }
    func switchDevice(uid: String?) async throws {
        if let switchError { throw switchError }
        switches.append(uid)
    }
}

private struct DeviceUnavailable: LocalizedError {
    var errorDescription: String? { "device is not connected" }
}

/// A host clock the test advances, for the starvation ticker.
private final class TestHostClock: @unchecked Sendable {
    private let lock = NSLock()
    private var ticks: UInt64 = 0
    var now: UInt64 { lock.withLock { ticks } }
    func advance(_ by: UInt64) { lock.withLock { ticks += by } }
}

private final class FakeShots: ShotSource, @unchecked Sendable {
    var continuation: AsyncStream<ScreenshotEvent>.Continuation?
    func start(folder: SessionFolder, sessionTime: @escaping @Sendable () -> TimeInterval) -> AsyncStream<ScreenshotEvent> {
        AsyncStream { self.continuation = $0 }
    }
    func stop() { continuation?.finish() }
}

private func config(root: URL, mode: SessionMode = .call, silence: TimeInterval? = nil, asymmetry: TimeInterval? = nil) -> SessionConfig {
    SessionConfig(root: root, mode: mode, input: InputDevice(name: "Fake Mic", uid: "fake"), locale: "en-US",
                  vocabulary: ["Acme"], vocabularyFileURL: nil, silencePeriod: silence, asymmetryPeriod: asymmetry,
                  engineInfo: EngineInfo(name: "fake", module: "Fake", locale: "en-US"), appVersion: "t",
                  timeZone: TimeZone(identifier: "UTC")!)
}

private final class Box: @unchecked Sendable { var value: StopReason? }

/// Everything the controller reports through `setOnHealth`, in order.
private final class HealthLog: @unchecked Sendable {
    private let lock = NSLock()
    private var changes: [HealthChange] = []
    private var snapshots: [HealthSnapshot] = []
    func record(_ c: [HealthChange], _ s: HealthSnapshot) { lock.withLock { changes += c; snapshots.append(s) } }
    var raised: [HealthChange] { lock.withLock { changes.filter(\.raised) } }
    var last: HealthSnapshot? { lock.withLock { snapshots.last } }
}

private func tempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("fr-ctrl-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: tests

@Test func startCreatesFolderFeedsBothChannelsAndStopFinalizes() async throws {
    let root = try tempRoot()
    let me = FakeSource([chunk(.me, hostTime: 10, level: 0.3), chunk(.me, hostTime: 20, level: 0.3)])
    let them = FakeSource([chunk(.them, hostTime: 15, level: 0.3)])
    let engine = FakeEngine(); let tracks = FakeTracks(); let shots = FakeShots()
    let controller = SessionController(sources: [.me: me, .them: them], engine: engine, trackWriter: tracks, shotSource: shots,
                                       now: { Date(timeIntervalSince1970: 1_756_830_612) }, hostNow: { 0 }, secondsPerHostTick: 1)
    let folder = try await controller.start(config: config(root: root))
    #expect(await controller.state == .recording(folder))
    #expect(FileManager.default.fileExists(atPath: folder.transcriptURL.path))
    #expect(tracks.started == [.me, .them])
    await waitUntil { engine.fed == [.me: 2, .them: 1] && tracks.written == 3 }
    #expect(engine.fed == [.me: 2, .them: 1])
    #expect(tracks.written == 3)

    shots.continuation?.yield(ScreenshotEvent(index: 1, time: 5, relativePath: "shots/001.png"))
    await controller.stop(reason: .user)

    #expect(await controller.state == .idle)
    #expect(engine.finished && tracks.finished && me.stopped && them.stopped)
    let transcript = try String(contentsOf: folder.transcriptURL, encoding: .utf8)
    // analyzer time 1 s + the .them channel's first buffer at host tick 15 (1 tick = 1 s) = 16 s
    #expect(transcript.contains("[00:16] Them: Final words."))
    #expect(transcript.contains("[00:05] ![shot 001](shots/001.png)"))
    let state = try SessionState.decoder.decode(SessionState.self, from: Data(contentsOf: folder.stateURL))
    #expect(state.state == .stopped && state.stopReason == .user && state.counts.shots == 1)
}

@Test func silenceOnAllChannelsStopsWithReasonSilence() async throws {
    let root = try tempRoot()
    // hostNow=0, one tick = 1 s; quiet chunks at 0…700 s exceed a 600 s period on the single room channel
    let quiet = (0..<8).map { chunk(.room, hostTime: UInt64($0 * 100), level: 0) }
    let room = FakeSource(quiet)
    let engine = FakeEngine(); let tracks = FakeTracks(); let shots = FakeShots()
    let controller = SessionController(sources: [.room: room], engine: engine, trackWriter: tracks, shotSource: shots,
                                       now: { Date(timeIntervalSince1970: 0) }, hostNow: { 0 }, secondsPerHostTick: 1)
    let stoppedWith = Box()
    await controller.setOnStopped { _, reason in stoppedWith.value = reason }
    let folder = try await controller.start(config: config(root: root, mode: .room, silence: 600))
    var tries = 0
    while await controller.state != .idle, tries < 50 { tries += 1; try await Task.sleep(for: .milliseconds(50)) }
    #expect(await controller.state == .idle)
    #expect(stoppedWith.value == .silence)
    let state = try SessionState.decoder.decode(SessionState.self, from: Data(contentsOf: folder.stateURL))
    #expect(state.stopReason == .silence && state.mode == .room)
}

@Test func addNoteAppearsInTranscript() async throws {
    let root = try tempRoot()
    let controller = SessionController(sources: [.room: FakeSource([])], engine: FakeEngine(), trackWriter: FakeTracks(),
                                       shotSource: FakeShots(), now: { Date(timeIntervalSince1970: 0) }, hostNow: { 7 }, secondsPerHostTick: 1)
    let folder = try await controller.start(config: config(root: root, mode: .room))
    await controller.addNote("input changed to MacBook Pro Microphone")
    await controller.stop(reason: .user)
    let transcript = try String(contentsOf: folder.transcriptURL, encoding: .utf8)
    #expect(transcript.contains("] (input changed to MacBook Pro Microphone)"))
}

@Test func stopFlushesTheConverterTailIntoTheEngine() async throws {
    let root = try tempRoot()
    let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let room = FakeSource([rawChunk(.room, format: sourceFormat, frameCount: 4800, hostTime: 0, level: 0.3)])
    let engine = FakeEngine(); let tracks = FakeTracks(); let shots = FakeShots()
    let controller = SessionController(sources: [.room: room], engine: engine, trackWriter: tracks, shotSource: shots,
                                       now: { Date(timeIntervalSince1970: 0) }, hostNow: { 0 }, secondsPerHostTick: 1)
    _ = try await controller.start(config: config(root: root, mode: .room))
    try await Task.sleep(for: .milliseconds(200))
    await controller.stop(reason: .user)
    let framesFed = engine.framesFed[.room] ?? 0
    #expect(abs(framesFed - 1600) <= 64)
    #expect(tracks.written >= 2)
}

@Test func formatChangeMidStreamRecreatesTheConverter() async throws {
    let root = try tempRoot()
    let format1 = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let format2 = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    let room = FakeSource([
        rawChunk(.room, format: format1, frameCount: 4800, hostTime: 0, level: 0.3),
        rawChunk(.room, format: format2, frameCount: 4410, hostTime: 100, level: 0.3),
    ])
    let engine = FakeEngine(); let tracks = FakeTracks(); let shots = FakeShots()
    let controller = SessionController(sources: [.room: room], engine: engine, trackWriter: tracks, shotSource: shots,
                                       now: { Date(timeIntervalSince1970: 0) }, hostNow: { 0 }, secondsPerHostTick: 1)
    let folder = try await controller.start(config: config(root: root, mode: .room))
    try await Task.sleep(for: .milliseconds(200))
    await controller.stop(reason: .user)
    let framesFed = engine.framesFed[.room] ?? 0
    #expect(abs(framesFed - 3200) <= 96)
    let transcript = try String(contentsOf: folder.transcriptURL, encoding: .utf8)
    #expect(!transcript.contains("conversion failed"))
}

@Test func stopReturnsWhenTheEngineNeverEndsItsStream() async throws {
    let root = try tempRoot()
    let controller = SessionController(sources: [.room: FakeSource([])], engine: HangingEngine(), trackWriter: FakeTracks(),
                                       shotSource: FakeShots(), now: { Date(timeIntervalSince1970: 0) }, hostNow: { 0 }, secondsPerHostTick: 1,
                                       segmentDrainTimeout: .milliseconds(200))
    let folder = try await controller.start(config: config(root: root, mode: .room))
    let clock = ContinuousClock()
    let elapsed = await clock.measure {
        await controller.stop(reason: .user)
    }
    #expect(elapsed < .seconds(3))
    #expect(await controller.state == .idle)
    let transcript = try String(contentsOf: folder.transcriptURL, encoding: .utf8)
    #expect(transcript.contains("(transcription drain timed out)"))
}

@Test func stopReturnsWhenEngineFinishBlocksForever() async throws {
    let root = try tempRoot()
    let engine = BlockingFinishEngine()
    let controller = SessionController(sources: [.room: FakeSource([])], engine: engine, trackWriter: FakeTracks(),
                                       shotSource: FakeShots(), now: { Date(timeIntervalSince1970: 0) }, hostNow: { 0 }, secondsPerHostTick: 1,
                                       segmentDrainTimeout: .milliseconds(200))
    let folder = try await controller.start(config: config(root: root, mode: .room))
    let clock = ContinuousClock()
    let elapsed = await clock.measure {
        await controller.stop(reason: .user)
    }
    #expect(elapsed < .seconds(3))
    #expect(await controller.state == .idle)
    let transcript = try String(contentsOf: folder.transcriptURL, encoding: .utf8)
    #expect(transcript.contains("(transcription finish timed out)"))
    await engine.release()   // let the abandoned finish() unwind now that the bound is proven
}

@Test func loudInt16AudioDoesNotTriggerTheSilenceWatchdog() async throws {
    // The engine's preferred format is Int16, so every buffer the watchdog measures is Int16 too.
    // A level reader that only looks at floatChannelData scores those buffers as digital silence
    // and stops a session that is in fact loud.
    let loudRoot = try tempRoot()
    let loud = (0..<8).map { int16Chunk(.room, hostTime: UInt64($0 * 100), sample: 16384) }
    let loudStop = Box()
    let loudController = SessionController(sources: [.room: FakeSource(loud)], engine: FakeEngine(format: int16Fmt),
                                           trackWriter: FakeTracks(), shotSource: FakeShots(),
                                           now: { Date(timeIntervalSince1970: 0) }, hostNow: { 0 }, secondsPerHostTick: 1)
    await loudController.setOnStopped { _, reason in loudStop.value = reason }
    let loudFolder = try await loudController.start(config: config(root: loudRoot, mode: .room, silence: 0.5))
    try await Task.sleep(for: .milliseconds(300))
    #expect(await loudController.state == .recording(loudFolder))
    await loudController.stop(reason: .user)
    #expect(loudStop.value == .user)
    let loudState = try SessionState.decoder.decode(SessionState.self, from: Data(contentsOf: loudFolder.stateURL))
    #expect(loudState.stopReason == .user)

    // The inverse, on the same Int16 path: all-zero buffers are silence and do stop the session.
    let quietRoot = try tempRoot()
    let quiet = (0..<8).map { int16Chunk(.room, hostTime: UInt64($0 * 100), sample: 0) }
    let quietStop = Box()
    let quietController = SessionController(sources: [.room: FakeSource(quiet)], engine: FakeEngine(format: int16Fmt),
                                            trackWriter: FakeTracks(), shotSource: FakeShots(),
                                            now: { Date(timeIntervalSince1970: 0) }, hostNow: { 0 }, secondsPerHostTick: 1)
    await quietController.setOnStopped { _, reason in quietStop.value = reason }
    let quietFolder = try await quietController.start(config: config(root: quietRoot, mode: .room, silence: 0.5))
    var tries = 0
    while await quietController.state != .idle, tries < 50 { tries += 1; try await Task.sleep(for: .milliseconds(50)) }
    #expect(await quietController.state == .idle)
    #expect(quietStop.value == .silence)
    let quietState = try SessionState.decoder.decode(SessionState.self, from: Data(contentsOf: quietFolder.stateURL))
    #expect(quietState.stopReason == .silence)
}

/// `handle` must read a buffer for its own purposes — the RMS level here — before handing it to
/// `engine.feed`. A real `SpeechAnalyzer` consumes fed buffers on its own worker thread with no
/// promise the caller's copy stays valid afterward; reading it back after `feed` races that
/// consumption and crashed the shipped app (SIGSEGV in `AudioLevel.rmsDBFS`, 2026-09-03).
@Test func levelIsMeasuredBeforeTheBufferIsHandedToTheEngine() async throws {
    let root = try tempRoot()
    let loud = (0..<8).map { int16Chunk(.room, hostTime: UInt64($0 * 100), sample: 16384) }
    let stop = Box()
    let controller = SessionController(sources: [.room: FakeSource(loud)], engine: BufferConsumingEngine(format: int16Fmt),
                                       trackWriter: FakeTracks(), shotSource: FakeShots(),
                                       now: { Date(timeIntervalSince1970: 0) }, hostNow: { 0 }, secondsPerHostTick: 1)
    await controller.setOnStopped { _, reason in stop.value = reason }
    let folder = try await controller.start(config: config(root: root, mode: .room, silence: 0.5))
    try await Task.sleep(for: .milliseconds(300))
    #expect(await controller.state == .recording(folder))
    await controller.stop(reason: .user)
    #expect(stop.value == .user)
}

@Test func anEngineThatFailsToFinishStopsWithReasonError() async throws {
    let root = try tempRoot()
    let stopped = Box()
    let controller = SessionController(sources: [.room: FakeSource([])], engine: ThrowingFinishEngine(),
                                       trackWriter: FakeTracks(), shotSource: FakeShots(),
                                       now: { Date(timeIntervalSince1970: 0) }, hostNow: { 0 }, secondsPerHostTick: 1,
                                       segmentDrainTimeout: .milliseconds(200))
    await controller.setOnStopped { _, reason in stopped.value = reason }
    let folder = try await controller.start(config: config(root: root, mode: .room))
    await controller.stop(reason: .user)          // the user asked, but the session failed

    let transcript = try String(contentsOf: folder.transcriptURL, encoding: .utf8)
    #expect(transcript.contains("(transcription stopped: analyzer died)"))
    let state = try SessionState.decoder.decode(SessionState.self, from: Data(contentsOf: folder.stateURL))
    #expect(state.stopReason == .error)
    #expect(stopped.value == .error)
}

@Test func anEngineErrorSegmentBecomesANoteNotASpeakerTurn() async throws {
    let root = try tempRoot()
    let engine = PushEngine()
    // .them's first buffer lands at host tick 5, so analyzer time 12 on that channel is 17 s in.
    let controller = SessionController(sources: [.them: FakeSource([chunk(.them, hostTime: 5, level: 0.3)])],
                                       engine: engine, trackWriter: FakeTracks(), shotSource: FakeShots(),
                                       now: { Date(timeIntervalSince1970: 0) }, hostNow: { 0 }, secondsPerHostTick: 1)
    let folder = try await controller.start(config: config(root: root))
    try await Task.sleep(for: .milliseconds(150))
    engine.continuation?.yield(.engineError(channel: .them, at: 12, message: "analyzer stalled"))
    try await Task.sleep(for: .milliseconds(150))
    await controller.stop(reason: .user)

    let transcript = try String(contentsOf: folder.transcriptURL, encoding: .utf8)
    #expect(transcript.contains("[00:17] (transcription stopped: analyzer stalled)"))
    #expect(!transcript.contains("Them: (transcription stopped"))
    let state = try SessionState.decoder.decode(SessionState.self, from: Data(contentsOf: folder.stateURL))
    #expect(state.counts.segments == 0)          // counted as a note, not a turn
    #expect(state.stopReason == .error)
}

@Test func aChannelThatStopsDeliveringIsNotedOnceAndAgainWhenItReturns() async throws {
    let root = try tempRoot()
    let host = TestHostClock()
    let them = PushSource(); let me = PushSource()
    let controller = SessionController(sources: [.me: me, .them: them], engine: FakeEngine(), trackWriter: FakeTracks(),
                                       shotSource: FakeShots(), now: { Date(timeIntervalSince1970: 0) },
                                       hostNow: { host.now }, secondsPerHostTick: 1,
                                       tickInterval: .milliseconds(100))
    let folder = try await controller.start(config: config(root: root))
    them.continuation?.yield(chunk(.them, hostTime: 0, level: 0.3))
    them.continuation?.yield(chunk(.them, hostTime: 1, level: 0.3))
    try await Task.sleep(for: .milliseconds(150))

    host.advance(20)                                     // 19 s since the last Them buffer
    try await Task.sleep(for: .milliseconds(400))        // several ticks: the note must still be one

    them.continuation?.yield(chunk(.them, hostTime: 20, level: 0.3))
    try await Task.sleep(for: .milliseconds(150))
    await controller.stop(reason: .user)

    let transcript = try String(contentsOf: folder.transcriptURL, encoding: .utf8)
    #expect(transcript.components(separatedBy: "(Them audio stopped delivering)").count - 1 == 1)
    #expect(transcript.contains("[00:20] (Them audio resumed)"))
    // .me never delivered a buffer, so there is no gap to report on it.
    #expect(!transcript.contains("Me audio stopped delivering"))
    // A device change is not a failure: the notes are the whole remedy.
    let state = try SessionState.decoder.decode(SessionState.self, from: Data(contentsOf: folder.stateURL))
    #expect(state.stopReason == .user)
}

@Test func stopReturnsWhenEngineFinishNeverReturns() async throws {
    let root = try tempRoot()
    let controller = SessionController(sources: [.room: FakeSource([])], engine: HangingFinishEngine(), trackWriter: FakeTracks(),
                                       shotSource: FakeShots(), now: { Date(timeIntervalSince1970: 0) }, hostNow: { 0 }, secondsPerHostTick: 1,
                                       segmentDrainTimeout: .milliseconds(200))
    let folder = try await controller.start(config: config(root: root, mode: .room))
    let clock = ContinuousClock()
    let elapsed = await clock.measure {
        await controller.stop(reason: .user)
    }
    #expect(elapsed < .seconds(3))
    #expect(await controller.state == .idle)
    let transcript = try String(contentsOf: folder.transcriptURL, encoding: .utf8)
    #expect(transcript.contains("(transcription finish timed out)"))
}

@Test func audioRecordedAtTheWrongRateIsNotedAndFailsTheSession() async throws {
    // The 2026-09-03 failure: the microphone tap labelled a 16 kHz headset's buffers 48 kHz, so
    // every 0.1 s of speech was resampled down to 0.033 s of file. Nothing else in the session
    // could tell -- buffers arrived, levels moved, the file grew -- and a whole side of a
    // 24-minute call came out three times too fast and unreadable.
    let root = try tempRoot()
    let mislabelled = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let me = PushSource()
    let controller = SessionController(sources: [.me: me], engine: FakeEngine(), trackWriter: FakeTracks(),
                                       shotSource: FakeShots(), now: { Date(timeIntervalSince1970: 0) },
                                       hostNow: { 0 }, secondsPerHostTick: 0.001)
    let folder = try await controller.start(config: config(root: root))
    // 1600 frames claiming to be 48 kHz arrive every 100 ms -- the pace of 16 kHz audio.
    for i in 0..<600 {
        me.continuation?.yield(rawChunk(.me, format: mislabelled, frameCount: 1600,
                                        hostTime: UInt64(i * 100), level: 0.3))
    }
    try await Task.sleep(for: .milliseconds(300))
    await controller.stop(reason: .user)

    let transcript = try String(contentsOf: folder.transcriptURL, encoding: .utf8)
    #expect(transcript.contains("Me audio is recording at 0.33x real time"))
    #expect(transcript.components(separatedBy: "is recording at").count - 1 == 1)   // said once
    let state = try SessionState.decoder.decode(SessionState.self, from: Data(contentsOf: folder.stateURL))
    #expect(state.stopReason == .error)
}

@Test func audioThatKeepsPaceIsNotFlagged() async throws {
    let root = try tempRoot()
    let me = PushSource()
    let controller = SessionController(sources: [.me: me], engine: FakeEngine(), trackWriter: FakeTracks(),
                                       shotSource: FakeShots(), now: { Date(timeIntervalSince1970: 0) },
                                       hostNow: { 0 }, secondsPerHostTick: 0.001)
    let folder = try await controller.start(config: config(root: root))
    for i in 0..<600 {                                   // 1600 frames of 16 kHz every 100 ms
        me.continuation?.yield(chunk(.me, hostTime: UInt64(i * 100), level: 0.3))
    }
    try await Task.sleep(for: .milliseconds(300))
    await controller.stop(reason: .user)

    let transcript = try String(contentsOf: folder.transcriptURL, encoding: .utf8)
    #expect(!transcript.contains("is recording at"))
    let state = try SessionState.decoder.decode(SessionState.self, from: Data(contentsOf: folder.stateURL))
    #expect(state.stopReason == .user)
}

// MARK: channel health

@Test func aSideThatFallsSilentWhileTheOtherTalksIsNotedAndReported() async throws {
    let root = try tempRoot()
    let me = PushSource(); let them = PushSource(); let engine = PushEngine()
    let log = HealthLog()
    let controller = SessionController(sources: [.me: me, .them: them], engine: engine, trackWriter: FakeTracks(),
                                       shotSource: FakeShots(), now: { Date(timeIntervalSince1970: 0) },
                                       hostNow: { 0 }, secondsPerHostTick: 0.001)
    await controller.setOnHealth { changes, snapshot in log.record(changes, snapshot) }
    let folder = try await controller.start(config: config(root: root, asymmetry: 30))
    for i in 0..<40 { me.continuation?.yield(chunk(.me, hostTime: UInt64(i * 100), level: 0.3)) }   // 4 s of Me
    try await Task.sleep(for: .milliseconds(150))
    engine.continuation?.yield(TranscriptSegment(channel: .me, start: 0, end: 4, text: "Here is the screen."))
    // 36 s of Them, transcribed as it goes; Me delivers silence throughout.
    for block in 0..<3 {
        for i in (40 + block * 120)..<(40 + (block + 1) * 120) {
            them.continuation?.yield(chunk(.them, hostTime: UInt64(i * 100), level: 0.3))
            me.continuation?.yield(chunk(.me, hostTime: UInt64(i * 100), level: 0))
        }
        try await Task.sleep(for: .milliseconds(150))
        // Them's analyzer clock starts at its first buffer (4 s in), so these land at 4–14, 14–24, 24–34.
        engine.continuation?.yield(TranscriptSegment(channel: .them, start: Double(block * 10), end: Double(block * 10 + 10), text: "Block \(block)."))
        try await Task.sleep(for: .milliseconds(100))
    }
    await controller.stop(reason: .user)

    let transcript = try String(contentsOf: folder.transcriptURL, encoding: .utf8)
    #expect(transcript.contains("(Me: no speech for 30 s while Them talked)"))
    #expect(transcript.components(separatedBy: "no speech for").count - 1 == 1)
    #expect(log.raised.contains { $0.channel == .me && $0.issue == .silentWhileOtherTalks })
    #expect(log.last?.problems == ["Me: no speech for 30 s while Them talked"])
    // A side that went quiet is something to look at, not a failed session.
    let state = try SessionState.decoder.decode(SessionState.self, from: Data(contentsOf: folder.stateURL))
    #expect(state.stopReason == .user)
}

@Test func speechThatNeverBecomesATranscriptIsNotedUntilASegmentLands() async throws {
    let root = try tempRoot()
    let me = PushSource(); let engine = PushEngine()
    let log = HealthLog()
    let controller = SessionController(sources: [.me: me], engine: engine, trackWriter: FakeTracks(),
                                       shotSource: FakeShots(), now: { Date(timeIntervalSince1970: 0) },
                                       hostNow: { 0 }, secondsPerHostTick: 0.001)
    await controller.setOnHealth { changes, snapshot in log.record(changes, snapshot) }
    let folder = try await controller.start(config: config(root: root))
    for i in 0..<10 { me.continuation?.yield(chunk(.me, hostTime: UInt64(i * 100), level: 0.001)) }  // a second of room, then
    // 62 s of talking — loud with the gaps a voice leaves, so it reads as speech and not as a tone
    // — of which 46 s is above the floor, with nothing transcribed from any of it.
    for i in 10..<630 {
        me.continuation?.yield(chunk(.me, hostTime: UInt64(i * 100), level: i % 4 == 3 ? 0.001 : 0.3))
    }
    try await Task.sleep(for: .milliseconds(400))
    #expect(log.last?.isHealthy == false)
    engine.continuation?.yield(TranscriptSegment(channel: .me, start: 40, end: 45, text: "Finally."))
    try await Task.sleep(for: .milliseconds(200))
    await controller.stop(reason: .user)

    let transcript = try String(contentsOf: folder.transcriptURL, encoding: .utf8)
    #expect(transcript.contains("(Me: 45 s of speech with nothing transcribed)"))
    #expect(transcript.contains("(Me: transcription resumed)"))
    #expect(transcript.contains("Me: Finally."))
    #expect(log.last?.isHealthy == true)
}

@Test func aSideThatIsNeverHeardIsReportedAsAOneSidedRecording() async throws {
    // Phone on speaker with system audio left on: Them never delivers a buffer while Me carries
    // the whole conversation for a minute. The capture is correct — there is nothing on the Mac's
    // output to record — but only half the call is being kept, and the session says which half.
    let root = try tempRoot()
    let me = PushSource(); let them = PushSource(); let engine = PushEngine()
    let log = HealthLog()
    let controller = SessionController(sources: [.me: me, .them: them], engine: engine, trackWriter: FakeTracks(),
                                       shotSource: FakeShots(), now: { Date(timeIntervalSince1970: 0) },
                                       hostNow: { 0 }, secondsPerHostTick: 0.001)
    await controller.setOnHealth { changes, snapshot in log.record(changes, snapshot) }
    let folder = try await controller.start(config: config(root: root, asymmetry: 30))
    for block in 0..<3 {                                                                         // 60 s of Me, transcribed as it goes
        for i in (block * 200)..<((block + 1) * 200) {
            me.continuation?.yield(chunk(.me, hostTime: UInt64(i * 100), level: 0.3))
        }
        try await Task.sleep(for: .milliseconds(150))
        engine.continuation?.yield(TranscriptSegment(channel: .me, start: Double(block * 20), end: Double(block * 20 + 19), text: "Block \(block)."))
        try await Task.sleep(for: .milliseconds(100))
    }
    await controller.stop(reason: .user)

    let transcript = try String(contentsOf: folder.transcriptURL, encoding: .utf8)
    // Them never spoke, so it cannot have fallen silent or gone untranscribed; it is simply absent.
    #expect(!transcript.contains("no speech"))
    #expect(!transcript.contains("nothing transcribed"))
    #expect(transcript.contains("(Them: nothing recorded on this side, the microphone carried the whole call)"))
    // And the microphone's lines stop claiming to be one speaker: it was the only record of the
    // call, the other party included, so it is labelled the way a single-microphone session is.
    #expect(transcript.contains("- Mode: call (Room = microphone, carrying both sides; the far side never reached this Mac)"))
    #expect(transcript.contains("Room: Block 0."))
    #expect(!transcript.contains("Me: Block"))
    #expect(log.raised.map(\.issue) == [.oneSidedRecording])
    #expect(log.raised.map(\.channel) == [.them])
    #expect(log.last?.unheard == [.them])
    #expect(log.last?.presentation == .micOnly)
    #expect(log.last?.isHealthy == false)
    // And the same thing said where a reader of the folder will find it afterwards.
    let state = try SessionState.decoder.decode(SessionState.self, from: Data(contentsOf: folder.stateURL))
    #expect(state.heard == [.me])
    #expect(state.systemAudio)            // the tap was asked for; `heard` says what it delivered
}

@Test func theInitialHealthStateIsReportedWhenTheSessionStarts() async throws {
    // The menu bar shows which sides have been heard from the first second, so it needs the
    // starting state — nobody heard, nothing wrong — before any buffer has arrived.
    let root = try tempRoot()
    let log = HealthLog()
    let controller = SessionController(sources: [.me: PushSource(), .them: PushSource()], engine: FakeEngine(),
                                       trackWriter: FakeTracks(), shotSource: FakeShots(),
                                       now: { Date(timeIntervalSince1970: 0) }, hostNow: { 0 }, secondsPerHostTick: 1)
    await controller.setOnHealth { changes, snapshot in log.record(changes, snapshot) }
    _ = try await controller.start(config: config(root: root))
    #expect(log.last?.unheard == [.me, .them])
    #expect(log.last?.isHealthy == true)
    #expect(log.raised.isEmpty)
    await controller.stop(reason: .user)
}

// MARK: switching input mid-session

@Test func switchingInputKeepsTheSessionAndNotesTheChange() async throws {
    let root = try tempRoot()
    let me = PushSource(); let them = PushSource()
    let controller = SessionController(sources: [.me: me, .them: them], engine: FakeEngine(), trackWriter: FakeTracks(),
                                       shotSource: FakeShots(), now: { Date(timeIntervalSince1970: 0) },
                                       hostNow: { 0 }, secondsPerHostTick: 0.001)
    let folder = try await controller.start(config: config(root: root))
    for i in 0..<20 { me.continuation?.yield(chunk(.me, hostTime: UInt64(i * 100), level: 0.3)) }
    try await Task.sleep(for: .milliseconds(200))

    #expect(await controller.switchInput(uid: "jabra-uid", name: "Jabra Link 380") == true)
    #expect(me.switches == ["jabra-uid"])
    #expect(them.switches.isEmpty)                       // the system-audio tap has no device to pick
    #expect(!me.stopped)                                 // the same source, the same stream
    #expect(await controller.state == .recording(folder)) // and the same session

    for i in 20..<40 { me.continuation?.yield(chunk(.me, hostTime: UInt64(i * 100), level: 0.3)) }
    try await Task.sleep(for: .milliseconds(200))
    await controller.stop(reason: .user)

    let transcript = try String(contentsOf: folder.transcriptURL, encoding: .utf8)
    #expect(transcript.contains("(input changed to Jabra Link 380)"))
    let state = try SessionState.decoder.decode(SessionState.self, from: Data(contentsOf: folder.stateURL))
    #expect(state.stopReason == .user)                   // a deliberate switch is not a failure
}

@Test func aSwitchThatFailsIsNotedWithoutFailingTheSession() async throws {
    let root = try tempRoot()
    let me = PushSource()
    me.switchError = DeviceUnavailable()
    let controller = SessionController(sources: [.me: me], engine: FakeEngine(), trackWriter: FakeTracks(),
                                       shotSource: FakeShots(), now: { Date(timeIntervalSince1970: 0) },
                                       hostNow: { 0 }, secondsPerHostTick: 0.001)
    let folder = try await controller.start(config: config(root: root))
    #expect(await controller.switchInput(uid: "gone", name: "Ghost Mic") == false)
    await controller.stop(reason: .user)

    let transcript = try String(contentsOf: folder.transcriptURL, encoding: .utf8)
    #expect(transcript.contains("(could not switch input to Ghost Mic: device is not connected)"))
    #expect(!transcript.contains("input changed to"))
    // The capture kept the device it had, so the recording is sound and the stop reason stands.
    let state = try SessionState.decoder.decode(SessionState.self, from: Data(contentsOf: folder.stateURL))
    #expect(state.stopReason == .user)
}

@Test func switchingInputInRoomModeSwitchesTheRoomChannel() async throws {
    let root = try tempRoot()
    let room = PushSource()
    let controller = SessionController(sources: [.room: room], engine: FakeEngine(), trackWriter: FakeTracks(),
                                       shotSource: FakeShots(), now: { Date(timeIntervalSince1970: 0) },
                                       hostNow: { 0 }, secondsPerHostTick: 0.001)
    _ = try await controller.start(config: config(root: root, mode: .room))
    #expect(await controller.switchInput(uid: nil, name: "MacBook Pro Microphone") == true)
    #expect(room.switches == [String?.none])
    await controller.stop(reason: .user)
}

@Test func switchingInputWhileIdleDoesNothing() async throws {
    let me = PushSource()
    let controller = SessionController(sources: [.me: me], engine: FakeEngine(), trackWriter: FakeTracks(),
                                       shotSource: FakeShots(), now: { Date(timeIntervalSince1970: 0) },
                                       hostNow: { 0 }, secondsPerHostTick: 1)
    #expect(await controller.switchInput(uid: "jabra-uid", name: "Jabra Link 380") == false)
    #expect(me.switches.isEmpty)
}

// MARK: level meters

private final class LevelLog: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [[Channel: Double]] = []
    func record(_ s: [Channel: Double]) { lock.withLock { snapshots.append(s) } }
    var count: Int { lock.withLock { snapshots.count } }
    func peak(_ channel: Channel) -> Double { lock.withLock { snapshots.compactMap { $0[channel] }.max() ?? -1 } }
}

@Test func levelMetersReportEachSideAgainstItsFloorWhileRecording() async throws {
    let root = try tempRoot()
    let me = PushSource(); let them = PushSource()
    let levels = LevelLog()
    let controller = SessionController(sources: [.me: me, .them: them], engine: FakeEngine(), trackWriter: FakeTracks(),
                                       shotSource: FakeShots(), now: { Date(timeIntervalSince1970: 0) },
                                       hostNow: { 0 }, secondsPerHostTick: 0.001, meterInterval: .milliseconds(40))
    await controller.setOnLevels { levels.record($0) }
    _ = try await controller.start(config: config(root: root))
    for i in 0..<10 { me.continuation?.yield(chunk(.me, hostTime: UInt64(i * 100), level: 0.001)) }   // −60 dBFS: the room
    await waitUntil { levels.count >= 1 }
    let quietPeak = levels.peak(.me)
    for i in 10..<15 { me.continuation?.yield(chunk(.me, hostTime: UInt64(i * 100), level: 0.3)) }    // −10 dBFS: 50 dB above it
    await waitUntil { levels.peak(.me) >= 1 && levels.count >= 3 }
    await controller.stop(reason: .user)

    #expect(levels.count >= 3)
    #expect(quietPeak == 0)                    // at the floor the meter rests
    #expect(levels.peak(.me) == 1)             // speech well above it fills the bar
    #expect(levels.peak(.them) == 0)           // a side that never delivered reads empty, not absent
}

@Test func theVocabularyReachesTheEngine() async throws {
    // VocabularyTests covers reading vocab.txt and nothing past it, so nothing caught the engine
    // accepting the phrases and dropping them. This is the seam where they leave FeedbackCore.
    let root = try tempRoot()
    let engine = FakeEngine()
    let controller = SessionController(sources: [.me: FakeSource([])], engine: engine, trackWriter: FakeTracks(),
                                       shotSource: FakeShots(), now: { Date(timeIntervalSince1970: 0) },
                                       hostNow: { 0 }, secondsPerHostTick: 1)
    _ = try await controller.start(config: config(root: root))
    await controller.stop(reason: .user)
    #expect(engine.startedWithVocabulary == ["Acme"])
}

private final class FakeBackfill: TranscriptBackfilling, @unchecked Sendable {
    private let lock = NSLock()
    private var _asked: [TranscriptGap] = []
    private var _recovered: [TranscriptSegment] = []
    private var _failure: Error?
    var asked: [TranscriptGap] { lock.withLock { _asked } }
    func willRecover(_ segments: [TranscriptSegment]) { lock.withLock { _recovered = segments } }
    func willFail(_ error: Error) { lock.withLock { _failure = error } }
    func recover(gaps: [TranscriptGap], folder: SessionFolder) async throws -> [TranscriptSegment] {
        let (failure, recovered) = lock.withLock { () -> (Error?, [TranscriptSegment]) in
            _asked = gaps
            return (_failure, _recovered)
        }
        if let failure { throw failure }
        return recovered
    }
}

/// Drives a session into one annotated dropout on Me and stops it, returning the transcript and
/// what the backfill was asked for.
private func sessionWithOneDropout(_ backfill: FakeBackfill) async throws -> (String, FakeBackfill) {
    let root = try tempRoot()
    let me = PushSource(); let engine = PushEngine()
    let controller = SessionController(sources: [.me: me], engine: engine, trackWriter: FakeTracks(),
                                       shotSource: FakeShots(), backfill: backfill,
                                       now: { Date(timeIntervalSince1970: 0) },
                                       hostNow: { 0 }, secondsPerHostTick: 0.001)
    let folder = try await controller.start(config: config(root: root))
    engine.continuation?.yield(TranscriptSegment(channel: .me, start: 0, end: 10, text: "Before the gap."))
    try await Task.sleep(for: .milliseconds(100))
    for i in 0..<10 { me.continuation?.yield(chunk(.me, hostTime: UInt64(i * 100), level: 0.001)) }
    for i in 10..<630 {                                        // 62 s of talking, nothing transcribed
        me.continuation?.yield(chunk(.me, hostTime: UInt64(i * 100), level: i % 4 == 3 ? 0.001 : 0.3))
    }
    try await Task.sleep(for: .milliseconds(400))
    engine.continuation?.yield(TranscriptSegment(channel: .me, start: 70, end: 75, text: "After the gap."))
    try await Task.sleep(for: .milliseconds(200))
    await controller.stop(reason: .user)
    return (try String(contentsOf: folder.transcriptURL, encoding: .utf8), backfill)
}

@Test func speechTheTranscriberDroppedIsRecoveredFromTheAudioOnStop() async throws {
    // A detected dropout must trigger a bounded recovery from the saved audio.
    let backfill = FakeBackfill()
    backfill.willRecover([TranscriptSegment(channel: .me, start: 30, end: 34, text: "The bit that was lost.")])
    let (transcript, asked) = try await sessionWithOneDropout(backfill)

    #expect(asked.asked.count == 1)
    let gap = try #require(asked.asked.first)
    #expect(gap.channel == .me)
    #expect(gap.start == 10)              // the end of the line before it
    #expect(gap.end == 70)                // the start of the line that ended it
    #expect(transcript.contains("Me: The bit that was lost."))
    #expect(transcript.contains("re-read by whisper, 1 line(s) recovered"))
}

@Test func aBackfillThatFailsLeavesTheTranscriptAloneAndSaysSo() async throws {
    struct NoWhisper: LocalizedError { var errorDescription: String? { "whisper-cli not found" } }
    let backfill = FakeBackfill()
    backfill.willFail(NoWhisper())
    let (transcript, _) = try await sessionWithOneDropout(backfill)
    #expect(transcript.contains("could not re-read the untranscribed audio: whisper-cli not found"))
    #expect(transcript.contains("Me: Before the gap."))
    #expect(transcript.contains("Me: After the gap."))
}

@Test func aSessionWithNoDropoutsNeverAsksForARecovery() async throws {
    let root = try tempRoot()
    let backfill = FakeBackfill()
    let engine = PushEngine()
    let controller = SessionController(sources: [.me: FakeSource([])], engine: engine, trackWriter: FakeTracks(),
                                       shotSource: FakeShots(), backfill: backfill,
                                       now: { Date(timeIntervalSince1970: 0) }, hostNow: { 0 }, secondsPerHostTick: 0.001)
    _ = try await controller.start(config: config(root: root))
    engine.continuation?.yield(TranscriptSegment(channel: .me, start: 0, end: 10, text: "All of it."))
    try await Task.sleep(for: .milliseconds(100))
    await controller.stop(reason: .user)
    #expect(backfill.asked.isEmpty)
}

private final class FailingStartTracks: TrackWriting, @unchecked Sendable {
    var finished = false
    func start(channels: [Channel], format: AVAudioFormat, folder: SessionFolder) throws { throw DeviceUnavailable() }
    func write(_ chunk: AudioChunk) throws {}
    func finish() async throws { finished = true }
}

private final class FailingWriteTracks: TrackWriting, @unchecked Sendable {
    func start(channels: [Channel], format: AVAudioFormat, folder: SessionFolder) throws {}
    func write(_ chunk: AudioChunk) throws { throw DeviceUnavailable() }
    func finish() async throws {}
}

private final class FailingSource: AudioSource, @unchecked Sendable {
    var stopped = false
    func start() async throws -> AsyncStream<AudioChunk> { throw DeviceUnavailable() }
    func stop() async { stopped = true }
}

@Test func failedTrackStartupRollsBackEngineAndSessionFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fr-start-fail-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = FakeEngine(), tracks = FailingStartTracks()
    let controller = SessionController(sources: [:], engine: engine, trackWriter: tracks, shotSource: FakeShots())
    await #expect(throws: DeviceUnavailable.self) { try await controller.start(config: config(root: root)) }
    #expect(await controller.state == .idle)
    #expect(engine.finished && tracks.finished)
    let folder = try #require(await controller.lastFolder)
    let saved = try SessionState.decoder.decode(SessionState.self, from: Data(contentsOf: folder.stateURL))
    #expect(saved.state == .stopped && saved.stopReason == .error)
}

@Test func failedSecondSourceStopsTheFirstWithoutCallerCleanup() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fr-source-fail-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let mic = FakeSource([]), system = FailingSource(), engine = FakeEngine(), tracks = FakeTracks()
    let controller = SessionController(sources: [.me: mic, .them: system], engine: engine,
                                       trackWriter: tracks, shotSource: FakeShots())
    await #expect(throws: DeviceUnavailable.self) { try await controller.start(config: config(root: root)) }
    #expect(mic.stopped && system.stopped && engine.finished && tracks.finished)
    #expect(await controller.state == .idle)
}

private actor PausedStartEngine: TranscriptionEngine {
    private var ready: CheckedContinuation<Void, Never>?
    func preferredFormat() async -> AVAudioFormat {
        await withCheckedContinuation { ready = $0 }
        return AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    }
    var waiting: Bool { ready != nil }
    func release() { ready?.resume(); ready = nil }
    func start(channels: [Channel], vocabulary: [String]) async throws -> AsyncStream<TranscriptSegment> {
        AsyncStream { $0.finish() }
    }
    func feed(_ chunk: AudioChunk) async {}
    func finish() async throws {}
}

@Test func concurrentStartCannotCreateASecondSession() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fr-concurrent-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = PausedStartEngine()
    let controller = SessionController(sources: [:], engine: engine, trackWriter: FakeTracks(), shotSource: FakeShots())
    let first = Task { try await controller.start(config: config(root: root)) }
    await waitUntil { await engine.waiting }
    #expect(await controller.state == .starting)
    await #expect(throws: SessionError.self) { try await controller.start(config: config(root: root)) }
    await engine.release()
    _ = try await first.value
    await controller.stop(reason: .user)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1)
}

@Test func audioWriteFailureStopsAndMarksSessionAsError() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fr-write-fail-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = PushSource()
    let controller = SessionController(sources: [.me: source], engine: FakeEngine(),
                                       trackWriter: FailingWriteTracks(), shotSource: FakeShots())
    let folder = try await controller.start(config: config(root: root))
    source.continuation?.yield(chunk(.me, hostTime: mach_absolute_time(), level: 0.2))
    #expect(await waitUntil { await controller.state == .idle })
    let saved = try SessionState.decoder.decode(SessionState.self, from: Data(contentsOf: folder.stateURL))
    #expect(saved.stopReason == .error)
    #expect(try String(contentsOf: folder.transcriptURL, encoding: .utf8).contains("Audio could not be saved"))
}

@Test func metadataWriteFailureStopsSession() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fr-metadata-fail-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let controller = SessionController(sources: [:], engine: FakeEngine(), trackWriter: FakeTracks(), shotSource: FakeShots())
    let folder = try await controller.start(config: config(root: root))
    // A directory in place of the metadata file produces a real, deterministic filesystem error.
    try FileManager.default.removeItem(at: folder.stateURL)
    try FileManager.default.createDirectory(at: folder.stateURL, withIntermediateDirectories: false)
    await controller.addNote("Force a flush.")
    #expect(await waitUntil { await controller.state == .idle })
}

private final class FinalizationClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1000)
    var now: Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}

private struct DelayedFinalizationTracks: TrackWriting {
    let clock: FinalizationClock
    func start(channels: [Channel], format: AVAudioFormat, folder: SessionFolder) throws {}
    func write(_ chunk: AudioChunk) throws {}
    func finish() async throws { clock.advance(600) }
}

@Test func recordingDurationExcludesSlowFinalization() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fr-duration-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = FinalizationClock()
    let controller = SessionController(sources: [:], engine: FakeEngine(),
        trackWriter: DelayedFinalizationTracks(clock: clock), shotSource: FakeShots(), now: { clock.now })
    let folder = try await controller.start(config: config(root: root))
    clock.advance(30)
    await controller.stop(reason: .user)
    let saved = try SessionState.decoder.decode(SessionState.self, from: Data(contentsOf: folder.stateURL))
    #expect(saved.durationSeconds == 30)
    #expect(saved.stoppedAt == Date(timeIntervalSince1970: 1030))
}
