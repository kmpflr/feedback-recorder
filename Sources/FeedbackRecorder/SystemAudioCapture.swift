import Foundation
import CoreAudio
import AVFAudio
import FeedbackCore

enum SystemAudioError: LocalizedError {
    case coreAudio(String, OSStatus)
    var errorDescription: String? {
        if case .coreAudio(let what, let status) = self { return "\(what) failed (\(status))" }
        return nil
    }
}

/// Global Core Audio process tap (all processes except this one), mono mixdown, via a private aggregate device.
final class SystemAudioCapture: AudioSource, @unchecked Sendable {
    private let channel: Channel
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private let queue = DispatchQueue(label: "feedback-recorder.system-audio")

    init(channel: Channel = .them) { self.channel = channel }

    /// Creates and destroys a tap so the system-audio permission prompt appears at launch, not mid-call.
    static func probePermission() throws {
        let description = try makeDescription()
        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "create tap")
        AudioHardwareDestroyProcessTap(tap)
    }

    func start() async throws -> AsyncStream<AudioChunk> {
        let description = try Self.makeDescription()
        try Self.check(AudioHardwareCreateProcessTap(description, &tapID), "create tap")
        do {
            let outputUID = try Self.defaultOutputUID()
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "FeedbackRecorder System Audio",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
            ]
            try Self.check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create aggregate device")

            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var asbd = AudioStreamBasicDescription(); var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try Self.check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd), "read tap format")
            guard let format = AVAudioFormat(streamDescription: &asbd) else { throw SystemAudioError.coreAudio("tap format", -1) }

            let (stream, cont) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(256))
            continuation = cont
            let channel = self.channel
            try Self.check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, inInputData, inInputTime, _, _ in
                guard let self,
                      let raw = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil),
                      let copy = raw.deepCopy() else { return }
                // The tap does not promise a host time on every callback. An unset one reads as 0,
                // which `ChannelClock` would take for "this channel started before the session" and
                // then place every Them line at [00:00]. Fall back to the current host time, which
                // is within one buffer of the truth.
                let ts = inInputTime.pointee
                let host = (ts.mFlags.contains(.hostTimeValid) && ts.mHostTime != 0) ? ts.mHostTime : mach_absolute_time()
                self.continuation?.yield(AudioChunk(channel: channel, buffer: copy, hostTime: host))
            }, "create io proc")
            try Self.check(AudioDeviceStart(aggregateID, procID), "start aggregate device")
            return stream
        } catch {
            teardown()
            throw error
        }
    }

    func stop() async {
        teardown()
        continuation?.finish(); continuation = nil
    }

    /// Stops and destroys whatever Core Audio objects currently exist, in reverse creation order.
    /// Safe to call regardless of how far `start()` got — each step is independently guarded.
    private func teardown() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = AudioObjectID(kAudioObjectUnknown) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = AudioObjectID(kAudioObjectUnknown) }
    }

    // MARK: helpers

    private static func makeDescription() throws -> CATapDescription {
        let own = try processObjectID(pid: getpid())
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [own])
        description.isMono = true
        description.isPrivate = true
        description.muteBehavior = .unmuted
        return description
    }

    private static func processObjectID(pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pidValue = pid; var object = AudioObjectID(kAudioObjectUnknown); var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pidValue, &size, &object), "translate pid")
        return object
    }

    private static func defaultOutputUID() throws -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device), "default output device")
        var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>? = nil; var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, &uid), "output device uid")
        return uid!.takeRetainedValue() as String
    }

    private static func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw SystemAudioError.coreAudio(what, status) }
    }
}
