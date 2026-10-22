import Foundation
import AVFAudio

/// The input device a capture is actually running against, and the rate it actually delivers.
///
/// This is deliberately not `AVAudioEngine`'s view of the world. `AVAudioInputNode` reports the
/// format of whatever device it was created against and keeps reporting it after the current
/// device is switched out underneath — verified on macOS 26 for a 16 kHz headset selected on an
/// engine created while a 48 kHz built-in microphone was the default: `outputFormat(forBus:)`
/// answers 48 kHz before the switch, after the switch, after `prepare()` and after `start()`.
/// The truth lives in CoreAudio, on the device itself, so the caller reads it there and hands it
/// in here.
public struct InputConfiguration: Sendable, Equatable {
    public let deviceUID: String?
    public let deviceName: String
    public let sampleRate: Double
    public let channelCount: UInt32

    public init(deviceUID: String?, deviceName: String, sampleRate: Double, channelCount: UInt32) {
        self.deviceUID = deviceUID; self.deviceName = deviceName
        self.sampleRate = sampleRate; self.channelCount = channelCount
    }

    /// What a configuration change should make the capture do.
    public enum Decision: Sendable, Equatable {
        case ignore
        /// Rebuild the engine, and write `note` to the transcript when there is one.
        case restart(note: String?)
    }

    /// The format to install the tap with, or `nil` to let `AVAudioEngine` choose.
    ///
    /// A tap carries its format to every buffer it delivers, so a tap installed with the node's
    /// stale format labels 16 kHz audio as 48 kHz. Nothing downstream can tell: the converter
    /// dutifully "resamples" 48 kHz to 16 kHz and drops two of every three frames, and the
    /// recording ends up a third of its true length and three times too fast — speech that no
    /// transcriber can read. Whenever the hardware rate is known, that rate wins.
    ///
    /// When it is not known, the answer is `nil` rather than a guess: `installTap` raises an
    /// Objective-C exception on a rate that disagrees with the hardware, which no Swift `catch`
    /// can reach and which takes the whole app — and the recording in progress — down with it.
    public static func tapFormat(nodeFormat: AVAudioFormat, hardwareSampleRate: Double?) -> AVAudioFormat? {
        guard let rate = hardwareSampleRate, rate > 0 else { return nil }
        guard rate != nodeFormat.sampleRate else { return nodeFormat }
        return AVAudioFormat(commonFormat: nodeFormat.commonFormat, sampleRate: rate,
                             channels: nodeFormat.channelCount, interleaved: nodeFormat.isInterleaved)
    }

    /// Selecting an input device makes CoreAudio raise a configuration change of its own, so a
    /// handler that restarts unconditionally selects the device again and raises another — the
    /// loop that wrote 969 "input changed" lines into a 24-minute transcript. Comparing the
    /// configuration the restart produced against the one already running breaks it: our own
    /// change is a no-op, and only something that actually moved gets a restart.
    public static func decide(previous: InputConfiguration, current: InputConfiguration) -> Decision {
        guard previous != current else { return .ignore }
        // Same device at a new rate — a headset dropping to 16 kHz as its microphone opens.
        // The capture has to follow it; the person reading the transcript does not care.
        guard previous.isSameDevice(as: current) else { return .restart(note: "input changed to \(current.deviceName)") }
        return .restart(note: nil)
    }

    private func isSameDevice(as other: InputConfiguration) -> Bool {
        if let uid = deviceUID, let otherUID = other.deviceUID { return uid == otherUID }
        return deviceUID == other.deviceUID && deviceName == other.deviceName
    }
}

/// Tells a real input change apart from the echo of our own device selection.
///
/// Both loops this guards against are silent and expensive. Selecting the device raises a
/// configuration change, so restarting for every notification selects it again and raises
/// another. And when selection *fails*, the device the engine ends up on never becomes the one
/// that was asked for, so "restart until they match" never stops either. Neither shows up as an
/// error; the first one wrote 969 identical lines into a 24-minute transcript.
///
/// The question that ends both: has anything moved since the last time the engine was built —
/// either the device the capture is meant to use, or the one it actually ended up on?
public struct InputConfigurationTracker: Sendable {
    private var running: InputConfiguration?
    private var desired: InputConfiguration?
    private var recorded = false

    public init() {}

    /// Records what a restart produced: the device the engine ended up on, and the one it was
    /// aiming for. They differ when selecting the device failed.
    public mutating func started(running: InputConfiguration?, desired: InputConfiguration?) {
        self.running = running; self.desired = desired; self.recorded = true
    }

    /// What to do about a configuration change, given how the two devices read right now.
    public func decide(running runningNow: InputConfiguration?, desired desiredNow: InputConfiguration?) -> InputConfiguration.Decision {
        guard recorded else {
            // Nothing to compare against, so take the notification at its word.
            return .restart(note: desiredNow.map { "input changed to \($0.deviceName)" })
        }
        if desiredNow != desired { return change(from: desired, to: desiredNow) }
        if runningNow != running { return change(from: running, to: runningNow) }
        return .ignore
    }

    private func change(from: InputConfiguration?, to: InputConfiguration?) -> InputConfiguration.Decision {
        guard let from, let to else { return .restart(note: to.map { "input changed to \($0.deviceName)" }) }
        return InputConfiguration.decide(previous: from, current: to)
    }
}
