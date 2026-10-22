import Foundation

/// Aligns per-channel analyzer time (seconds since that channel's first buffer) to the session clock.
public struct ChannelClock: Sendable {
    public let sessionStartHostTime: UInt64
    private let secondsPerHostTick: Double
    private var firstBufferHostTime: [Channel: UInt64] = [:]

    public init(sessionStartHostTime: UInt64, secondsPerHostTick: Double = ChannelClock.machSecondsPerTick()) {
        self.sessionStartHostTime = sessionStartHostTime
        self.secondsPerHostTick = secondsPerHostTick
    }

    public mutating func noteBuffer(channel: Channel, hostTime: UInt64) {
        if firstBufferHostTime[channel] == nil { firstBufferHostTime[channel] = hostTime }
    }

    public func sessionTime(channel: Channel, analyzerTime: TimeInterval) -> TimeInterval {
        let first = firstBufferHostTime[channel] ?? sessionStartHostTime
        return max(0, analyzerTime + seconds(from: sessionStartHostTime, to: first))
    }

    public func sessionTime(hostTime: UInt64) -> TimeInterval {
        max(0, seconds(from: sessionStartHostTime, to: hostTime))
    }

    private func seconds(from a: UInt64, to b: UInt64) -> TimeInterval {
        Double(Int64(bitPattern: b &- a)) * secondsPerHostTick
    }

    public static func machSecondsPerTick() -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }
}
