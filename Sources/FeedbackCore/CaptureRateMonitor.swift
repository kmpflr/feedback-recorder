import Foundation

/// Notices when a channel's recording is not keeping up with the audio going into it.
///
/// A capture can be wrong about the rate its hardware delivers and still look entirely healthy:
/// buffers arrive, levels move, the silence watchdog stays quiet, files grow. What comes out is
/// a recording at a fraction of real time, three times too fast, which no transcriber can read.
/// The `Me` side of a 24-minute call was lost that way on 2026-09-03 with nothing in the
/// transcript to say so.
///
/// The comparison that catches it: a buffer covering a tenth of a second of audio should arrive
/// about a tenth of a second after the last one. Gaps longer than `gapCap` are dropped from the
/// comparison rather than counted as loss — a source that pauses is not a source that is losing
/// audio, and system audio delivers nothing at all while nothing is playing.
public struct CaptureRateMonitor: Sendable {
    public let gapCap: TimeInterval
    public let minimumSpan: TimeInterval
    public let low: Double
    public let high: Double

    private var recorded: [Channel: TimeInterval] = [:]
    private var span: [Channel: TimeInterval] = [:]
    private var lastArrival: [Channel: TimeInterval] = [:]
    private var reported: Set<Channel> = []

    public init(gapCap: TimeInterval = 2, minimumSpan: TimeInterval = 30, low: Double = 0.7, high: Double = 1.4) {
        self.gapCap = gapCap; self.minimumSpan = minimumSpan; self.low = low; self.high = high
    }

    /// Drops everything measured for a channel, so its next verdict is reached from scratch. For a
    /// device change mid-session: the pace of the device that has gone says nothing about the one
    /// that replaced it, and a channel already reported must be able to be judged again.
    public mutating func forget(channel: Channel) {
        recorded[channel] = nil
        span[channel] = nil
        lastArrival[channel] = nil
        reported.remove(channel)
    }

    /// Returns the note to write when this channel is first found to be off the pace, and `nil`
    /// every other time — including for good, once a channel has been reported.
    public mutating func observe(channel: Channel, audioSeconds: TimeInterval, at arrival: TimeInterval) -> String? {
        defer { lastArrival[channel] = arrival }
        guard !reported.contains(channel) else { return nil }
        // Audio counts only against the gap it arrived over: the first buffer of a channel, and
        // the first after a pause, have no gap to be measured against and would otherwise bias
        // the ratio by a whole buffer.
        if let last = lastArrival[channel] {
            let gap = arrival - last
            if gap > 0, gap <= gapCap {
                span[channel, default: 0] += gap
                recorded[channel, default: 0] += audioSeconds
            }
        }
        guard let span = span[channel], span >= minimumSpan, let recorded = recorded[channel] else { return nil }
        let ratio = recorded / span
        guard ratio < low || ratio > high else { return nil }
        reported.insert(channel)
        return "\(channel.label) audio is recording at \(String(format: "%.2f", ratio))x real time "
             + "(\(Int(recorded)) s captured from \(Int(span)) s of input)"
    }
}
