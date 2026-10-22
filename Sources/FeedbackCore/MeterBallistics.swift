import Foundation

/// How a level meter's bar follows the level it is fed. Reports arrive several times a second, and
/// a bar that jumped to each report's peak and fell away before the next would flicker with every
/// syllable. Instead the bar closes only part of the gap towards a higher measurement on each
/// report, and drops by at most a fixed step towards a lower one, so a word lifts it and a pause
/// lets it settle rather than snap.
public struct MeterBallistics: Sendable, Equatable {
    /// The share of the gap to a higher measurement the bar closes per report. At 0.5 the bar is
    /// within an eighth of a sustained level after three reports.
    public let rise: Double
    /// The most the bar may drop per report, as a share of full scale. At 0.1 a full bar takes
    /// ten reports to empty.
    public let fall: Double

    public init(rise: Double = 0.5, fall: Double = 0.1) {
        self.rise = rise
        self.fall = fall
    }

    /// The level to show after `measured` (0…1) arrives while `shown` is on the bar.
    public func next(shown: Double, measured: Double) -> Double {
        let shown = min(1, max(0, shown)), measured = min(1, max(0, measured))
        if measured > shown { return shown + (measured - shown) * rise }
        return max(measured, shown - fall)
    }
}
