import AppKit
import SwiftUI
import FeedbackCore

@MainActor
final class RecordingsWindowController: NSWindowController {
    let model = RecordingsModel()
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Recordings"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 420)
        super.init(window: window)
        window.contentView = NSHostingView(rootView: RecordingsView(model: model))
        window.center()
    }
    required init?(coder: NSCoder) { nil }
    func present() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        refreshIfVisible()
    }
    func refreshIfVisible() {
        guard window?.isVisible == true else { return }
        Task { await model.reload() }
    }
}

@MainActor
final class RecordingsModel: ObservableObject {
    @Published var sessions: [SavedSession] = []
    @Published var query = ""
    @Published var selectedID: URL?
    @Published var loading = false
    @Published var warnings: [String] = []
    @Published var error: String?
    @Published var renaming = false
    @Published var renameText = ""
    @Published var renameError: String?
    private var generation = UUID()
    var filtered: [SavedSession] { sessions.filter { $0.matches(query) } }
    var selected: SavedSession? { filtered.first { $0.id == selectedID } }

    func reload() async {
        let request = UUID(); generation = request; loading = true
        let roots = Settings.recordingRoots
        let snapshot = await Task.detached(priority: .userInitiated) { SessionLibrary.load(roots: roots) }.value
        guard request == generation else { return }
        sessions = snapshot.sessions; warnings = snapshot.warnings; loading = false
    }
    func beginRename() {
        guard let selected else { return }
        renameText = selected.name; renameError = nil; renaming = true
    }
    func saveName() {
        guard let selected else { return }
        do {
            try SessionLibrary.rename(selected.folder, to: renameText)
            renaming = false
            Task { await reload() }
        } catch { renameError = error.localizedDescription }
    }
    func openSelected() {
        guard let selected else { return }
        if !NSWorkspace.shared.open(selected.folder.url) { error = "This session folder couldn’t be opened. Refresh the list and check that its disk is connected." }
    }
    func copySelectedCommand() {
        guard let selected else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selected.folder.feedbackCommand(for: Settings.feedbackAgent), forType: .string)
        Notifier.post(title: "Copied feedback command", body: selected.name)
    }
}

struct RecordingsView: View {
    @ObservedObject var model: RecordingsModel
    @AppStorage(Settings.Key.sessionRoot, store: Settings.defaults) private var sessionPath = Settings.defaultSessionRoot.path

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your recordings").font(.title2.weight(.semibold))
                    Text("Sessions from your saved recording locations.").foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await model.reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh recordings").accessibilityLabel("Refresh recordings")
                    .disabled(model.loading)
            }.padding(20)
            TextField("Search names, dates, modes or microphones", text: $model.query)
                .textFieldStyle(.roundedBorder).padding(.horizontal, 20).padding(.bottom, 12)
            if model.loading && model.sessions.isEmpty {
                Spacer(); ProgressView("Loading recordings…"); Spacer()
            } else if model.filtered.isEmpty {
                Spacer()
                Image(systemName: "waveform").font(.largeTitle).foregroundStyle(.secondary)
                Text(model.query.isEmpty ? "No recordings yet" : "No matching recordings").font(.headline).padding(.top, 8)
                Text(model.query.isEmpty ? "Start a session from the menu bar to see it here." : "Try a different name, date or microphone.")
                    .foregroundStyle(.secondary).padding(.top, 2)
                Spacer()
            } else {
                List(selection: $model.selectedID) {
                    ForEach(model.filtered) { session in
                        HStack(spacing: 12) {
                            Image(systemName: session.state.mode == .call ? "person.2.wave.2" : "mic")
                                .foregroundStyle(.blue).frame(width: 24)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.name).fontWeight(.medium).lineLimit(1)
                                Text(session.state.startedAt.formatted(date: .abbreviated, time: .shortened)
                                     + " · " + Timestamp.format(Double(session.state.durationSeconds))
                                     + " · \(session.state.counts.shots) images")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if session.state.state == .recording {
                                Text("In progress").font(.caption).foregroundStyle(.secondary)
                            } else if session.state.stopReason == .error || session.state.stopReason == .crash {
                                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                                    .help("This session ended with an error or interruption; its output may be incomplete.")
                            }
                        }
                        .padding(.vertical, 5).tag(session.id)
                        .help((session.folder.url.path as NSString).abbreviatingWithTildeInPath)
                    }
                }.listStyle(.inset)
            }
            if !model.warnings.isEmpty {
                Text(model.warnings.joined(separator: "\n"))
                    .font(.caption).foregroundStyle(.orange).lineLimit(3)
                    .textSelection(.enabled).padding(.horizontal, 20).padding(.vertical, 8)
            }
            Divider()
            HStack {
                Button("Open Folder", action: model.openSelected)
                Button("Copy feedback command", action: model.copySelectedCommand)
                Spacer()
                Button("Rename…", action: model.beginRename)
            }.disabled(model.selected == nil).padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: sessionPath) { await model.reload() }
        .sheet(isPresented: $model.renaming) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Name this recording").font(.headline)
                TextField("Session name", text: $model.renameText).textFieldStyle(.roundedBorder).onSubmit(model.saveName)
                Text("Only the display name changes. The session’s files and feedback command keep the same path.")
                    .font(.callout).foregroundStyle(.secondary)
                if let message = model.renameError { Text(message).foregroundStyle(.red).font(.callout) }
                HStack {
                    Spacer()
                    Button("Cancel") { model.renaming = false }.keyboardShortcut(.cancelAction)
                    Button("Save", action: model.saveName).keyboardShortcut(.defaultAction)
                        .disabled(model.renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 400)
        }
        .alert("Couldn’t open recording", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}
