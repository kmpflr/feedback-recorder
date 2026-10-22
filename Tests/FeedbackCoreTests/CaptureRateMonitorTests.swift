import Testing
import Foundation
@testable import FeedbackCore

/// Feeds `count` buffers that each carry `audio` seconds and arrive `every` seconds apart.
private func run(_ monitor: inout CaptureRateMonitor, channel: Channel = .me,
                 audio: TimeInterval, every: TimeInterval, count: Int, from start: TimeInterval = 0) -> String? {
    var note: String?
    for i in 0..<count {
        if let n = monitor.observe(channel: channel, audioSeconds: audio, at: start + Double(i) * every), note == nil { note = n }
    }
    return note
}

@Test func audioThatKeepsUpWithRealTimeIsNotWorthANote() {
    var monitor = CaptureRateMonitor()
    #expect(run(&monitor, audio: 0.256, every: 0.256, count: 1000) == nil)
}

@Test func audioRecordedAtAThirdOfRealTimeIsReported() {
    // A 16 kHz microphone whose buffers are labelled 48 kHz: every 0.256 s of speech is
    // resampled down to 0.085 s of file. 2026-09-03 lost a whole side of a call this way.
    var monitor = CaptureRateMonitor()
    let note = run(&monitor, audio: 0.256 / 3, every: 0.256, count: 1000)
    #expect(note?.hasPrefix("Me audio is recording at 0.33x real time") == true)
}

@Test func aChannelIsReportedOnlyOnce() {
    var monitor = CaptureRateMonitor()
    #expect(run(&monitor, audio: 0.085, every: 0.256, count: 1000) != nil)
    #expect(run(&monitor, audio: 0.085, every: 0.256, count: 1000, from: 500) == nil)
}

@Test func aSourceThatGoesQuietForAWhileIsNotMistakenForLostAudio() {
    // System audio delivers nothing at all while nothing is playing. The gap between buffers is
    // then minutes long and says nothing about whether the audio that did arrive was recorded
    // correctly, so it must not count towards the comparison.
    var monitor = CaptureRateMonitor()
    var note: String?
    var time: TimeInterval = 0
    for block in 0..<20 {
        for _ in 0..<200 {                              // ~51 s of continuous audio
            if let n = monitor.observe(channel: .them, audioSeconds: 0.256, at: time), note == nil { note = n }
            time += 0.256
        }
        time += Double(block + 1) * 120                 // then a long silence with no buffers at all
    }
    #expect(note == nil)
}

@Test func aVerdictIsNotReachedBeforeEnoughAudioHasFlowed() {
    var monitor = CaptureRateMonitor()
    #expect(run(&monitor, audio: 0.085, every: 0.256, count: 100) == nil)   // ~25 s of input
    #expect(run(&monitor, audio: 0.085, every: 0.256, count: 200, from: 25.6) != nil)
}

@Test func channelsAreJudgedIndependently() {
    var monitor = CaptureRateMonitor()
    #expect(run(&monitor, channel: .them, audio: 0.256, every: 0.256, count: 1000) == nil)
    #expect(run(&monitor, channel: .me, audio: 0.085, every: 0.256, count: 1000) != nil)
}

@Test func audioArrivingFasterThanRealTimeIsAlsoReported() {
    var monitor = CaptureRateMonitor()
    #expect(run(&monitor, audio: 0.768, every: 0.256, count: 1000)?.contains("3.00x") == true)
}
