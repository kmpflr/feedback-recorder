import AppKit
import FeedbackCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: StatusItemController!
    private var hotkey: HotkeyController?
    private var controller: SessionController!
    private var preflight: Preflight.Report?
    private var starting = false
    /// Mirrors `controller.state == .recording` so `applicationShouldTerminate` — which cannot
    /// await the actor — can decide synchronously. Set on a successful start, cleared in `didStop`.
    private var isRecording = false
    /// The folder of the session this delegate believes is live, so `didStop` can tell its own
    /// session's callback from a stale one. Set on a successful start, cleared in `didStop`.
    private var liveFolder: SessionFolder?
    /// The shot-count poller for the live session, cancelled in `didStop`.
    private var shotPoller: Task<Void, Never>?
    /// Set when termination is deferred, so whichever stop is in flight can answer AppKit from
    /// `didStop`. Checked and cleared on the main actor, so exactly one reply is ever sent.
    private var terminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.registerDefaults()
        Notifier.requestAuthorization()
        status = StatusItemController()
        status.hotkeyLabel = HotkeyController.describe(keyCode: Settings.hotkeyKeyCode, modifiers: Settings.hotkeyModifiers)
        controller = SessionController(
            sources: [:],                                  // replaced per session in start()
            engine: AppleSpeechEngine(localeIdentifier: Settings.localeIdentifier),
            trackWriter: AudioTrackWriter(), shotSource: PasteboardShotSource(),
            backfill: WhisperBackfill(localeIdentifier: Settings.localeIdentifier))
        wireMenu()
        do {
            hotkey = try HotkeyController(keyCode: Settings.hotkeyKeyCode, modifiers: Settings.hotkeyModifiers) { [weak self] in
                Task { @MainActor in self?.toggle() }
            }
        } catch {
            Notifier.post(title: "Hotkey unavailable", body: "Could not register \(status.hotkeyLabel): \(error.localizedDescription)")
        }
        Task {
            let report = await Preflight.run()
            preflight = report
            if !report.recovered.isEmpty {
                Notifier.post(title: "Recovered \(report.recovered.count) interrupted session(s)", body: report.recovered.map(\.lastPathComponent).joined(separator: ", "))
            }
            for problem in report.problems { Notifier.post(title: "Feedback Recorder", body: problem) }
        }
    }

    /// Quit during a session has to finish it first: without this the process exits with
    /// `session.json` still saying `recording` and the WAVs never transcoded to m4a.
    ///
    /// The reply is sent from `didStop`, not from here. Replying after our own
    /// `stop(reason: .user)` returns would be wrong when a stop is *already* in flight — that call
    /// is a no-op, since `SessionController.stop()` guards on `.recording`, so it would return
    /// immediately and terminate the process while the original stop was still inside
    /// `trackWriter.finish()` and `writer.stop()`. `didStop` is reached exactly once, by whichever
    /// stop is in flight, and only after the session is finalized, copied and announced.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard isRecording else { return .terminateNow }
        terminationPending = true
        status.setStopping()
        Task {
            // A stale `isRecording` — only reachable if `didStop` never ran — would otherwise
            // leave AppKit waiting forever, since nothing is left to answer it.
            if await controller.state == .idle {
                if terminationPending {
                    terminationPending = false
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
                return
            }
            await controller.stop(reason: .user)
        }
        return .terminateLater
    }

    private func wireMenu() {
        status.onToggle = { [weak self] in self?.toggle() }
        status.onCopyCommand = { [weak self] in Task { await self?.copyCommand() } }
        status.onOpenSession = { [weak self] in Task { await self?.openSession() } }
        status.onChooseInput = { [weak self] uid in
            Settings.inputDeviceUID = uid
            self?.applyInputChoice(uid)
        }
        status.onToggleSystemAudio = { Settings.captureSystemAudio.toggle() }
        status.onSilenceMinutes = { Settings.silenceMinutes = $0 }
        status.onAsymmetryMinutes = { Settings.asymmetryMinutes = $0 }
        status.onToggleLevelMeters = { [weak self] in
            Settings.showLevelMeters.toggle()
            guard let self else { return }
            self.status.refreshIcon()
            let session: SessionController = self.controller
            Task { await session.setOnLevels(self.levelsHandler(for: session)) }
        }
    }

    /// The meter listener for `session`, or nil when meters are off. Levels arrive ten times a
    /// second, so the identity check keeps a replaced session's last reports off the new icon.
    private func levelsHandler(for session: SessionController) -> (@Sendable ([Channel: Double]) -> Void)? {
        guard Settings.showLevelMeters else { return nil }
        return { [weak self] levels in
            Task { @MainActor in
                guard let self, self.controller === session else { return }
                self.status.setLevels(levels)
            }
        }
    }

    private func toggle() {
        Task {
            switch await controller.state {
            case .idle: await start()
            case .recording:
                status.setStopping()
                await controller.stop(reason: .user)
            case .stopping: break
            }
        }
    }

    private func start() async {
        // `toggle()` reads the controller's state and then awaits, and setup below awaits again
        // before the controller reaches `.recording`. Two presses inside that window would each
        // build a fresh controller, orphaning the first with a live microphone and a session
        // folder nothing can stop. The flag is set before the first await, so it excludes.
        guard !starting else { return }
        starting = true
        defer { starting = false }

        // tccd resolves the process to its binary on disk before it grants the microphone or the
        // system audio tap. Once that binary is deleted (a worktree removed, the Trash emptied)
        // the lookup fails, and CoreAudio hands both channels silence without an error, so the
        // session would record minutes of nothing. The permission checks below cannot see this.
        if let executable = Bundle.main.executablePath, !FileManager.default.fileExists(atPath: executable) {
            Notifier.post(title: "Cannot start",
                          body: "This copy of Feedback Recorder was deleted or moved while running, so macOS may give it only silence. Quit it and open the installed app.")
            return
        }

        let mode: SessionMode = Settings.captureSystemAudio ? .call : .room
        if mode == .call, preflight?.systemAudio == false {
            Notifier.post(title: "Cannot start in call mode", body: "System audio recording is not permitted. Allow it in Privacy & Security or turn off Capture system audio for room mode.")
            return
        }
        guard preflight?.microphone != false else {
            Notifier.post(title: "Cannot start", body: "Microphone access is denied."); return
        }
        // Without the model, `SpeechAnalyzer.start` fails per channel and every turn is lost while
        // the session records on regardless. Refusing here says why, once, before anything is
        // created. Preflight installs the assets at launch, so this is the offline case.
        guard preflight?.assets != false else {
            Notifier.post(title: "Cannot start",
                          body: "Speech model assets for \(Settings.localeIdentifier) are not installed. Connect to the network and relaunch.")
            return
        }
        var input = InputDevices.defaultInput() ?? InputDevice(name: "Default input", uid: "")
        var fallbackNote: String?
        if let uid = Settings.inputDeviceUID {
            if let chosen = InputDevices.list().first(where: { $0.uid == uid }) { input = chosen }
            else { fallbackNote = "chosen input not connected; using \(input.name)" }
        }
        let micChannel: Channel = mode == .call ? .me : .room
        var sources: [Channel: any AudioSource] = [
            micChannel: MicCapture(channel: micChannel, deviceUID: Settings.inputDeviceUID) { [weak self] note in
                Task { await self?.controller.addNote(note) }
            },
        ]
        if mode == .call { sources[.them] = SystemAudioCapture() }
        // A fresh engine per session: SessionController.stop() may abandon a non-cooperative
        // engine.finish(), and reusing the instance would let that leaked call race the new session.
        let engine = AppleSpeechEngine(localeIdentifier: Settings.localeIdentifier)
        let shots = PasteboardShotSource { [weak self] note in
            Task { await self?.controller.addNote(note) }
        }
        let session = SessionController(sources: sources, engine: engine, trackWriter: AudioTrackWriter(), shotSource: shots,
                                        backfill: WhisperBackfill(localeIdentifier: Settings.localeIdentifier))
        controller = session
        await session.setOnStopped { [weak self] folder, reason in
            Task { @MainActor in self?.didStop(folder: folder, reason: reason) }
        }
        await session.setOnHealth { [weak self] changes, snapshot in
            Task { @MainActor in self?.healthChanged(changes, snapshot, from: session) }
        }
        await session.setOnLevels(levelsHandler(for: session))
        let config = SessionConfig(root: Settings.sessionRoot, mode: mode, input: input, locale: Settings.localeIdentifier,
                                   vocabulary: Vocabulary.load(from: Settings.vocabularyURL), vocabularyFileURL: Settings.vocabularyURL,
                                   silencePeriod: Settings.silencePeriod, asymmetryPeriod: Settings.asymmetryPeriod,
                                   engineInfo: engine.engineInfo, appVersion: Settings.appVersion)
        do {
            let folder = try await controller.start(config: config)
            isRecording = true
            liveFolder = folder
            if let fallbackNote { await controller.addNote(fallbackNote) }
            status.setRecording(inputName: input.name)
            Notifier.post(title: "Recording", body: "\(input.name) · system audio \(mode == .call ? "on" : "off")\(fallbackNote.map { " · " + $0 } ?? "")")
            observeShots(folder: folder)
        } catch {
            // `SessionController.start` reaches `.recording` before it starts the sources, and in
            // call mode the microphone starts first. So a throw from `SystemAudioCapture.start()`
            // leaves the mic engine running and pumping into a live writer. Stopping tears down
            // every source, finalizes the writer and fires `didStop`'s `.error` arm; it is a no-op
            // if the throw came before `.recording`.
            await controller.stop(reason: .error)
            Notifier.post(title: "Could not start", body: error.localizedDescription)
        }
    }

    /// Shot count for the menu title: poll `session.json` counts every 2 s while this session runs.
    ///
    /// The loop is bound to `folder`, not to "is anything recording". `start()` replaces
    /// `self.controller`, so a poller that only tested the state would survive its own session and
    /// keep polling the next one — one live poller per session started, each writing the menu title.
    /// `didStop` cancels it as well, so the last session's poller does not outlive its session by
    /// up to two seconds.
    private func observeShots(folder: SessionFolder) {
        shotPoller?.cancel()
        shotPoller = Task { [weak self] in
            while !Task.isCancelled, let self, await self.controller.currentFolder == folder {
                if let data = try? Data(contentsOf: folder.stateURL),
                   let state = try? SessionState.decoder.decode(SessionState.self, from: data) {
                    self.status.setShotCount(state.counts.shots)
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Moves a live session onto the chosen input. Picking a device from the menu used to change
    /// only the setting, so a session kept recording from the device it started with and nothing
    /// said otherwise. Idle is nothing to do: the choice is already saved for the next session.
    private func applyInputChoice(_ uid: String?) {
        guard isRecording else { return }
        let device = uid.flatMap { id in InputDevices.list().first { $0.uid == id } }
        guard uid == nil || device != nil else {
            Notifier.post(title: "Input not switched", body: "That input is no longer connected.")
            return
        }
        let name = device?.name ?? InputDevices.defaultInput()?.name ?? "the system default input"
        let session: SessionController = controller
        Task {
            let switched = await session.switchInput(uid: uid, name: name)
            guard switched else {
                Notifier.post(title: "Input not switched", body: "Still recording from \(status.currentInputName).")
                return
            }
            // The menu header reads the device name it was given when the session started.
            status.setInputName(name)
            Notifier.post(title: "Input switched", body: "Now recording from \(name).")
        }
    }

    /// Health reaches here from whichever session raised it, on a main-actor hop that can land
    /// after that session has been replaced. Only the current session's state may paint the icon.
    /// The first report arrives while `start()` is still awaiting, before `isRecording` is set, so
    /// the icon takes it unconditionally; notifications wait for a session that is actually live,
    /// since a raise that lands after `didStop` would otherwise announce a problem with a
    /// recording that is already over.
    private func healthChanged(_ changes: [HealthChange], _ snapshot: HealthSnapshot, from session: SessionController) {
        guard controller === session else { return }
        status.setHealth(snapshot)
        guard isRecording else { return }
        for change in changes where change.raised {
            // A side nobody is ever heard on is not a side that may be failing: the tap is working
            // and there is simply nothing on it. Saying so sends you looking in the wrong place.
            let title = change.issue == .oneSidedRecording
                ? "Recording only one side of this call"
                : "\(change.channel.label) may not be recording"
            Notifier.post(title: title, body: change.text)
        }
    }

    private func didStop(folder: SessionFolder, reason: StopReason) {
        // Every session installs its own `onStopped`, but the callback hops to the main actor, so a
        // hop enqueued by session N can run after session N+1 has started and put the menu bar into
        // recording. Honouring it there would show idle during a live session and copy the wrong
        // /feedback path. The callback is this session's when it names the folder believed live;
        // when nothing is live — a start that threw after creating its folder, so `liveFolder` was
        // never set — there is no session state to corrupt and the callback is honoured.
        guard liveFolder == nil || liveFolder == folder else { return }
        liveFolder = nil
        isRecording = false
        shotPoller?.cancel(); shotPoller = nil
        status.setIdle()
        copy(folder.feedbackCommand(for: Settings.feedbackAgent))
        let why: String = switch reason {
        case .user: "Stopped"
        case .silence: "Stopped after \(Settings.silenceMinutes) minutes of silence"
        // `.crash` is written by `SessionRecovery` at the next launch, which reports through
        // Preflight's own notification and never reaches a stop callback.
        case .error, .crash: "Stopped after an error"
        }
        Notifier.post(title: why, body: "\(Settings.feedbackAgent.displayName) feedback command copied · \(folder.url.lastPathComponent)")
        if terminationPending {
            terminationPending = false
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }

    /// The session in progress, else the last one stopped this launch, else the newest one on disk.
    /// Each actor property needs its own `await`: the right-hand side of `??` is an autoclosure,
    /// which cannot be asynchronous.
    private func latestFolder() async -> SessionFolder? {
        if let current = await controller.currentFolder { return current }
        if let last = await controller.lastFolder { return last }
        return SessionRecovery.newestSession(root: Settings.sessionRoot)
    }

    private func copyCommand() async {
        guard let folder = await latestFolder() else {
            Notifier.post(title: "No session yet", body: "Start a session first."); return
        }
        let command = folder.feedbackCommand(for: Settings.feedbackAgent)
        copy(command)
        Notifier.post(title: "Copied for \(Settings.feedbackAgent.displayName)", body: command)
    }

    private func openSession() async {
        if let folder = await latestFolder() {
            NSWorkspace.shared.open(folder.url)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
