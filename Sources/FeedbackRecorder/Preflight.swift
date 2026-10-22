import AVFoundation
import Foundation
import FeedbackCore

enum Preflight {
    struct Report { var microphone: Bool; var systemAudio: Bool; var assets: Bool; var recovered: [URL]; var problems: [String] }

    static func run() async -> Report {
        var report = Report(microphone: false, systemAudio: false, assets: false, recovered: [], problems: [])
        try? FileManager.default.createDirectory(at: Settings.sessionRoot, withIntermediateDirectories: true)
        Settings.ensureVocabularyFile()

        report.microphone = await AVCaptureDevice.requestAccess(for: .audio)
        if !report.microphone { report.problems.append("Microphone access denied. Enable it in System Settings › Privacy & Security › Microphone.") }

        do { try SystemAudioCapture.probePermission(); report.systemAudio = true }
        catch { report.problems.append("System audio recording unavailable (\(error.localizedDescription)). Enable it in System Settings › Privacy & Security › System Audio Recording, or use room mode.") }

        do { try await AppleSpeechEngine.ensureAssets(localeIdentifier: Settings.localeIdentifier); report.assets = true }
        catch { report.problems.append("Speech model assets for \(Settings.localeIdentifier) could not be installed (\(error.localizedDescription)). Connect to the network and relaunch.") }

        report.recovered = (try? SessionRecovery.recoverOrphans(root: Settings.sessionRoot)) ?? []
        return report
    }
}
