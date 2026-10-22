import Foundation
import AVFAudio

public struct AudioChunk: @unchecked Sendable {
    public let channel: Channel
    public let buffer: AVAudioPCMBuffer
    public let hostTime: UInt64
    public init(channel: Channel, buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        self.channel = channel; self.buffer = buffer; self.hostTime = hostTime
    }
}

public protocol AudioSource: Sendable {
    func start() async throws -> AsyncStream<AudioChunk>
    func stop() async
    /// Moves a running capture to another input device, keeping the same buffer stream. The
    /// default does nothing, for sources with no device to choose (the system-audio tap).
    /// Throwing leaves the capture on the device it was already using.
    func switchDevice(uid: String?) async throws
}

extension AudioSource {
    public func switchDevice(uid: String?) async throws {}
}

public protocol TranscriptionEngine: Sendable {
    func preferredFormat() async -> AVAudioFormat
    func start(channels: [Channel], vocabulary: [String]) async throws -> AsyncStream<TranscriptSegment>
    func feed(_ chunk: AudioChunk) async
    func finish() async throws
}

public protocol TrackWriting: Sendable {
    func start(channels: [Channel], format: AVAudioFormat, folder: SessionFolder) throws
    func write(_ chunk: AudioChunk) throws
    func finish() async throws
}

/// A stretch of one side's audio that produced no transcript, bounded by the transcript either
/// side of it: from the end of the last line before the gap to the start of the first line after.
public struct TranscriptGap: Sendable, Equatable {
    public var channel: Channel
    public var start: TimeInterval
    public var end: TimeInterval
    public var seconds: TimeInterval { max(0, end - start) }
    public init(channel: Channel, start: TimeInterval, end: TimeInterval) {
        self.channel = channel; self.start = start; self.end = end
    }
}

/// Recovers speech the live transcriber dropped, from the audio the session has already written.
///
/// The session detects its own dropouts and annotates them; without this it then ships a
/// transcript it knows is incomplete, with the audio that would fill it sitting in the same folder.
public protocol TranscriptBackfilling: Sendable {
    /// Re-transcribes `gaps` from `folder`'s audio, returning what it recovered in session time.
    /// Throwing leaves the transcript as it was, with a note saying the recovery failed.
    func recover(gaps: [TranscriptGap], folder: SessionFolder) async throws -> [TranscriptSegment]
}

public protocol ShotSource: Sendable {
    func start(folder: SessionFolder, sessionTime: @escaping @Sendable () -> TimeInterval) -> AsyncStream<ScreenshotEvent>
    func stop()
}

public struct SessionConfig: Sendable {
    public var root: URL
    public var mode: SessionMode
    public var input: InputDevice
    public var locale: String
    public var vocabulary: [String]
    public var vocabularyFileURL: URL?
    public var silencePeriod: TimeInterval?
    /// How long one side may stay silent while the other talks before the session says so.
    /// `nil` switches the check off.
    public var asymmetryPeriod: TimeInterval?
    public var engineInfo: EngineInfo
    public var appVersion: String
    public var timeZone: TimeZone
    public init(root: URL, mode: SessionMode, input: InputDevice, locale: String, vocabulary: [String],
                vocabularyFileURL: URL?, silencePeriod: TimeInterval?, asymmetryPeriod: TimeInterval? = nil,
                engineInfo: EngineInfo, appVersion: String, timeZone: TimeZone = .current) {
        self.root = root; self.mode = mode; self.input = input; self.locale = locale; self.vocabulary = vocabulary
        self.vocabularyFileURL = vocabularyFileURL; self.silencePeriod = silencePeriod; self.asymmetryPeriod = asymmetryPeriod
        self.engineInfo = engineInfo; self.appVersion = appVersion; self.timeZone = timeZone
    }
}
