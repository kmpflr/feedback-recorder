import Foundation

/// The single writer to a session folder. Rewrites transcript.md and session.json atomically.
public actor SessionWriter {
    public let folder: SessionFolder
    private let header: SessionHeader
    private var state: SessionState
    private var events: [TranscriptEvent] = []
    private var micCarriedTheCall = false
    private let debounce: Duration
    private let onError: @Sendable (String) -> Void
    private var flushTask: Task<Void, Never>?

    public init(folder: SessionFolder, header: SessionHeader, state: SessionState, debounce: Duration = .milliseconds(500),
                onError: @escaping @Sendable (String) -> Void = { _ in }) {
        self.folder = folder; self.header = header; self.state = state; self.debounce = debounce; self.onError = onError
    }

    public func start() throws { try flush() }

    public func append(_ event: TranscriptEvent) {
        events.append(event)
        switch event {
        case .turn: state.counts.segments += 1
        case .shot: state.counts.shots += 1
        case .note: break
        }
        scheduleFlush()
    }

    public func updateDuration(_ seconds: Int) {
        state.durationSeconds = seconds
        scheduleFlush()
    }

    /// The call turned out to have only the microphone on it, so its lines are the whole
    /// conversation rather than one speaker's half. Re-renders the transcript: the labels of lines
    /// already written change with it, which is the point — they were wrong when written.
    public func setMicCarriedTheCall(_ value: Bool) {
        guard micCarriedTheCall != value else { return }
        micCarriedTheCall = value
        scheduleFlush()
    }

    /// Records which sides speech has been heard on, in `channels` order so the file does not
    /// churn on set ordering.
    public func updateHeard(_ heard: [Channel]) {
        guard state.heard != heard else { return }
        state.heard = heard
        scheduleFlush()
    }

    public func stop(reason: StopReason, at date: Date) throws {
        flushTask?.cancel(); flushTask = nil
        state.stop(reason: reason, at: date)
        try flush()
    }

    public func flush() throws {
        let transcript = TranscriptFormatter.render(header: header, events: events, micCarriedTheCall: micCarriedTheCall)
        try Data(transcript.utf8).write(to: folder.transcriptURL, options: .atomic)
        try SessionState.encoder.encode(state).write(to: folder.stateURL, options: .atomic)
    }

    private func flushScheduled() {
        flushTask = nil
        do { try flush() }
        catch { onError(error.localizedDescription) }
    }

    private func scheduleFlush() {
        // Continuous events must not postpone every write indefinitely.
        guard flushTask == nil else { return }
        let delay = debounce
        flushTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            await self.flushScheduled()
        }
    }
}
