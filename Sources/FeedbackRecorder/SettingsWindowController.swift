import AppKit
import SwiftUI
import FeedbackCore

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let model: SettingsPanelModel
    init(model: SettingsPanelModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Feedback Recorder Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: RecorderSettingsView(model: model))
        installWindowMenus()
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        Task { await model.refreshPassiveStatus() }
    }

    @objc private func openSettings(_ sender: Any?) { present() }

    private func installWindowMenus() {
        // Accessory apps have no default main menu. Supply standard keyboard actions while the
        // settings window or its folder sheet is active, including copy/paste and Cmd-W.
        let main = NSMenu()
        let application = NSMenu(title: "Feedback Recorder")
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settings.target = self
        application.addItem(settings)
        application.addItem(.separator())
        application.addItem(NSMenuItem(title: "Quit Feedback Recorder", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        for submenu in [application, edit, windowMenu] {
            let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            main.addItem(item)
        }
        NSApp.mainMenu = main
    }
}

private final class SettingsPresentation: ObservableObject {
    @Published var folderError: String?
    @Published var choosingFolder = false
    @Published var section = "General"
}

struct RecorderSettingsView: View {
    @ObservedObject var model: SettingsPanelModel
    @AppStorage(Settings.Key.sessionRoot, store: Settings.defaults) private var sessionPath = Settings.defaultSessionRoot.path
    @AppStorage(Settings.Key.captureSystemAudio, store: Settings.defaults) private var systemAudio = true
    @AppStorage(Settings.Key.silenceMinutes, store: Settings.defaults) private var silence = 10
    @AppStorage(Settings.Key.asymmetryMinutes, store: Settings.defaults) private var asymmetry = 3
    @AppStorage(Settings.Key.showLevelMeters, store: Settings.defaults) private var meters = true
    @AppStorage(Settings.Key.feedbackAgent, store: Settings.defaults) private var agent = FeedbackAgent.claudeCode.rawValue
    @AppStorage(Settings.Key.copyCommandOnStop, store: Settings.defaults) private var autoCopy = true
    @StateObject private var presentation = SettingsPresentation()

    private var folderURL: URL { URL(fileURLWithPath: sessionPath, isDirectory: true) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 42)).foregroundStyle(.white, .blue)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Feedback Recorder").font(.title2.weight(.semibold))
                    Text("Set up your next recording.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 12)

            Picker("Settings section", selection: $presentation.section) {
                Text("General").tag("General")
                Text("Recording").tag("Recording")
                Text("Access").tag("Access")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)
            .padding(.bottom, 8)

            Form {
                if presentation.section == "General" {
                    storageSection
                    handoffSection
                    menuBarSection
                } else if presentation.section == "Recording" {
                    recordingSection
                } else {
                    accessSection
                }
            }
            .formStyle(.grouped)
            .onChange(of: meters) { _, _ in model.onMetersChanged() }
            .task { await model.refreshPassiveStatus() }
        }
        .frame(minWidth: 560, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Couldn’t use that folder", isPresented: Binding(
            get: { presentation.folderError != nil }, set: { if !$0 { presentation.folderError = nil } })) {
                Button("OK", role: .cancel) { presentation.folderError = nil }
            } message: { Text(presentation.folderError ?? "") }
    }

    private var storageSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "folder.fill").foregroundStyle(.blue).font(.title2)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(folderURL.lastPathComponent).fontWeight(.medium)
                        Text((sessionPath as NSString).abbreviatingWithTildeInPath)
                            .font(.callout).foregroundStyle(.secondary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                HStack {
                    Button("Choose Folder…", action: chooseFolder).disabled(presentation.choosingFolder)
                    Button("Open Folder", action: openFolder)
                    Spacer()
                    if folderURL.standardizedFileURL != Settings.defaultSessionRoot.standardizedFileURL {
                        Button("Use Default") { saveFolder(Settings.defaultSessionRoot) }
                    }
                }
            }.padding(.vertical, 4)
        } header: {
            Text("Save recordings")
        } footer: {
            Text("Applies to new recordings. Existing sessions stay in their original folder. Cloud folders may sync your recordings.")
        }
    }

    private var recordingSection: some View {
        Section {
            Toggle("Include system audio", isOn: $systemAudio)
                .help("Record the other side of a call. Turn off for microphone-only room recordings.")
            Picker("Stop after silence", selection: $silence) {
                ForEach(Array(Set([0, 5, 10, 20, silence])).sorted(), id: \.self) { value in
                    Text(value == 0 ? "Never" : "\(value) minutes").tag(value)
                }
            }
            Picker("Warn when one side is quiet", selection: $asymmetry) {
                ForEach(Array(Set([0, 2, 3, 5, asymmetry])).sorted(), id: \.self) { value in
                    Text(value == 0 ? "Never" : "After \(value) minutes").tag(value)
                }
            }.disabled(!systemAudio)
            HStack {
                Text("Recognition vocabulary")
                Spacer()
                Button("Edit…") {
                    Settings.ensureVocabularyFile()
                    NSWorkspace.shared.open(Settings.vocabularyURL)
                }
            }
        } header: {
            Text("Recording defaults")
        } footer: {
            Text("These changes apply to the next recording. Choose or switch your microphone from the menu bar’s Input menu.")
        }
    }

    private var handoffSection: some View {
        Section {
            Picker("Feedback agent", selection: $agent) {
                ForEach(FeedbackAgent.allCases, id: \.rawValue) { agent in
                    Text(agent.displayName).tag(agent.rawValue)
                }
            }
            Toggle("Copy feedback command when recording stops", isOn: $autoCopy)
        } header: {
            Text("After recording")
        } footer: {
            Text(autoCopy
                 ? "Replaces your clipboard with a command for the selected agent. Nothing is sent automatically."
                 : "Your clipboard stays as it is. Use Copy feedback command in the menu when you’re ready.")
        }
    }

    private var menuBarSection: some View {
        Section {
            Toggle("Show audio level meters", isOn: $meters)
            HStack {
                Text("Start / stop shortcut")
                Spacer()
                ShortcutRecorder(label: model.hotkeyLabel, onChange: model.updateShortcut,
                                 onCapture: model.onCaptureShortcut, onError: { model.shortcutError = $0 })
                    .frame(width: 160, height: 26)
                Button("Reset") {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    model.restoreShortcut()
                }
            }
            if let message = model.shortcutError {
                Text(message).font(.callout).foregroundStyle(.red)
            }
        } header: {
            Text("Menu bar")
        } footer: {
            Text("Click the shortcut to change it. Use Command or Control with another modifier and a key. Escape cancels.")
        }
    }

    private var accessSection: some View {
        Section {
            LabeledContent("Microphone", value: model.microphoneStatus)
            LabeledContent("System audio", value: model.accessReport.map { $0.systemAudio ? "Available at last check" : "Needs access" } ?? "Not checked")
            LabeledContent("On-device speech", value: model.accessReport.map { $0.assets ? "Ready" : "Needs setup" } ?? "Not checked")
            LabeledContent("Notifications", value: model.notificationStatus)
            HStack {
                Button(model.checkingAccess ? "Checking…" : "Check Again") { Task { await model.recheckAccess() } }
                    .disabled(model.checkingAccess || model.recordingActive)
                Spacer()
                Button("Open Privacy Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") { NSWorkspace.shared.open(url) }
                }
            }
            if let message = model.accessError { Text(message).font(.callout).foregroundStyle(.red) }
            if let report = model.accessReport, !report.problems.isEmpty {
                Text(report.problems.joined(separator: "\n\n")).font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text("Recording access")
        } footer: {
            Text(model.recordingActive
                 ? "Stop the current recording before checking access again."
                 : "Checking may show macOS permission prompts or download speech assets. System audio reflects the last capture check. No session files are changed.")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a recordings folder"
        panel.prompt = "Use Folder"
        panel.message = "New recordings will be saved here. Existing sessions won’t be moved."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folderURL
        presentation.choosingFolder = true
        // A sheet keeps the menu-bar app responsive while the user chooses a folder.
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                presentation.choosingFolder = false
                if response == .OK, let url = panel.url { saveFolder(url) }
            }
        } else {
            panel.begin { response in
                presentation.choosingFolder = false
                if response == .OK, let url = panel.url { saveFolder(url) }
            }
        }
    }

    private func saveFolder(_ url: URL) {
        do {
            try SessionStorage.prepare(url)
            Settings.sessionRoot = url.standardizedFileURL
            sessionPath = url.standardizedFileURL.path
        } catch { presentation.folderError = error.localizedDescription }
    }

    private func openFolder() {
        do {
            try SessionStorage.prepare(folderURL)
            if !NSWorkspace.shared.open(folderURL) {
                presentation.folderError = "Finder couldn’t open this folder. Check that the disk is connected and try again."
            }
        } catch { presentation.folderError = error.localizedDescription }
    }
}
