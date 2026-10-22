import Foundation
import AVFAudio

public enum SessionError: Error { case alreadyRecording }

public actor SessionController {
    public enum State: Sendable, Equatable { case idle, recording(SessionFolder), stopping }

    public private(set) var state: State = .idle
    public private(set) var lastFolder: SessionFolder?
    public var currentFolder: SessionFolder? { if case .recording(let f) = state { return f }; return nil }

    private let sources: [Channel: any AudioSource]
    private let engine: any TranscriptionEngine
    private let trackWriter: any TrackWriting
    private let shotSource: any ShotSource
    private let backfill: (any TranscriptBackfilling)?
    private let now: @Sendable () -> Date
    private let hostNow: @Sendable () -> UInt64
    private let secondsPerHostTick: Double
    private let segmentDrainTimeout: Duration
    private let tickInterval: Duration
    private let meterInterval: Duration
    private let starvationTimeout: TimeInterval

    private var writer: SessionWriter?
    private var clock: ChannelClock?
    private var watchdog: SilenceWatchdog?
    private var rateMonitor = CaptureRateMonitor()
    private var health = ChannelHealth(channels: [], asymmetryPeriod: nil)
    /// What `health.heard` was when the health callback last fired, so a side becoming heard
    /// reaches the caller even though it raises no issue.
    private var reportedHeard: Set<Channel> = []
    private var converters: [Channel: FormatConverter] = [:]
    private var pumps: [Task<Void, Never>] = []
    private var segmentTask: Task<Void, Never>?
    private var shotTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?
    /// The loudest buffer on each channel since the meter last published. Only kept while someone
    /// is listening for levels.
    private var meterPeak: [Channel: Double] = [:]
    private var onStopped: (@Sendable (SessionFolder, StopReason) -> Void)?
    private var onNote: (@Sendable (String) -> Void)?
    private var onHealth: (@Sendable ([HealthChange], HealthSnapshot) -> Void)?
    private var onLevels: (@Sendable ([Channel: Double]) -> Void)?
    /// Set the moment anything is written to the transcript as an error note, so `stop` can record
    /// `stopReason: error` for a session that kept recording through a failure. Cleared by `start`.
    private var sawError = false
    private var activeChannels: [Channel] = []
    /// Session seconds of the newest buffer seen on each channel, and the channels whose gap has
    /// already been noted. Together they make the starvation note fire once per silence.
    private var lastBufferTime: [Channel: TimeInterval] = [:]
    private var starvedChannels: Set<Channel> = []
    /// Where each side's transcript had got to, which side is currently inside a dropout, and the
    /// dropouts closed so far. Together they bound the audio worth re-transcribing at stop.
    private var lastSegmentEnd: [Channel: TimeInterval] = [:]
    private var channelsInDropout: Set<Channel> = []
    private var gaps: [TranscriptGap] = []

    public init(sources: [Channel: any AudioSource], engine: any TranscriptionEngine, trackWriter: any TrackWriting,
                shotSource: any ShotSource, backfill: (any TranscriptBackfilling)? = nil,
                now: @escaping @Sendable () -> Date = { Date() },
                hostNow: @escaping @Sendable () -> UInt64 = { mach_absolute_time() },
                secondsPerHostTick: Double = ChannelClock.machSecondsPerTick(),
                segmentDrainTimeout: Duration = .seconds(5),
                tickInterval: Duration = .seconds(5),
                starvationTimeout: TimeInterval = 10,
                meterInterval: Duration = .milliseconds(100)) {
        self.sources = sources; self.engine = engine; self.trackWriter = trackWriter; self.shotSource = shotSource
        self.backfill = backfill
        self.now = now; self.hostNow = hostNow; self.secondsPerHostTick = secondsPerHostTick
        self.segmentDrainTimeout = segmentDrainTimeout
        self.tickInterval = tickInterval; self.starvationTimeout = starvationTimeout
        self.meterInterval = meterInterval
    }

    public func setOnStopped(_ handler: @escaping @Sendable (SessionFolder, StopReason) -> Void) { onStopped = handler }
    public func setOnNote(_ handler: @escaping @Sendable (String) -> Void) { onNote = handler }
    /// Called whenever a side's health changes or a side is heard for the first time, with the
    /// transitions and the state they led to.
    public func setOnHealth(_ handler: @escaping @Sendable ([HealthChange], HealthSnapshot) -> Void) { onHealth = handler }
    /// Called every `meterInterval` while recording with each active channel's level since the last
    /// call, as a 0…1 fraction above that channel's own noise floor. `nil` stops the reports and the
    /// bookkeeping behind them; the handler may be set or cleared mid-session.
    public func setOnLevels(_ handler: (@Sendable ([Channel: Double]) -> Void)?) {
        onLevels = handler
        if handler == nil { meterPeak = [:] }
    }

    public func start(config: SessionConfig) async throws -> SessionFolder {
        guard state == .idle else { throw SessionError.alreadyRecording }
        sawError = false
        lastBufferTime = [:]
        starvedChannels = []
        lastSegmentEnd = [:]
        channelsInDropout = []
        gaps = []
        let startedAt = now()
        let folder = try SessionFolder.create(root: config.root, startedAt: startedAt, timeZone: config.timeZone)
        let header = SessionHeader.make(startedAt: startedAt, mode: config.mode, inputName: config.input.name, timeZone: config.timeZone)
        let sessionState = SessionState(startedAt: startedAt, mode: config.mode, input: config.input,
                                        systemAudio: config.mode == .call, engine: config.engineInfo, appVersion: config.appVersion)
        let writer = SessionWriter(folder: folder, header: header, state: sessionState)
        try await writer.start()
        if let vocabURL = config.vocabularyFileURL, FileManager.default.fileExists(atPath: vocabURL.path) {
            try? FileManager.default.copyItem(at: vocabURL, to: folder.vocabURL)
        }
        self.writer = writer

        let channels = config.mode.channels
        activeChannels = channels
        let initialClock = ChannelClock(sessionStartHostTime: hostNow(), secondsPerHostTick: secondsPerHostTick)
        self.clock = initialClock
        watchdog = SilenceWatchdog(channels: channels, period: config.silencePeriod, startTime: 0)
        rateMonitor = CaptureRateMonitor()
        health = ChannelHealth(channels: channels, asymmetryPeriod: config.asymmetryPeriod)
        reportedHeard = []
        meterPeak = [:]

        let format = await engine.preferredFormat()
        let segments = try await engine.start(channels: channels, vocabulary: config.vocabulary)
        try trackWriter.start(channels: channels, format: format, folder: folder)

        state = .recording(folder)

        for channel in channels {
            guard let source = sources[channel] else { continue }
            let stream = try await source.start()
            pumps.append(Task { [weak self] in
                for await chunk in stream {
                    guard let self else { return }
                    await self.handle(chunk, targetFormat: format)
                }
            })
        }
        segmentTask = Task { [weak self] in
            for await segment in segments {
                guard let self else { return }
                await self.record(segment)
            }
        }
        let sessionTime: @Sendable () -> TimeInterval = { [hostNow] in initialClock.sessionTime(hostTime: hostNow()) }
        let shots = shotSource.start(folder: folder, sessionTime: sessionTime)
        shotTask = Task { [weak self] in
            for await shot in shots {
                guard let self else { return }
                await self.writer?.append(.shot(shot))
            }
        }
        tickerTask = Task { [weak self, interval = tickInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                await self.tick(startedAt: startedAt)
            }
        }
        meterTask = Task { [weak self, interval = meterInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                await self.publishLevels()
            }
        }
        // The starting state — nobody heard yet, nothing wrong — is what the menu bar shows until
        // the first side speaks, so it is reported before any buffer can.
        onHealth?([], health.snapshot)
        return folder
    }

    public func stop(reason: StopReason) async {
        guard case .recording(let folder) = state else { return }
        state = .stopping
        for source in sources.values { await source.stop() }
        pumps.forEach { $0.cancel() }
        for pump in pumps { await pump.value }
        pumps = []
        tickerTask?.cancel(); tickerTask = nil
        meterTask?.cancel(); meterTask = nil
        shotSource.stop()
        await shotTask?.value; shotTask = nil
        for (channel, converter) in converters {
            if let tail = try? converter.flush(), tail.frameLength > 0 {
                let tailChunk = AudioChunk(channel: channel, buffer: tail, hostTime: hostNow())
                await engine.feed(tailChunk)
                try? trackWriter.write(tailChunk)
            }
        }
        converters = [:]

        let finishTimedOut = await withinTimeout(segmentDrainTimeout) {
            do { try await self.engine.finish() }
            catch { await self.noteError("transcription stopped: \(error.localizedDescription)") }
        }
        if finishTimedOut {
            await noteError("transcription finish timed out")
        }

        if let task = segmentTask {
            let drainTimedOut = await withinTimeout(segmentDrainTimeout, cancelling: { task.cancel() }) {
                await task.value
            }
            if drainTimedOut {
                await noteError("transcription drain timed out")
            }
        }
        segmentTask = nil
        do { try await trackWriter.finish() } catch { await noteError("audio file error: \(error.localizedDescription)") }
        await recoverDroppedSpeech(folder: folder, endingAt: elapsed())
        // An error anywhere in the session outranks the reason the stop was requested for: the
        // recording is still there, but the transcript is incomplete, and `session.json` is what
        // tells the /feedback skill and the next reader that. A clean run keeps `.user`/`.silence`.
        let outcome: StopReason = sawError ? .error : reason
        try? await writer?.stop(reason: outcome, at: now())
        writer = nil; watchdog = nil
        lastFolder = folder
        state = .idle
        onStopped?(folder, outcome)
    }

    /// Moves the microphone channel of a live session to another input device. The session keeps
    /// running: the same transcript, the same audio files, one note to say the input changed.
    /// The new device's noise floor is measured afresh, since it is a different room to the
    /// health rules and the level meter.
    ///
    /// Returns false when there is nothing to switch — no session, or no microphone channel.
    @discardableResult
    public func switchInput(uid: String?, name: String) async -> Bool {
        guard case .recording = state else { return false }
        let channel: Channel? = sources[.me] != nil ? .me : (sources[.room] != nil ? .room : nil)
        guard let channel, let source = sources[channel] else { return false }
        do {
            try await source.switchDevice(uid: uid)
        } catch {
            // A plain note, not an error: the capture falls back to the device it was already
            // using, so the recording is intact and the session's own reason still stands. If the
            // fallback failed too, the microphone has stopped delivering and the health rules say
            // so in their own words. The caller tells the person their choice did not take.
            await addNote("could not switch input to \(name): \(error.localizedDescription)")
            return false
        }
        health.resetFloor(channel: channel)
        meterPeak[channel] = nil
        // The tap's format follows the new hardware, and a converter built for the old rate would
        // resample every buffer from a rate the audio no longer has. `handle` rebuilds it when the
        // format changes, but flushing here keeps the tail of the old device's audio in the file.
        if let converter = converters[channel] {
            if let tail = try? converter.flush(), tail.frameLength > 0 {
                let tailChunk = AudioChunk(channel: channel, buffer: tail, hostTime: hostNow())
                try? trackWriter.write(tailChunk)
                await engine.feed(tailChunk)
            }
            converters[channel] = nil
        }
        // A rate mislabel is judged per device: the new one gets its own verdict, and a channel
        // already reported for drift is measured again rather than staying condemned.
        rateMonitor.forget(channel: channel)
        await report(health.set(.wrongRate, on: channel, false), at: elapsed(), noting: false)
        await addNote("input changed to \(name)")
        return true
    }

    public func addNote(_ text: String) async {
        await writer?.append(.note(NoteEvent(time: elapsed(), text: text)))
        onNote?(text)
    }

    // MARK: private

    private func elapsed() -> TimeInterval { clock?.sessionTime(hostTime: hostNow()) ?? 0 }

    /// Writes a note and marks the session as having failed, so `stop` records `stopReason: error`.
    private func noteError(_ text: String) async {
        sawError = true
        await writer?.append(.note(NoteEvent(time: elapsed(), text: text)))
    }

    /// Races `work` against a `timeout` sleep. Returns `true` if the timer wins.
    ///
    /// The bound is unconditional: it holds even when `work` awaits something that ignores
    /// cancellation. That is why `work` runs in an *unstructured* `Task` instead of as a child of
    /// the task group. A task group cannot return while any of its children is still suspended, and
    /// a child suspended inside an await that never resumes (a continuation nobody resumes, a
    /// blocking C call) stays suspended however hard it is cancelled — so awaiting `work` as a
    /// group child would only bound cooperative work. Instead the unstructured task signals its
    /// completion by yielding once into an `AsyncStream` and finishing it, and the group races two
    /// children that are both cancellation-aware by construction: one iterating that stream
    /// (`AsyncStream` iteration always observes cancellation), one sleeping for `timeout`. Whichever
    /// loses is cancelled and returns promptly, so the group always exits.
    ///
    /// On timeout the `cancelling` hook runs — pass a separately-owned task's `cancel()` here, as
    /// the segment drain does, since cancelling this helper's own tasks does not reach it — and the
    /// work task is cancelled too. Work that ignores that cancellation is then abandoned: its task,
    /// and everything the task holds, leak until it completes on its own. That is deliberate. The
    /// only caller is session teardown, where returning the actor to a usable `.idle` state matters
    /// more than reclaiming a wedged engine's memory.
    private func withinTimeout(_ timeout: Duration, cancelling cancel: @escaping @Sendable () -> Void = {},
                               _ work: @escaping @Sendable () async -> Void) async -> Bool {
        let (done, signal) = AsyncStream<Void>.makeStream()      // unbounded: a yield before anyone iterates is kept
        let workTask = Task.detached {
            await work()
            signal.yield(())
            signal.finish()
        }
        return await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                for await _ in done { break }
                return false
            }
            group.addTask { try? await Task.sleep(for: timeout); return true }
            let timedOut = await group.next() ?? false
            if timedOut {
                cancel()             // ends the separately-owned operation, if the caller named one
                workTask.cancel()    // and asks the abandoned work to unwind, if it ever cooperates
            }
            group.cancelAll()
            return timedOut
        }
    }

    private func handle(_ chunk: AudioChunk, targetFormat: AVAudioFormat) async {
        guard case .recording = state else { return }
        clock?.noteBuffer(channel: chunk.channel, hostTime: chunk.hostTime)
        let arrival = clock?.sessionTime(hostTime: chunk.hostTime) ?? 0
        lastBufferTime[chunk.channel] = arrival
        if starvedChannels.remove(chunk.channel) != nil {
            await writer?.append(.note(NoteEvent(time: arrival, text: "\(chunk.channel.label) audio resumed")))
            await report(health.set(.noAudio, on: chunk.channel, false), at: arrival, noting: false)
        }
        if let existing = converters[chunk.channel], existing.inputFormat != chunk.buffer.format {
            if let tail = try? existing.flush(), tail.frameLength > 0 {
                let tailChunk = AudioChunk(channel: chunk.channel, buffer: tail, hostTime: chunk.hostTime)
                try? trackWriter.write(tailChunk)
                await engine.feed(tailChunk)
            }
            converters[chunk.channel] = nil
        }
        let converted: AVAudioPCMBuffer
        do {
            if converters[chunk.channel] == nil {
                converters[chunk.channel] = try FormatConverter(from: chunk.buffer.format, to: targetFormat)
            }
            converted = try converters[chunk.channel]!.convert(chunk.buffer)
        } catch {
            await noteError("audio conversion failed on \(chunk.channel.label): \(error)")
            return
        }
        let out = AudioChunk(channel: chunk.channel, buffer: converted, hostTime: chunk.hostTime)
        // Read `converted` for our own purposes before handing it to `engine.feed`: a real
        // SpeechAnalyzer consumes fed buffers on its own worker thread with no promise that the
        // caller's copy stays valid afterward, so reading it back after `feed` races that
        // consumption (this is what crashed the shipped app on 2026-09-03).
        try? trackWriter.write(out)
        let level = AudioLevel.rmsDBFS(converted)
        if onLevels != nil { meterPeak[chunk.channel] = max(meterPeak[chunk.channel] ?? level, level) }
        // A capture that is wrong about its hardware's rate still looks healthy from here:
        // buffers arrive, levels move, the file grows. Only the length of the audio against the
        // time it took to arrive gives it away.
        let audioSeconds = Double(converted.frameLength) / targetFormat.sampleRate
        if let note = rateMonitor.observe(channel: chunk.channel, audioSeconds: audioSeconds, at: arrival) {
            await noteError(note)
            await report(health.set(.wrongRate, on: chunk.channel, true), at: arrival, noting: false)
        }
        await report(health.observeAudio(channel: chunk.channel, levelDBFS: level, audioSeconds: audioSeconds, at: arrival), at: arrival)
        await engine.feed(out)
        if watchdog?.observe(levelDBFS: level, channel: chunk.channel, at: arrival) == true {
            watchdog = nil
            Task { await self.stop(reason: .silence) }
        }
    }

    private func record(_ segment: TranscriptSegment) async {
        guard let clock else { return }
        let start = clock.sessionTime(channel: segment.channel, analyzerTime: segment.start)
        // An engine reports a failed result stream as a pseudo-segment. Writing it as a turn would
        // attribute the failure to a speaker and let it merge into a neighbouring line; it belongs
        // in the transcript as a note, and it is why the session stops with `stopReason: error`.
        guard !segment.isEngineError else {
            sawError = true
            await writer?.append(.note(NoteEvent(time: start, text: segment.engineErrorNoteText)))
            return
        }
        var aligned = segment
        aligned.start = start
        aligned.end = clock.sessionTime(channel: segment.channel, analyzerTime: segment.end)
        if channelsInDropout.remove(segment.channel) != nil {
            gaps.append(TranscriptGap(channel: segment.channel,
                                      start: lastSegmentEnd[segment.channel] ?? 0, end: aligned.start))
        }
        lastSegmentEnd[segment.channel] = max(lastSegmentEnd[segment.channel] ?? 0, aligned.end)
        await writer?.append(.turn(aligned))
        await report(health.observeSegment(channel: segment.channel, start: aligned.start, end: aligned.end), at: aligned.end)
    }

    private func tick(startedAt: Date) async {
        guard case .recording = state else { return }
        await writer?.updateDuration(Int(now().timeIntervalSince(startedAt)))
        await noteStarvedChannels()
        let sessionSeconds = elapsed()
        await report(health.observeTime(sessionSeconds), at: sessionSeconds)
    }

    /// Hands the listener every active channel's loudest level since the last report, read against
    /// that channel's floor. A channel that delivered nothing in the interval reads 0, so a meter
    /// for a silent tap rests at empty rather than freezing at its last value.
    private func publishLevels() {
        guard case .recording = state, let onLevels else { return }
        var fractions: [Channel: Double] = [:]
        for channel in activeChannels {
            fractions[channel] = meterPeak[channel].map { health.meterFraction(channel: channel, levelDBFS: $0) } ?? 0
        }
        meterPeak = [:]
        onLevels(fractions)
    }

    /// Writes the transitions the health monitor found as transcript notes and hands them, with
    /// the state they produced, to the health callback. `noting: false` is for conditions whose
    /// note the caller has already written in its own words — starvation and rate drift keep the
    /// notes they had before they were also health issues. The callback also fires when no issue
    /// moved but a side was heard for the first time, since the icon shows that too.
    private func report(_ changes: [HealthChange], at time: TimeInterval, noting: Bool = true) async {
        if noting {
            for change in changes {
                await writer?.append(.note(NoteEvent(time: time, text: change.text)))
            }
        }
        // With nothing on the system-audio side, the microphone is not one speaker's half of a call
        // — it is the only record of it, the other party included. The transcript says so by
        // labelling its lines Room. Only ever the system-audio side: the mirror case, a dead
        // microphone with system audio working, leaves Them meaning exactly what it always did.
        for change in changes where change.issue == .oneSidedRecording && change.channel == .them {
            await writer?.setMicCarriedTheCall(change.raised)
        }
        // A dropout opens where the transcriber stopped producing lines from audible speech. Its
        // far end is set by the line that ends it, in `record`.
        for change in changes where change.issue == .noTranscript && change.raised {
            channelsInDropout.insert(change.channel)
        }
        guard !changes.isEmpty || health.heard != reportedHeard else { return }
        reportedHeard = health.heard
        await writer?.updateHeard(activeChannels.filter { health.heard.contains($0) })
        onHealth?(changes, health.snapshot)
    }

    /// Re-transcribes the stretches this session annotated as speech that produced no transcript,
    /// now that the audio files are closed and final.
    ///
    /// Gap annotations bound the audio to retry. Recover only those ranges rather than
    /// retranscribing the whole recording.
    ///
    /// Anything recovered is written as ordinary turns, which sort into place by their timestamps,
    /// behind a note naming the stretch and the engine that read it — the transcript should never
    /// quietly mix two recognisers. A failure is a note and nothing else: the session's own
    /// transcript is intact either way, and the recording has already stopped.
    private func recoverDroppedSpeech(folder: SessionFolder, endingAt sessionEnd: TimeInterval) async {
        guard let backfill else { return }
        // A dropout still open at stop has no line to close it, so the session's end does.
        for channel in activeChannels where channelsInDropout.contains(channel) {
            gaps.append(TranscriptGap(channel: channel, start: lastSegmentEnd[channel] ?? 0, end: sessionEnd))
        }
        channelsInDropout = []
        let pending = gaps.filter { $0.seconds > 0 }
        guard !pending.isEmpty else { return }
        do {
            let recovered = try await backfill.recover(gaps: pending, folder: folder)
            for gap in pending {
                let found = recovered.filter { $0.channel == gap.channel && $0.start >= gap.start && $0.start < gap.end }
                let what = found.isEmpty ? "nothing found" : "\(found.count) line(s) recovered"
                await writer?.append(.note(NoteEvent(time: gap.start,
                                                     text: "\(gap.channel.label): \(Int(gap.seconds.rounded())) s re-read by whisper, \(what)")))
            }
            for segment in recovered { await writer?.append(.turn(segment)) }
        } catch {
            await writer?.append(.note(NoteEvent(time: sessionEnd,
                                                 text: "could not re-read the untranscribed audio: \(error.localizedDescription)")))
        }
    }

    /// A channel that delivered audio and then went quiet — the output device changed, the machine
    /// slept, the tap died — otherwise leaves no trace at all: the recording simply has nothing on
    /// that side and the transcript does not say why. One note when the gap opens, one when buffers
    /// return. A channel that has never delivered is skipped; Start already refuses when a source
    /// cannot open, so there is nothing there to have lost.
    ///
    /// This is not treated as an error: an unplugged headset mid-call is routine, the note is the
    /// whole remedy, and marking the session `error` for it would hide genuine engine failures.
    private func noteStarvedChannels() async {
        let sessionSeconds = elapsed()
        for channel in activeChannels {
            guard let last = lastBufferTime[channel], sessionSeconds - last > starvationTimeout else { continue }
            guard starvedChannels.insert(channel).inserted else { continue }
            await writer?.append(.note(NoteEvent(time: sessionSeconds, text: "\(channel.label) audio stopped delivering")))
            await report(health.set(.noAudio, on: channel, true), at: sessionSeconds, noting: false)
        }
    }
}
