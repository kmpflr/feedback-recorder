import Foundation

/// Requests a stop when every tracked channel has stayed below the threshold for `period` seconds.
public struct SilenceWatchdog: Sendable {
    public let thresholdDBFS: Double
    public let period: TimeInterval?          // nil = disabled
    private var lastLoud: [Channel: TimeInterval]

    public init(channels: [Channel], period: TimeInterval?, startTime: TimeInterval, thresholdDBFS: Double = -50) {
        self.period = period
        self.thresholdDBFS = thresholdDBFS
        self.lastLoud = Dictionary(uniqueKeysWithValues: channels.map { ($0, startTime) })
    }

    /// Returns true when the session should stop for silence.
    public mutating func observe(levelDBFS: Double, channel: Channel, at time: TimeInterval) -> Bool {
        guard lastLoud[channel] != nil else { return false }
        if levelDBFS > thresholdDBFS { lastLoud[channel] = time }
        guard let period else { return false }
        return lastLoud.values.allSatisfy { time - $0 >= period }
    }
}
