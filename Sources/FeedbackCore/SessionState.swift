import Foundation

public enum RecordingState: String, Codable, Sendable { case recording, stopped }
public enum StopReason: String, Codable, Sendable { case user, silence, error, crash }

public struct InputDevice: Codable, Sendable, Equatable {
    public var name: String
    public var uid: String
    public init(name: String, uid: String) { self.name = name; self.uid = uid }
}

public struct EngineInfo: Codable, Sendable, Equatable {
    public var name: String
    public var module: String
    public var locale: String
    public init(name: String, module: String, locale: String) { self.name = name; self.module = module; self.locale = locale }
}

public struct SessionCounts: Codable, Sendable, Equatable {
    public var segments = 0
    public var shots = 0
    public init() {}
}

public struct SessionState: Codable, Sendable, Equatable {
    enum CodingKeys: String, CodingKey {
        case version, state, startedAt, stoppedAt, stopReason, mode, input, systemAudio, heard, engine, counts, durationSeconds, appVersion
    }

    public var version = 1
    public var state: RecordingState = .recording
    public var startedAt: Date
    public var stoppedAt: Date?
    public var stopReason: StopReason?
    public var mode: SessionMode
    public var input: InputDevice
    public var systemAudio: Bool
    /// The sides speech was actually heard on. `systemAudio` records that the tap was asked for;
    /// this records what came down it, so a call that only ever captured one of its two sides is
    /// visible to whoever opens the folder later.
    public var heard: [Channel] = []
    public var engine: EngineInfo
    public var counts = SessionCounts()
    public var durationSeconds = 0
    public var appVersion: String

    public init(startedAt: Date, mode: SessionMode, input: InputDevice, systemAudio: Bool, engine: EngineInfo, appVersion: String) {
        self.startedAt = startedAt; self.mode = mode; self.input = input
        self.systemAudio = systemAudio; self.engine = engine; self.appVersion = appVersion
    }

    public mutating func stop(reason: StopReason, at date: Date) {
        state = .stopped; stopReason = reason; stoppedAt = date
        durationSeconds = Int(date.timeIntervalSince(startedAt).rounded())
    }

    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    public static var decoder: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }
}

extension SessionState {
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(state, forKey: .state)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(stoppedAt, forKey: .stoppedAt)        // encodes null when nil
        try c.encode(stopReason, forKey: .stopReason)
        try c.encode(mode, forKey: .mode)
        try c.encode(input, forKey: .input)
        try c.encode(systemAudio, forKey: .systemAudio)
        try c.encode(heard, forKey: .heard)
        try c.encode(engine, forKey: .engine)
        try c.encode(counts, forKey: .counts)
        try c.encode(durationSeconds, forKey: .durationSeconds)
        try c.encode(appVersion, forKey: .appVersion)
    }
}
