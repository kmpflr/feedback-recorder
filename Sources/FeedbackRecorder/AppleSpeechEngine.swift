import Foundation
import AVFAudio
import Speech
import FeedbackCore

/// One SpeechAnalyzer per channel. Final results only, so transcript lines never change after they are written.
final class AppleSpeechEngine: TranscriptionEngine, @unchecked Sendable {
    private struct ChannelSession {
        let analyzer: SpeechAnalyzer
        let transcriber: SpeechTranscriber
        let input: AsyncStream<AnalyzerInput>.Continuation
        let reader: Task<Void, Never>
    }

    private let locale: Locale
    private var sessions: [Channel: ChannelSession] = [:]
    private var output: AsyncStream<TranscriptSegment>.Continuation?
    private var format: AVAudioFormat?
    /// Newest result end time per channel, in that channel's analyzer clock. Read only when the
    /// channel's result stream fails, to stamp the error note where transcription stopped.
    /// One reader task per channel writes it, so the lock is not optional.
    private let lock = NSLock()
    private var lastEnd: [Channel: TimeInterval] = [:]

    init(localeIdentifier: String) { locale = Locale(identifier: localeIdentifier) }

    var engineInfo: EngineInfo { EngineInfo(name: "apple-speech", module: "SpeechTranscriber", locale: locale.identifier) }

    static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
    }

    static func ensureAssets(localeIdentifier: String) async throws {
        let transcriber = makeTranscriber(locale: Locale(identifier: localeIdentifier))
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    func preferredFormat() async -> AVAudioFormat {
        if let format { return format }
        let transcriber = Self.makeTranscriber(locale: locale)
        let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            ?? AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        format = best
        return best
    }

    /// Pass vocabulary through the analyzer's contextual strings; the transcriber initializer
    /// does not take phrase hints directly.
    ///
    /// Contextual strings bias the recogniser toward the spellings; they do not guarantee them, and
    /// `SFCustomLanguageModelData` is the heavier tool if this proves not to be enough. The
    /// `vocab.txt` copy in the session folder still reaches the /feedback skill for what gets
    /// through regardless.
    func start(channels: [Channel], vocabulary: [String]) async throws -> AsyncStream<TranscriptSegment> {
        let (stream, cont) = AsyncStream<TranscriptSegment>.makeStream()
        output = cont
        resetEnds()
        for channel in channels {
            let transcriber = Self.makeTranscriber(locale: locale)
            let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            // One context per channel rather than one shared between them: `AnalysisContext` is a
            // reference type, and the two analyzers run on separate tasks.
            if !vocabulary.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings[.general] = vocabulary
                try await analyzer.setContext(context)
            }
            try await analyzer.start(inputSequence: inputSequence)
            let reader = Task { [weak self] in
                do {
                    for try await result in transcriber.results where result.isFinal {
                        let range = result.range
                        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                        self?.noteEnd(range.end.seconds, for: channel)
                        guard !text.isEmpty else { continue }
                        self?.output?.yield(TranscriptSegment(channel: channel, start: range.start.seconds,
                                                              end: range.end.seconds, text: text))
                    }
                } catch {
                    // Stamped at the last result this channel produced, so the note lands where
                    // transcription stopped. A zero would put it at [00:00], ahead of the whole
                    // session, where a reader takes it for a failure to start.
                    let at = self?.end(for: channel) ?? 0
                    self?.output?.yield(.engineError(channel: channel, at: at, message: error.localizedDescription))
                }
            }
            sessions[channel] = ChannelSession(analyzer: analyzer, transcriber: transcriber, input: inputBuilder, reader: reader)
        }
        return stream
    }

    func feed(_ chunk: AudioChunk) async {
        guard let session = sessions[chunk.channel] else { return }
        session.input.yield(AnalyzerInput(buffer: chunk.buffer))
        fedChannels.insert(chunk.channel)
    }

    /// Finalizes every channel that received audio, all channels at once, and simply tears down
    /// the ones that never did. `finalizeAndFinishThroughEndOfInput()` does not return for an
    /// analyzer that was started but never fed — the system-audio channel of a call in which
    /// nothing played — and its result stream never ends either, so both must be skipped or
    /// stop() only completes when the controller's timeout gives up on it.
    func finish() async throws {
        for session in sessions.values { session.input.finish() }
        let starved = sessions.filter { !fedChannels.contains($0.key) }
        for (_, session) in starved { session.reader.cancel() }
        let fed = sessions.filter { fedChannels.contains($0.key) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (_, session) in fed {
                group.addTask { try await session.analyzer.finalizeAndFinishThroughEndOfInput() }
            }
            try await group.waitForAll()
        }
        for (_, session) in fed { await session.reader.value }
        sessions = [:]
        fedChannels = []
        output?.finish(); output = nil
    }

    /// Channels that have received at least one buffer this session; see `finish()`.
    private var fedChannels: Set<Channel> = []

    // MARK: last-result bookkeeping
    //
    // Synchronous (non-async) so NSLock's lock/unlock, which are unavailable in async contexts,
    // stay confined here — the same shape `MicCapture` uses.

    private func noteEnd(_ end: TimeInterval, for channel: Channel) {
        lock.withLock { lastEnd[channel] = end }
    }

    private func end(for channel: Channel) -> TimeInterval {
        lock.withLock { lastEnd[channel] ?? 0 }
    }

    private func resetEnds() {
        lock.withLock { lastEnd = [:] }
    }
}
