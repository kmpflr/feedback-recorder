import Foundation
import AVFAudio
import CoreAudio
import FeedbackCore

/// Captures the selected input device through AVAudioEngine and emits buffers tagged with `channel`.
final class MicCapture: AudioSource, @unchecked Sendable {
    private let channel: Channel
    /// The device this capture is pinned to, or nil to follow the system default. Settable while
    /// running, from `switchDevice`, so a session can change input without being restarted.
    private var deviceUID: String?
    private let onDeviceChange: @Sendable (String) -> Void
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var observer: NSObjectProtocol?
    private var stopped = false
    /// What the last restart was aiming for and what it actually got, so a configuration
    /// change can be told apart from the echo of our own device selection.
    private var tracker = InputConfigurationTracker()
    /// The last note handed to `onDeviceChange`, so an identical one is not written twice.
    private var lastNote: String?

    /// The engine is rebuilt for a device switch, which raises a configuration change of its own;
    /// `emit` drops a note identical to the last one, and the tracker ignores an echo, so the
    /// switch writes exactly the one note `SessionController.switchInput` adds itself.
    init(channel: Channel, deviceUID: String?, onDeviceChange: @escaping @Sendable (String) -> Void) {
        self.channel = channel; self.deviceUID = deviceUID; self.onDeviceChange = onDeviceChange
    }

    func start() async throws -> AsyncStream<AudioChunk> {
        let (stream, cont) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(256))
        continuation = cont
        try beginLocked()
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] _ in
            self?.handleConfigurationChangeLocked()
        }
        return stream
    }

    func stop() async {
        stopLocked()
    }

    /// Rebuilds the engine against another device, keeping the buffer stream the session is
    /// already consuming. The tap's format follows the new hardware's rate, which is the whole
    /// reason this cannot be a bare `AudioUnitSetProperty` on the running unit.
    func switchDevice(uid: String?) async throws {
        try switchDeviceLocked(uid: uid)
    }

    private func switchDeviceLocked(uid: String?) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        let previous = deviceUID
        deviceUID = uid
        stopEngine()
        do {
            try startEngine()
        } catch {
            // Put the capture back on the device that was working rather than leaving the session
            // with no microphone at all. If even that fails, the throw reaches the caller.
            deviceUID = previous
            try startEngine()
            throw error
        }
    }

    deinit {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        if let observer { NotificationCenter.default.removeObserver(observer) }
        stopEngine()
        continuation?.finish()
    }

    /// Synchronous (non-async) so NSLock's lock/unlock, which are unavailable in async contexts, stay confined here.
    private func beginLocked() throws {
        lock.lock()
        defer { lock.unlock() }
        stopped = false
        try startEngine()
    }

    private func handleConfigurationChangeLocked() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        // Selecting the input device raises a configuration change of its own, so restarting for
        // every notification selects the device again and raises another. Read both devices back
        // and let the tracker say whether either has moved since the engine was built; when
        // neither has, this notification is the echo of our own selection.
        guard case .restart(let note) = tracker.decide(running: runningConfiguration(),
                                                      desired: targetConfiguration()) else { return }
        stopEngine()
        do {
            try startEngine()
            if let note { emit(note) }
        } catch {
            emit("microphone capture failed: \(error.localizedDescription)")
        }
    }

    /// Drops a note identical to the one before it. `decide` already keeps the engine from
    /// churning; this is what keeps a transcript readable if it ever churns anyway, since a
    /// second "input changed to Jabra Link 380" tells the reader nothing the first did not.
    private func emit(_ note: String) {
        guard note != lastNote else { return }
        lastNote = note
        onDeviceChange(note)
    }

    private func stopLocked() {
        lock.lock()
        defer { lock.unlock() }
        stopped = true
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        stopEngine()
        continuation?.finish(); continuation = nil
    }

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let unit = input.audioUnit
        if let uid = deviceUID, let id = InputDevices.deviceID(forUID: uid), let unit {
            var deviceID = id
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr {
                let name = InputDevices.list().first { $0.uid == uid }?.name ?? uid
                emit("could not select input \(name): \(status); using \(actualDevice(of: unit)?.name ?? "default input")")
            }
        }
        // The device the unit ended up on, read back rather than assumed, and its rate read from
        // CoreAudio rather than from the input node — the node keeps answering with the format of
        // the device it was created against, so a tap built from it labels a 16 kHz headset's
        // audio as 48 kHz and the recording comes out a third of its length and three times too
        // fast. See `InputConfiguration`.
        let deviceID = unit.flatMap { InputDevices.currentDevice(of: $0) }
        let hardware = deviceID.flatMap { InputDevices.hardwareFormat(id: $0) }
        let nodeFormat = input.outputFormat(forBus: 0)
        let tapFormat = InputConfiguration.tapFormat(nodeFormat: nodeFormat, hardwareSampleRate: hardware?.sampleRate)
        input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, time in
            guard let self, let copy = buffer.deepCopy() else { return }
            self.continuation?.yield(AudioChunk(channel: self.channel, buffer: copy, hostTime: time.hostTime))
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        tracker.started(running: deviceID.flatMap(configuration(of:)), desired: targetConfiguration())
    }

    private func stopEngine() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    /// The device this capture is meant to use — the pinned one, or the system default when
    /// it follows along — as it reads right now.
    private func targetConfiguration() -> InputConfiguration? {
        let uid = deviceUID ?? InputDevices.defaultInput()?.uid
        return uid.flatMap(InputDevices.deviceID(forUID:)).flatMap(configuration(of:))
    }

    /// The device the running engine actually ended up on, as it reads right now. Not the same
    /// question as `targetConfiguration()`: selecting a device can fail, and then it never will be.
    private func runningConfiguration() -> InputConfiguration? {
        engine?.inputNode.audioUnit.flatMap(InputDevices.currentDevice(of:)).flatMap(configuration(of:))
    }

    private func configuration(of id: AudioDeviceID) -> InputConfiguration? {
        guard let device = InputDevices.device(id: id), let hardware = InputDevices.hardwareFormat(id: id) else { return nil }
        return InputConfiguration(deviceUID: device.uid, deviceName: device.name,
                                  sampleRate: hardware.sampleRate, channelCount: hardware.channelCount)
    }

    private func actualDevice(of unit: AudioUnit) -> InputDevice? {
        InputDevices.currentDevice(of: unit).flatMap(InputDevices.device(id:))
    }
}
