import AppKit
import AVFoundation
import SwiftUI
import UserNotifications
import FeedbackCore

@MainActor
final class SettingsPanelModel: ObservableObject {
    @Published var hotkeyLabel: String
    @Published var shortcutError: String?
    @Published var accessReport: Preflight.Report?
    @Published var recordingActive: Bool
    @Published var checkingAccess = false
    @Published var accessError: String?
    @Published var microphoneStatus = "Not checked"
    @Published var notificationStatus = "Not checked"
    let onMetersChanged: () -> Void
    let onCaptureShortcut: (Bool) -> Void
    private let changeShortcut: (RecordingShortcut, String?) throws -> String
    private let checkAccess: () async throws -> Preflight.Report

    init(hotkeyLabel: String, accessReport: Preflight.Report?, recordingActive: Bool,
         onMetersChanged: @escaping () -> Void,
         onCaptureShortcut: @escaping (Bool) -> Void,
         onShortcutChange: @escaping (RecordingShortcut, String?) throws -> String,
         onCheckAccess: @escaping () async throws -> Preflight.Report) {
        self.hotkeyLabel = hotkeyLabel; self.accessReport = accessReport; self.recordingActive = recordingActive
        self.onMetersChanged = onMetersChanged; self.onCaptureShortcut = onCaptureShortcut
        self.changeShortcut = onShortcutChange; self.checkAccess = onCheckAccess
    }

    func updateShortcut(_ shortcut: RecordingShortcut, displayKey: String?) throws {
        hotkeyLabel = try changeShortcut(shortcut, displayKey)
        shortcutError = nil
    }

    func restoreShortcut() {
        do { try updateShortcut(RecordingShortcut(keyCode: 15, modifiers: (1 << 8) | (1 << 11) | (1 << 12)), displayKey: "R") }
        catch { shortcutError = error.localizedDescription }
    }

    func refreshPassiveStatus() async {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphoneStatus = "Allowed"
        case .denied: microphoneStatus = "Denied"
        case .restricted: microphoneStatus = "Restricted"
        case .notDetermined: microphoneStatus = "Not requested"
        @unknown default: microphoneStatus = "Unknown"
        }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: notificationStatus = "Allowed"
        case .denied: notificationStatus = "Off (optional)"
        case .notDetermined: notificationStatus = "Not requested (optional)"
        @unknown default: notificationStatus = "Unknown"
        }
    }

    func recheckAccess() async {
        guard !checkingAccess, !recordingActive else { return }
        checkingAccess = true; accessError = nil
        defer { checkingAccess = false }
        do { accessReport = try await checkAccess() }
        catch { accessError = error.localizedDescription }
        await refreshPassiveStatus()
    }
}
