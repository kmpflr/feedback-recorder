import Foundation
import Carbon.HIToolbox
import FeedbackCore

enum Settings {
    static let defaults = UserDefaults.standard
    static let bundleID = "local.feedback-recorder"
    /// The marketing version from Info.plist, so the bundle stays the one place a release is numbered;
    /// a bare `swift run` has no bundle and reports 0.0.0.
    static let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

    private enum Key {
        static let sessionRoot = "sessionRoot"
        static let silenceMinutes = "silenceMinutes"
        static let asymmetryMinutes = "asymmetryMinutes"
        static let showLevelMeters = "showLevelMeters"
        static let inputDeviceUID = "inputDeviceUID"
        static let captureSystemAudio = "captureSystemAudio"
        static let locale = "locale"
        static let feedbackAgent = "feedbackAgent"
        static let whisperExecutable = "whisperExecutable"
        static let whisperModel = "whisperModel"
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let hotkeyModifiers = "hotkeyModifiers"
    }

    static func registerDefaults() {
        defaults.register(defaults: [
            Key.sessionRoot: NSHomeDirectory() + "/FeedbackSessions",
            Key.silenceMinutes: 10,
            Key.asymmetryMinutes: 3,
            Key.showLevelMeters: true,
            Key.captureSystemAudio: true,
            Key.locale: "en-US",
            Key.feedbackAgent: FeedbackAgent.claudeCode.rawValue,
            Key.hotkeyKeyCode: Int(kVK_ANSI_R),
            Key.hotkeyModifiers: Int(controlKey | optionKey | cmdKey),
        ])
    }

    static var sessionRoot: URL {
        get { URL(fileURLWithPath: defaults.string(forKey: Key.sessionRoot)!, isDirectory: true) }
        set { defaults.set(newValue.path, forKey: Key.sessionRoot) }
    }
    static var feedbackAgent: FeedbackAgent {
        get { FeedbackAgent(rawValue: defaults.string(forKey: Key.feedbackAgent) ?? "") ?? .claudeCode }
        set { defaults.set(newValue.rawValue, forKey: Key.feedbackAgent) }
    }
    static var silenceMinutes: Int {
        get { defaults.integer(forKey: Key.silenceMinutes) }
        set { defaults.set(newValue, forKey: Key.silenceMinutes) }
    }
    static var silencePeriod: TimeInterval? { silenceMinutes > 0 ? TimeInterval(silenceMinutes * 60) : nil }
    static var asymmetryMinutes: Int {
        get { defaults.integer(forKey: Key.asymmetryMinutes) }
        set { defaults.set(newValue, forKey: Key.asymmetryMinutes) }
    }
    static var asymmetryPeriod: TimeInterval? { asymmetryMinutes > 0 ? TimeInterval(asymmetryMinutes * 60) : nil }
    static var showLevelMeters: Bool {
        get { defaults.bool(forKey: Key.showLevelMeters) }
        set { defaults.set(newValue, forKey: Key.showLevelMeters) }
    }
    static var inputDeviceUID: String? {
        get { defaults.string(forKey: Key.inputDeviceUID) }
        set { defaults.set(newValue, forKey: Key.inputDeviceUID) }
    }
    static var captureSystemAudio: Bool {
        get { defaults.bool(forKey: Key.captureSystemAudio) }
        set { defaults.set(newValue, forKey: Key.captureSystemAudio) }
    }
    static var localeIdentifier: String { defaults.string(forKey: Key.locale) ?? "en-US" }
    /// Where whisper.cpp lives, when it is not in one of the usual Homebrew locations. Defaults
    /// only; there is no UI for them.
    static var whisperExecutable: String? { defaults.string(forKey: Key.whisperExecutable) }
    static var whisperModel: String? { defaults.string(forKey: Key.whisperModel) }
    static var hotkeyKeyCode: UInt32 { UInt32(defaults.integer(forKey: Key.hotkeyKeyCode)) }
    static var hotkeyModifiers: UInt32 { UInt32(defaults.integer(forKey: Key.hotkeyModifiers)) }

    static var appSupportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FeedbackRecorder", isDirectory: true)
    }
    static var vocabularyURL: URL { appSupportURL.appendingPathComponent("vocab.txt") }

    /// Creates vocab.txt from the bundled example on first launch.
    static func ensureVocabularyFile() {
        let fm = FileManager.default
        try? fm.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
        guard !fm.fileExists(atPath: vocabularyURL.path) else { return }
        if let example = Bundle.main.url(forResource: "vocab.example", withExtension: "txt"),
           let data = try? Data(contentsOf: example) {
            try? data.write(to: vocabularyURL)
        } else {
            try? Data("# One phrase per line, at most 100.\nAcme\nWorkbench\ncatalogue\n".utf8).write(to: vocabularyURL)
        }
    }
}
