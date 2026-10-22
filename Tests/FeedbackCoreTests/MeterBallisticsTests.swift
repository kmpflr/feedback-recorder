import Testing
@testable import FeedbackCore

// Reports arrive every 100 ms. The shown level should read as "how much this side is talking",
// not jump to every syllable's peak and vanish before the next one.

@Test func aBurstRaisesTheBarPartWayNotAllAtOnce() {
    let b = MeterBallistics(rise: 0.5, fall: 0.1)
    #expect(b.next(shown: 0, measured: 1) == 0.5)
    #expect(b.next(shown: 0.5, measured: 1) == 0.75)
}

@Test func sustainedSpeechFillsTheBarToItsLevelWithinHalfASecond() {
    let b = MeterBallistics(rise: 0.5, fall: 0.1)
    var shown = 0.0
    for _ in 0..<5 { shown = b.next(shown: shown, measured: 0.8) }
    #expect(shown > 0.77 && shown <= 0.8)
}

@Test func silenceLetsTheBarFallOneStepPerReport() {
    let b = MeterBallistics(rise: 0.5, fall: 0.1)
    #expect(abs(b.next(shown: 1, measured: 0) - 0.9) < 1e-9)
    #expect(abs(b.next(shown: 0.35, measured: 0) - 0.25) < 1e-9)
    #expect(b.next(shown: 0.05, measured: 0) == 0)          // never below empty
}

@Test func aQuieterMeasurementAboveTheFallLineIsShownAsIs() {
    let b = MeterBallistics(rise: 0.5, fall: 0.1)
    #expect(b.next(shown: 1, measured: 0.95) == 0.95)
    #expect(b.next(shown: 0.6, measured: 0.6) == 0.6)
}

@Test func theShownLevelStaysInsideTheBar() {
    let b = MeterBallistics(rise: 0.5, fall: 0.1)
    #expect(b.next(shown: 0.9, measured: 1.5) <= 1)
    #expect(b.next(shown: 0, measured: -0.2) == 0)
    #expect(b.next(shown: 1.2, measured: 0) <= 1)
}

@Test func aSingleLoudReportIsBackAtRestInHalfASecond() {
    let b = MeterBallistics(rise: 0.5, fall: 0.1)
    var shown = b.next(shown: 0, measured: 1)   // one 100 ms report of full level
    var reports = 0
    while shown > 0.001 && reports < 50 { shown = b.next(shown: shown, measured: 0); reports += 1 }
    #expect(reports == 5)                        // 0.5 → 0.4 → 0.3 → 0.2 → 0.1 → 0
}

@Test func theDefaultsRiseInAboutAThirdOfASecondAndFallInASecond() {
    let b = MeterBallistics()
    var shown = 0.0
    for _ in 0..<3 { shown = b.next(shown: shown, measured: 1) }
    #expect(shown > 0.85)                        // three reports: 0.5, 0.75, 0.875
    #expect(abs(b.next(shown: 1, measured: 0) - 0.9) < 1e-9)   // ten reports from full to empty
}
