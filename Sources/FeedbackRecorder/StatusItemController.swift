import AppKit
import FeedbackCore

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var recordingSince: Date?
    private var stopping = false
    private var shotCount = 0
    private var inputName = ""
    private var lastTitle = ""
    /// Live only while the menu is open: the header carries a running clock, and `menuNeedsUpdate`
    /// fires once per opening, so the item's title has to be rewritten in place.
    private var headerTicker: Timer?
    private weak var headerItem: NSMenuItem?
    private weak var healthItem: NSMenuItem?
    /// The live session's per-side health, as last reported. Kept across `setRecording`, since the
    /// initial state arrives while the session is still starting; cleared by `setIdle`.
    private var health: HealthSnapshot?
    /// What the level meters show right now, per side, 0…1, smoothed by `ballistics` so a syllable
    /// lifts a bar rather than flashing it, and a pause lets it settle rather than snap.
    private var levels: [Channel: Double] = [:]
    private static let ballistics = MeterBallistics()
    /// Every symbol the item shows is drawn at this size. The default configuration renders the
    /// circle 13 pt across, visibly smaller than the user-switching menu extra beside it, which
    /// draws 14 pt. 14 pt matches that neighbour exactly.
    ///
    /// Do not raise it: on a menu bar 24 pt tall, which is every display that is not the built-in
    /// one on a notched Mac, a 15 pt symbol is drawn with its top and bottom cut off, measured as
    /// a 16 x 11 px band where 14 pt gives a whole 14 x 14 px circle. The clipping follows the
    /// symbol's point size, not the image box, so resizing the image does not avoid it.
    private static let symbolSize = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)

    var onToggle: (() -> Void)?
    var onCopyCommand: (() -> Void)?
    var onOpenSession: (() -> Void)?
    var onChooseInput: ((String?) -> Void)?           // nil = follow system default
    var onToggleSystemAudio: (() -> Void)?
    var onSilenceMinutes: ((Int) -> Void)?
    var onAsymmetryMinutes: ((Int) -> Void)?
    var onToggleLevelMeters: (() -> Void)?
    var hotkeyLabel = ""

    override init() {
        super.init()
        // No standing menu: a plain click starts recording; the menu is shown on demand
        // for right-click, Control-click or Cmd-click (see `statusItemClicked`).
        menu.delegate = self
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Click to start recording; click again and choose Stop to end it. Right-click or Cmd-click for the menu."
            // Monospaced digits keep the shot count's width steady as it grows. Setting only the
            // font leaves the colour automatic, so the text still follows the menu bar's own
            // appearance rather than being drawn black on a dark bar.
            let size = button.font?.pointSize ?? NSFont.systemFontSize
            button.font = .monospacedDigitSystemFont(ofSize: size, weight: .regular)
        }
        // `menuNeedsUpdate` sets each item's enabled state itself. Automatic validation would run
        // afterwards and re-enable anything without a `validateMenuItem`, undoing the deliberate
        // `isEnabled = false` on the header, the hotkey label and "Capture system audio" while
        // recording. No item here relies on automatic validation.
        menu.autoenablesItems = false
        setIdle()
    }

    func setRecording(inputName: String) {
        recordingSince = Date(); shotCount = 0; self.inputName = inputName
        levels = [:]
        repaintIcon()
        item.button?.contentTintColor = nil
        updateTitle()
    }

    /// The per-side state of the live session. Stored even before `setRecording`, so the state
    /// reported while the session starts is what the icon shows the moment it turns to recording.
    func setHealth(_ snapshot: HealthSnapshot) {
        health = snapshot
        guard recordingSince != nil, !stopping else { return }
        repaintIcon()
        healthItem?.title = healthLine() ?? ""
    }

    /// The input device the live session is recording from, as the menu header shows it.
    var currentInputName: String { inputName }

    /// The input device the live session is recording from, after a mid-session switch.
    func setInputName(_ name: String) {
        inputName = name
        headerItem?.title = headerTitle()
    }

    /// Fresh per-side levels, 0…1 above each side's floor.
    func setLevels(_ fractions: [Channel: Double]) {
        for (channel, fraction) in fractions {
            levels[channel] = Self.ballistics.next(shown: levels[channel] ?? 0, measured: fraction)
        }
        guard recordingSince != nil, !stopping, Settings.showLevelMeters else { return }
        repaintIcon()
    }

    /// The meters were switched on or off; redraw with or without them.
    func refreshIcon() {
        guard recordingSince != nil, !stopping else { return }
        if !Settings.showLevelMeters { levels = [:] }
        repaintIcon()
    }

    private func repaintIcon() {
        item.button?.image = Settings.showLevelMeters ? meteredImage() : recordingImage()
    }

    /// The health icon with one level bar per side beside it, in one image of constant size so the
    /// status item never relayouts while recording. Me (or Room) is the left bar in blue, Them the
    /// right in teal; a side with an open issue draws its bar orange.
    private func meteredImage() -> NSImage? {
        guard let icon = recordingImage() else { return nil }
        let channels = health?.channels ?? [.me, .them]
        let barWidth: CGFloat = 3, barGap: CGFloat = 2, lead: CGFloat = 4, barHeight: CGFloat = 13
        let iconSize = icon.size
        let width = iconSize.width + lead + CGFloat(channels.count) * barWidth + CGFloat(max(0, channels.count - 1)) * barGap
        let height = max(iconSize.height, barHeight)
        let levels = self.levels, issues = health?.issues ?? [:]
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            icon.draw(in: NSRect(x: 0, y: (height - iconSize.height) / 2, width: iconSize.width, height: iconSize.height))
            var x = iconSize.width + lead
            let y = (height - barHeight) / 2
            for channel in channels {
                let track = NSRect(x: x, y: y, width: barWidth, height: barHeight)
                NSColor.secondaryLabelColor.withAlphaComponent(0.35).setFill()
                NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()
                let fraction = levels[channel] ?? 0
                if fraction > 0 {
                    let colour: NSColor = issues[channel]?.isEmpty == false ? .systemOrange : (channel == .them ? .systemTeal : .systemBlue)
                    colour.setFill()
                    let fill = NSRect(x: x, y: y, width: barWidth, height: max(1, barHeight * CGFloat(fraction)))
                    NSBezierPath(roundedRect: fill, xRadius: 1, yRadius: 1).fill()
                }
                x += barWidth + barGap
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// The recording icon says three things at once: whether anything has been heard yet (outlined
    /// until a side is heard, filled after), which sides (waveform, microphone or speaker), and
    /// whether one of them is in trouble (blue or orange).
    private func recordingImage() -> NSImage? {
        let symbol: String
        switch health?.presentation ?? .nothingHeard {
        case .nothingHeard: symbol = "waveform.circle"
        case .bothSides: symbol = "waveform.circle.fill"
        case .micOnly: symbol = "mic.circle.fill"
        case .systemAudioOnly: symbol = "speaker.wave.2.circle.fill"
        }
        let troubled = health?.isHealthy == false
        // Colour the symbol itself. Setting `contentTintColor` on a status bar button also
        // re-colours its title through a non-adaptive path, which drew the text black on a
        // dark menu bar; a palette-configured, non-template image leaves the title alone.
        // Two palette colours: the first paints the glyph, the second the circle behind it.
        // A single colour paints every layer, which renders as a solid disc with the glyph
        // invisible inside it. The outlined symbol has no filled disc, so there both layers take
        // the accent and the glyph stays visible.
        let accent: NSColor = troubled ? .systemOrange : .systemBlue
        let palette = NSImage.SymbolConfiguration(paletteColors: [symbol.hasSuffix(".fill") ? .white : accent, accent])
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: troubled ? "Recording, one side needs a look" : "Recording")?
            .withSymbolConfiguration(Self.symbolSize.applying(palette))
        image?.isTemplate = false
        return image
    }

    /// Shown the moment Stop is requested. Stopping can take several seconds (final transcription
    /// results, audio transcoding, bounded waits on a wedged engine); without this the icon keeps
    /// saying "recording" and the click looks lost.
    func setStopping() {
        guard recordingSince != nil, !stopping else { return }
        stopping = true
        let grey = NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor])
        let stoppingImage = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stopping")?
            .withSymbolConfiguration(Self.symbolSize.applying(grey))
        stoppingImage?.isTemplate = false
        item.button?.image = stoppingImage
        setTitle(" Stopping…")
    }

    func setIdle() {
        recordingSince = nil
        stopping = false
        health = nil
        levels = [:]
        headerTicker?.invalidate(); headerTicker = nil
        // `withSymbolConfiguration` returns an image with `isTemplate` cleared, which the menu bar
        // then does not tint: the idle icon drew in the symbol's own dark colour, at about a
        // quarter of its neighbours' brightness on a dark bar. Only the recording and stopping
        // images carry their own colours; this one follows the bar.
        let idle = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Feedback Recorder")?
            .withSymbolConfiguration(Self.symbolSize)
        idle?.isTemplate = true
        item.button?.image = idle
        item.button?.contentTintColor = nil
        setTitle("")
    }

    func setShotCount(_ n: Int) {
        guard n != shotCount else { return }
        shotCount = n
        updateTitle()
    }

    // MARK: click handling

    @objc private func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        let modifiers = event?.modifierFlags ?? []
        let wantsMenu = event?.type == .rightMouseUp
            || modifiers.contains(.command)
            || modifiers.contains(.control)
        // A plain click starts a session at once. While recording it opens the menu instead,
        // so stopping always takes a deliberate second click on "Stop".
        if wantsMenu || recordingSince != nil { showMenu() } else { onToggle?() }
    }

    /// Use the pointer's screen coordinates rather than synthesizing a status-button click.
    /// With a menu bar on each display, the button's backing window can still belong to another
    /// display. A programmatic click can consequently open the menu there. Passing no view makes
    /// AppKit interpret this location in screen coordinates, on the display actually clicked.
    private func showMenu() {
        let location = NSEvent.mouseLocation
        menu.popUp(positioning: nil, at: location, in: nil)
    }

    private func updateTitle() {
        guard recordingSince != nil, !stopping else { return }
        setTitle(" \(shotCount)")
    }

    /// Every assignment to the button's title relayouts the status item, so write it only when it
    /// changed: the tick timer and the shot-count poll otherwise rewrite the same string twice a
    /// second, redrawing the menu bar for nothing.
    private func setTitle(_ title: String) {
        guard title != lastTitle else { return }
        lastTitle = title
        item.button?.title = title
    }

    // MARK: menu

    /// Recomputed every second while the menu is open, so the clock and the shot count run live.
    private func headerTitle() -> String {
        if stopping { return "● Stopping…" }
        guard let since = recordingSince else { return "Feedback Recorder" }
        let elapsed = Timestamp.format(Date().timeIntervalSince(since))
        return "● Recording \(elapsed) · \(inputName) · \(shotCount) shots"
    }

    /// The header's second line: what is wrong with a side, else which sides are still unheard,
    /// else that every side has been heard. Nothing while idle.
    private func healthLine() -> String? {
        guard let health, recordingSince != nil, !stopping else { return nil }
        if !health.problems.isEmpty { return "⚠ " + health.problems.joined(separator: " · ") }
        if !health.unheard.isEmpty { return health.unheard.map { "\($0.label) not heard yet" }.joined(separator: " · ") }
        return health.channels.map(\.label).joined(separator: " and ") + " heard"
    }

    func menuWillOpen(_ menu: NSMenu) {
        headerTicker?.invalidate()
        guard recordingSince != nil else { return }
        let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.headerItem?.title = self.headerTitle()
                self.healthItem?.title = self.healthLine() ?? ""
            }
        }
        // Menu tracking runs in the event-tracking run loop mode. `.common` includes it; a
        // default-mode timer does not fire at all while a menu is open, which is why the header
        // used to freeze at the value it had when the menu was opened.
        RunLoop.main.add(ticker, forMode: .common)
        headerTicker = ticker
    }

    func menuDidClose(_ menu: NSMenu) {
        headerTicker?.invalidate(); headerTicker = nil
        headerItem = nil
        healthItem = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let recording = recordingSince != nil
        let header = NSMenuItem(title: headerTitle(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        headerItem = header
        if let line = healthLine() {
            let status = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
            healthItem = status
        }
        let toggleTitle = stopping ? "Stopping…" : (recording ? "Stop" : "Start")
        let toggle = NSMenuItem(title: toggleTitle, action: #selector(toggle(_:)), keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = !stopping
        toggle.toolTip = hotkeyLabel
        menu.addItem(toggle)
        menu.addItem(.separator())
        menu.addItem(action("Copy feedback command for \(Settings.feedbackAgent.displayName)", #selector(copyCommand(_:))))
        menu.addItem(action("Open current session", #selector(openSession(_:))))
        menu.addItem(action("Sessions folder…", #selector(openRoot(_:))))
        let agents = NSMenu()
        for agent in FeedbackAgent.allCases {
            let option = NSMenuItem(title: agent.displayName, action: #selector(chooseFeedbackAgent(_:)), keyEquivalent: "")
            option.target = self
            option.representedObject = agent.rawValue
            option.state = Settings.feedbackAgent == agent ? .on : .off
            agents.addItem(option)
        }
        let agentItem = NSMenuItem(title: "Feedback agent", action: nil, keyEquivalent: "")
        agentItem.submenu = agents
        menu.addItem(agentItem)
        menu.addItem(.separator())

        let inputMenu = NSMenu()
        let follow = NSMenuItem(title: "Follow system default", action: #selector(chooseInput(_:)), keyEquivalent: "")
        follow.target = self; follow.representedObject = nil
        follow.state = Settings.inputDeviceUID == nil ? .on : .off
        inputMenu.addItem(follow)
        inputMenu.addItem(.separator())
        for device in InputDevices.list() {
            let mi = NSMenuItem(title: device.name, action: #selector(chooseInput(_:)), keyEquivalent: "")
            mi.target = self; mi.representedObject = device.uid
            mi.state = Settings.inputDeviceUID == device.uid ? .on : .off
            inputMenu.addItem(mi)
        }
        let inputItem = NSMenuItem(title: "Input", action: nil, keyEquivalent: "")
        inputItem.submenu = inputMenu
        menu.addItem(inputItem)

        let sys = NSMenuItem(title: "Capture system audio", action: #selector(toggleSystemAudio(_:)), keyEquivalent: "")
        sys.target = self; sys.state = Settings.captureSystemAudio ? .on : .off
        sys.isEnabled = !recording
        menu.addItem(sys)
        let meters = NSMenuItem(title: "Level meters", action: #selector(toggleLevelMeters(_:)), keyEquivalent: "")
        meters.target = self; meters.state = Settings.showLevelMeters ? .on : .off
        meters.toolTip = "Two bars beside the icon while recording: Me (blue) and Them (teal), each read above that side's own noise floor."
        menu.addItem(meters)
        menu.addItem(.separator())

        let settings = NSMenu()
        let silence = NSMenu()
        for minutes in [5, 10, 20, 0] {
            let mi = NSMenuItem(title: minutes == 0 ? "Off" : "\(minutes) min", action: #selector(chooseSilence(_:)), keyEquivalent: "")
            mi.target = self; mi.representedObject = minutes
            mi.state = Settings.silenceMinutes == minutes ? .on : .off
            silence.addItem(mi)
        }
        let silenceItem = NSMenuItem(title: "Silence auto-stop", action: nil, keyEquivalent: ""); silenceItem.submenu = silence
        settings.addItem(silenceItem)
        let asymmetry = NSMenu()
        for minutes in [2, 3, 5, 0] {
            let mi = NSMenuItem(title: minutes == 0 ? "Off" : "\(minutes) min", action: #selector(chooseAsymmetry(_:)), keyEquivalent: "")
            mi.target = self; mi.representedObject = minutes
            mi.state = Settings.asymmetryMinutes == minutes ? .on : .off
            asymmetry.addItem(mi)
        }
        let asymmetryItem = NSMenuItem(title: "One-sided silence warning", action: nil, keyEquivalent: ""); asymmetryItem.submenu = asymmetry
        settings.addItem(asymmetryItem)
        settings.addItem(action("Edit vocabulary…", #selector(editVocabulary(_:))))
        settings.addItem(action("Session root…", #selector(chooseRoot(_:))))
        let hk = NSMenuItem(title: "Hotkey: \(hotkeyLabel)", action: nil, keyEquivalent: ""); hk.isEnabled = false
        settings.addItem(hk)
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: ""); settingsItem.submenu = settings
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: selector, keyEquivalent: ""); mi.target = self; return mi
    }

    @objc private func toggle(_ sender: Any?) { onToggle?() }
    @objc private func copyCommand(_ sender: Any?) { onCopyCommand?() }
    @objc private func chooseFeedbackAgent(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let agent = FeedbackAgent(rawValue: raw) else { return }
        Settings.feedbackAgent = agent
    }
    @objc private func openSession(_ sender: Any?) { onOpenSession?() }
    @objc private func openRoot(_ sender: Any?) { NSWorkspace.shared.open(Settings.sessionRoot) }
    @objc private func chooseInput(_ sender: NSMenuItem) { onChooseInput?(sender.representedObject as? String) }
    @objc private func toggleSystemAudio(_ sender: Any?) { onToggleSystemAudio?() }
    @objc private func toggleLevelMeters(_ sender: Any?) { onToggleLevelMeters?() }
    @objc private func chooseSilence(_ sender: NSMenuItem) { onSilenceMinutes?(sender.representedObject as? Int ?? 10) }
    @objc private func chooseAsymmetry(_ sender: NSMenuItem) { onAsymmetryMinutes?(sender.representedObject as? Int ?? 3) }
    @objc private func editVocabulary(_ sender: Any?) { NSWorkspace.shared.open(Settings.vocabularyURL) }
    @objc private func chooseRoot(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = Settings.sessionRoot
        if panel.runModal() == .OK, let url = panel.url { Settings.sessionRoot = url }
    }
}
