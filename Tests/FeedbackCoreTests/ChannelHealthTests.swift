import Testing
import Foundation
@testable import FeedbackCore

private let room: Double = -60          // a quiet room's floor
private let speech: Double = -20

private func health(channels: [Channel] = [.me, .them], period: TimeInterval? = 180) -> ChannelHealth {
    ChannelHealth(channels: channels, asymmetryPeriod: period)
}

/// Feeds 0.1 s buffers at `level` dBFS on `channel`, covering `seconds` of session time from `from`.
@discardableResult
private func feed(_ h: inout ChannelHealth, _ channel: Channel, level: Double, seconds: TimeInterval, from: TimeInterval) -> [HealthChange] {
    var changes: [HealthChange] = []
    for i in 0..<Int((seconds / 0.1).rounded()) {
        changes += h.observeAudio(channel: channel, levelDBFS: level, audioSeconds: 0.1, at: from + Double(i) * 0.1)
    }
    return changes
}

/// Speech as a microphone hears it: bursts at `peak` between dips back to `floor`, 0.1 s each.
@discardableResult
private func talk(_ h: inout ChannelHealth, _ channel: Channel, peak: Double, floor: Double, seconds: TimeInterval, from: TimeInterval) -> [HealthChange] {
    var changes: [HealthChange] = []
    for i in 0..<Int((seconds / 0.2).rounded()) {
        let t = from + Double(i) * 0.2
        changes += h.observeAudio(channel: channel, levelDBFS: peak, audioSeconds: 0.1, at: t)
        changes += h.observeAudio(channel: channel, levelDBFS: floor, audioSeconds: 0.1, at: t + 0.1)
    }
    return changes
}

/// A finished utterance on `channel`, as the transcriber reports it.
@discardableResult
private func say(_ h: inout ChannelHealth, _ channel: Channel, from start: TimeInterval, to end: TimeInterval) -> [HealthChange] {
    h.observeSegment(channel: channel, start: start, end: end)
}

/// Both sides deliver buffers over the same span, interleaved as a live session would; a side that
/// is talking gets a transcript segment every 20 s covering what it said, as a working engine gives it.
@discardableResult
private func both(_ h: inout ChannelHealth, me: Double, them: Double, seconds: TimeInterval, from: TimeInterval) -> [HealthChange] {
    var changes: [HealthChange] = []
    for i in 0..<Int((seconds / 0.1).rounded()) {
        let t = from + Double(i) * 0.1
        changes += h.observeAudio(channel: .me, levelDBFS: me, audioSeconds: 0.1, at: t)
        changes += h.observeAudio(channel: .them, levelDBFS: them, audioSeconds: 0.1, at: t)
        if i % 200 == 199 {
            if me > room { changes += say(&h, .me, from: t - 19.9, to: t) }
            if them > room { changes += say(&h, .them, from: t - 19.9, to: t) }
        }
    }
    return changes
}

private func raised(_ changes: [HealthChange], _ issue: HealthIssue, on channel: Channel) -> [HealthChange] {
    changes.filter { $0.channel == channel && $0.issue == issue && $0.raised }
}

private func cleared(_ changes: [HealthChange], _ issue: HealthIssue, on channel: Channel) -> [HealthChange] {
    changes.filter { $0.channel == channel && $0.issue == issue && !$0.raised }
}

// MARK: arming

@Test func aSideIsHeardTheMomentTheTranscriberReportsIt() {
    // The engine is the best speech detector in the process; a line of transcript is proof.
    var h = health()
    let changes = say(&h, .me, from: 1, to: 3)
    #expect(h.snapshot.heard == [.me])
    #expect(changes.isEmpty)                      // being heard is state for the icon, not an issue
}

@Test func aSideIsHeardAfterThreeSecondsOfAudioWithTheShapeOfTalking() {
    // The fallback for a side whose transcriber has died: speech-level audio arms it on its own,
    // once there is enough of it and it starts and stops the way talking does. Seconds above the
    // floor are not enough on their own — one unbroken stretch of them is a tone, not a voice.
    var h = health()
    feed(&h, .me, level: room, seconds: 1, from: 0)
    talk(&h, .me, peak: speech, floor: room, seconds: 5, from: 1)      // 2.5 s of it above the floor
    #expect(!h.snapshot.heard.contains(.me))
    talk(&h, .me, peak: speech, floor: room, seconds: 2, from: 6)      // 3.5 s now
    #expect(h.snapshot.heard.contains(.me))
    #expect(!h.snapshot.heard.contains(.them))
}

@Test func aShortDingDoesNotArmASide() {
    // A notification sound through the system-audio tap is half a second of loud audio and no
    // transcript. It must not make Them a side the session then expects to keep hearing from.
    var h = health()
    feed(&h, .them, level: room, seconds: 1, from: 0)
    feed(&h, .them, level: speech, seconds: 0.5, from: 1)
    feed(&h, .them, level: room, seconds: 10, from: 1.5)
    #expect(!h.snapshot.heard.contains(.them))
}

// MARK: the level gate is relative to each side's own floor

@Test func speechBarelyAboveAQuietMicsFloorStillCounts() {
    // Session 2026-09-04_1621, built-in MacBook microphone: silence sat at −50 dBFS and speech
    // peaked at −36 to −38, so a fixed −40 gate saw 1.7 s of "speech" in a minute of talking and
    // the side was never heard. Speech has to be judged against the floor the mic actually has.
    var h = health()
    feed(&h, .me, level: -50, seconds: 2, from: 0)                    // the room, before anyone speaks
    talk(&h, .me, peak: -38, floor: -50, seconds: 8, from: 2)         // 8 s of talking, 4 s of it at the peaks
    #expect(h.snapshot.heard.contains(.me))
}

@Test func aQuieterMicIsJudgedAgainstItsOwnFloor() {
    var h = health()
    feed(&h, .me, level: -75, seconds: 1, from: 0)
    talk(&h, .me, peak: -62, floor: -75, seconds: 8, from: 1)
    #expect(h.snapshot.heard.contains(.me))
}

@Test func steadyNoiseFromTheStartIsNotSpeech() {
    // A fan that is already running when the session starts is the floor, however loud it is.
    var h = health()
    let changes = feed(&h, .me, level: -35, seconds: 60, from: 0)
    #expect(!h.snapshot.heard.contains(.me))
    #expect(changes.isEmpty)
}

@Test func noiseJustAboveTheFloorIsNotSpeech() {
    // The built-in mic's silence wanders up to 3 dB above its own median; that is not talking.
    var h = health()
    feed(&h, .me, level: -50, seconds: 2, from: 0)
    talk(&h, .me, peak: -46, floor: -50, seconds: 60, from: 2)
    #expect(!h.snapshot.heard.contains(.me))
}

// MARK: one-sided silence

@Test func aCallThatOnlyEverHearsOneSideSaysSo() {
    // Phone on speaker with system audio still on: Them never delivers a word while Me carries the
    // whole conversation. The recording is correct — there was nothing on the Mac's output to
    // capture — but half the call is missing from it, and a session that is only recording one side
    // of a two-sided conversation has to say so while there is still time to do something about it.
    var h = health()
    var changes: [HealthChange] = []
    for block in 0..<12 {                                    // 4 min of Me, transcribed as it goes
        let start = Double(block) * 20
        changes += talk(&h, .me, peak: -38, floor: -50, seconds: 20, from: start)
        changes += say(&h, .me, from: start, to: start + 19)
    }
    #expect(raised(changes, .oneSidedRecording, on: .them).count == 1)
    // Not "no speech for 3 min while Me talked" — that side never spoke, so it cannot have fallen
    // silent, and saying it did is what sent the reader looking for audio that was never there.
    #expect(raised(changes, .silentWhileOtherTalks, on: .them).isEmpty)
    #expect(!h.snapshot.isHealthy)
    #expect(h.snapshot.unheard == [.them])
}

@Test func aOneSidedCallStopsBeingOneSidedWhenTheOtherSideSpeaks() {
    var h = health()
    var changes: [HealthChange] = []
    for block in 0..<12 {
        let start = Double(block) * 20
        changes += talk(&h, .me, peak: -38, floor: -50, seconds: 20, from: start)
        changes += say(&h, .me, from: start, to: start + 19)
    }
    #expect(raised(changes, .oneSidedRecording, on: .them).count == 1)
    let back = say(&h, .them, from: 245, to: 255)
    #expect(cleared(back, .oneSidedRecording, on: .them).count == 1)
    #expect(h.snapshot.isHealthy)
}

@Test func roomModeNeverCallsItselfOneSided() {
    // One microphone in a room is the whole recording; there is no other side to be missing.
    var h = health(channels: [.room])
    var changes: [HealthChange] = []
    for block in 0..<12 {
        let start = Double(block) * 20
        changes += talk(&h, .room, peak: -38, floor: -50, seconds: 20, from: start)
        changes += say(&h, .room, from: start, to: start + 19)
    }
    #expect(raised(changes, .oneSidedRecording, on: .room).isEmpty)
    #expect(h.snapshot.isHealthy)
}

@Test func aHeardSideThatFallsSilentWhileTheOtherTalksIsFlagged() {
    var h = health()
    say(&h, .me, from: 0, to: 10)
    say(&h, .them, from: 10, to: 20)
    let changes = both(&h, me: room, them: speech, seconds: 171, from: 20)
    let hits = raised(changes, .silentWhileOtherTalks, on: .me)
    #expect(hits.count == 1)
    #expect(hits.first?.text == "Me: no speech for 3 min while Them talked")
    #expect(h.snapshot.issues[.me] == [.silentWhileOtherTalks])
    #expect(!h.snapshot.isHealthy)
    #expect(h.snapshot.problems == ["Me: no speech for 3 min while Them talked"])
}

@Test func bothSidesQuietIsNotOneSided() {
    var h = health()
    say(&h, .me, from: 0, to: 10)
    say(&h, .them, from: 10, to: 20)
    let changes = both(&h, me: room, them: room, seconds: 600, from: 20)
    #expect(changes.isEmpty)
}

@Test func theOtherSideHasToHaveTalkedForAWhile() {
    var h = health()
    say(&h, .them, from: 0, to: 10)
    say(&h, .me, from: 10, to: 20)
    say(&h, .them, from: 20, to: 25)                                        // 5 s is a "yes, go on"
    let changes = both(&h, me: room, them: room, seconds: 300, from: 25)
    #expect(changes.isEmpty)
}

@Test func theOtherSidesTalkingIsMeasuredByWhatWasTranscribed() {
    // Buffers alone do not make talking: Them's level runs high for minutes, but nothing is
    // transcribed, so Me is not the side with the problem here.
    var h = health()
    say(&h, .me, from: 0, to: 10)
    say(&h, .them, from: 10, to: 20)
    var changes: [HealthChange] = []
    for i in 0..<3000 {                                                    // 300 s, Them loud, no segments
        let t = 20 + Double(i) * 0.1
        changes += h.observeAudio(channel: .me, levelDBFS: room, audioSeconds: 0.1, at: t)
        changes += h.observeAudio(channel: .them, levelDBFS: speech, audioSeconds: 0.1, at: t)
    }
    #expect(raised(changes, .silentWhileOtherTalks, on: .me).isEmpty)
}

@Test func aTranscriptLineFromTheFlaggedSideClearsIt() {
    var h = health()
    say(&h, .me, from: 0, to: 10)
    say(&h, .them, from: 10, to: 20)
    both(&h, me: room, them: speech, seconds: 171, from: 20)
    #expect(h.snapshot.issues[.me] == [.silentWhileOtherTalks])
    let changes = say(&h, .me, from: 190, to: 192)
    let hits = cleared(changes, .silentWhileOtherTalks, on: .me)
    #expect(hits.count == 1)
    #expect(hits.first?.text == "Me: speech resumed")
    #expect(h.snapshot.isHealthy)
}

@Test func audioWithTheShapeOfTalkingFromTheFlaggedSideAlsoClearsIt() {
    // A sentence-shaped signal can clear the warning when transcription is unavailable;
    // a single notification chime cannot.
    var h = health()
    say(&h, .me, from: 0, to: 10)
    say(&h, .them, from: 10, to: 20)
    both(&h, me: room, them: speech, seconds: 171, from: 20)
    #expect(h.snapshot.issues[.me] == [.silentWhileOtherTalks])
    #expect(feed(&h, .me, level: speech, seconds: 0.1, from: 191).isEmpty)
    let changes = talk(&h, .me, peak: speech, floor: room, seconds: 8, from: 191.1)
    #expect(cleared(changes, .silentWhileOtherTalks, on: .me).count == 1)
}

@Test func eachTransitionIsReportedOnce() {
    var h = health()
    say(&h, .me, from: 0, to: 10)
    say(&h, .them, from: 10, to: 20)
    let changes = both(&h, me: room, them: speech, seconds: 600, from: 20)
    #expect(raised(changes, .silentWhileOtherTalks, on: .me).count == 1)
}

@Test func timePassingWithoutBuffersStillRaisesOneSidedSilence() {
    // The quiet side may have stopped delivering buffers altogether, so the rule cannot rely on
    // its own buffers to be re-evaluated; the session ticker asks on its behalf.
    var h = health()
    say(&h, .me, from: 0, to: 10)
    say(&h, .them, from: 10, to: 50)
    #expect(h.observeTime(100).isEmpty)
    let changes = h.observeTime(200)
    #expect(raised(changes, .silentWhileOtherTalks, on: .me).count == 1)
}

@Test func noAudioSuppressesOneSidedSilenceOnTheSameSide() {
    var h = health()
    say(&h, .me, from: 0, to: 10)
    say(&h, .them, from: 10, to: 20)
    #expect(raised(h.set(.noAudio, on: .me, true), .noAudio, on: .me).count == 1)
    var changes: [HealthChange] = []
    for block in 1..<16 { changes += say(&h, .them, from: Double(block) * 20, to: Double(block) * 20 + 19) }
    #expect(raised(changes, .silentWhileOtherTalks, on: .me).isEmpty)
}

@Test func roomModeNeverRaisesOneSidedSilence() {
    var h = health(channels: [.room])
    say(&h, .room, from: 0, to: 10)
    let changes = feed(&h, .room, level: room, seconds: 600, from: 10)
    #expect(changes.isEmpty)
}

@Test func oneSidedSilenceCanBeSwitchedOff() {
    var h = health(period: nil)
    say(&h, .me, from: 0, to: 10)
    say(&h, .them, from: 10, to: 20)
    let changes = both(&h, me: room, them: speech, seconds: 600, from: 20)
    #expect(changes.isEmpty)
}

// MARK: audio without transcript

@Test func speechWithNoTranscriptIsFlaggedAtFortyFiveSeconds() {
    // Half of talking is the dips between words, so 45 s of speech-level audio is ~90 s of talk.
    var h = health()
    feed(&h, .me, level: room, seconds: 1, from: 0)
    var changes = talk(&h, .me, peak: speech, floor: room, seconds: 89.8, from: 1)
    #expect(raised(changes, .noTranscript, on: .me).isEmpty)
    changes = talk(&h, .me, peak: speech, floor: room, seconds: 0.4, from: 90.8)
    let hits = raised(changes, .noTranscript, on: .me)
    #expect(hits.count == 1)
    #expect(hits.first?.text == "Me: 45 s of speech with nothing transcribed")

    let cleared = cleared(say(&h, .me, from: 80, to: 91), .noTranscript, on: .me)
    #expect(cleared.count == 1)
    #expect(cleared.first?.text == "Me: transcription resumed")
    #expect(h.snapshot.isHealthy)
}

@Test func segmentsKeepNoTranscriptQuiet() {
    var h = health()
    feed(&h, .me, level: room, seconds: 1, from: 0)
    var changes: [HealthChange] = []
    for block in 0..<10 {
        let start = 1 + Double(block) * 20
        changes += feed(&h, .me, level: speech, seconds: 20, from: start)
        changes += say(&h, .me, from: start, to: start + 19)
    }
    // Them is flagged as a side nobody was ever heard on, which is a different complaint; what
    // this test is about is that a transcribed side never gets accused of going untranscribed.
    #expect(changes.filter { $0.issue == .noTranscript }.isEmpty)
}

// MARK: promoted conditions

@Test func starvationIsAWarningOnlyForAHeardSide() {
    var h = health()
    #expect(h.set(.noAudio, on: .them, true).isEmpty)
    #expect(h.snapshot.isHealthy)
    say(&h, .them, from: 0, to: 5)
    let on = h.set(.noAudio, on: .them, true)
    #expect(raised(on, .noAudio, on: .them).count == 1)
    #expect(on.first?.text == "Them audio stopped delivering")
    let off = h.set(.noAudio, on: .them, false)
    #expect(cleared(off, .noAudio, on: .them).count == 1)
    #expect(h.snapshot.isHealthy)
}

@Test func wrongRateIsAWarningEvenBeforeASideIsHeard() {
    var h = health()
    let changes = h.set(.wrongRate, on: .me, true)
    #expect(raised(changes, .wrongRate, on: .me).count == 1)
    #expect(changes.first?.text == "Me audio is recording out of step with real time")
}

@Test func settingAConditionThatIsAlreadySetSaysNothing() {
    var h = health()
    say(&h, .me, from: 0, to: 5)
    #expect(h.set(.noAudio, on: .me, true).count == 1)
    #expect(h.set(.noAudio, on: .me, true).isEmpty)
    #expect(h.set(.noAudio, on: .me, false).count == 1)
    #expect(h.set(.noAudio, on: .me, false).isEmpty)
}

// MARK: presentation

@Test func presentationFollowsWhichSidesWereHeard() {
    // A session nobody has spoken into must not look like one where both sides have.
    var h = health()
    #expect(h.snapshot.presentation == .nothingHeard)
    say(&h, .me, from: 0, to: 5)
    #expect(h.snapshot.presentation == .micOnly)
    say(&h, .them, from: 5, to: 10)
    #expect(h.snapshot.presentation == .bothSides)

    var themFirst = health()
    say(&themFirst, .them, from: 0, to: 5)
    #expect(themFirst.snapshot.presentation == .systemAudioOnly)

    var roomMode = health(channels: [.room])
    say(&roomMode, .room, from: 0, to: 5)
    #expect(roomMode.snapshot.presentation == .micOnly)
}

@Test func unheardSidesAreListedInOrder() {
    var h = health()
    #expect(h.snapshot.unheard == [.me, .them])
    say(&h, .me, from: 0, to: 5)
    #expect(h.snapshot.unheard == [.them])
    say(&h, .them, from: 5, to: 10)
    #expect(h.snapshot.unheard.isEmpty)
}

// MARK: level meter

@Test func meterReadsEachSideRelativeToItsOwnFloor() {
    var h = health()
    #expect(h.meterFraction(channel: .me, levelDBFS: -30) == 0)            // nothing heard yet: no floor to read against
    feed(&h, .me, level: -50, seconds: 1, from: 0)
    #expect(h.meterFraction(channel: .me, levelDBFS: -50) == 0)
    #expect(abs(h.meterFraction(channel: .me, levelDBFS: -37.5) - 0.5) < 0.001)
    #expect(h.meterFraction(channel: .me, levelDBFS: -25) == 1)
    #expect(h.meterFraction(channel: .me, levelDBFS: -10) == 1)            // clamped
    #expect(h.meterFraction(channel: .me, levelDBFS: -60) == 0)            // clamped
    #expect(h.meterFraction(channel: .them, levelDBFS: -30) == 0)          // the other side has its own floor
}

// MARK: device changes

@Test func aNewDeviceStartsWithItsOwnFloor() {
    // Switching from a quiet microphone to a noisier one mid-session must not read the new mic's
    // room as fifteen seconds of speech while the old floor climbs to meet it.
    var h = health()
    feed(&h, .me, level: -60, seconds: 2, from: 0)
    h.resetFloor(channel: .me)
    let changes = feed(&h, .me, level: -45, seconds: 30, from: 2)
    #expect(h.meterFraction(channel: .me, levelDBFS: -45) == 0)
    #expect(!h.snapshot.heard.contains(.me))
    #expect(changes.isEmpty)
}

// MARK: a silent tap with chimes on it

/// Synthetic notification tones separated by digital silence. The quiet intervals use
/// the same −120 dBFS clamp as `AudioLevel.rmsDBFS`.
private func chime(_ h: inout ChannelHealth, _ channel: Channel, level: Double, seconds: TimeInterval,
                   from: TimeInterval, thenSilentFor quiet: TimeInterval) -> [HealthChange] {
    var changes = feed(&h, channel, level: level, seconds: seconds, from: from)
    changes += feed(&h, channel, level: AudioLevel.floor, seconds: quiet, from: from + seconds)
    return changes
}

@Test func aLongChimeOnADigitallySilentTapDoesNotArmTheSide() {
    // A tap recording digital zero has its floor pinned at the −120 dBFS clamp, so *any* audible
    // sound clears a gate set 10 dB above it. The join tone is 3.5 s — longer than `armSeconds` —
    // so on total gated seconds alone it armed Them, and the session then believed it was
    // recording a side that had never carried a word.
    var h = health()
    feed(&h, .them, level: AudioLevel.floor, seconds: 0.2, from: 0)
    chime(&h, .them, level: -26, seconds: 3.5, from: 0.2, thenSilentFor: 20)
    #expect(!h.snapshot.heard.contains(.them))
}

@Test func chimesSpreadAcrossASessionDoNotSumIntoASideBeingHeard() {
    // The three tones total 5 s of audio above the floor. Counting gated seconds for the whole
    // session and never letting the total decay turned that into "Them has been heard".
    var h = health()
    feed(&h, .them, level: AudioLevel.floor, seconds: 0.2, from: 0)
    chime(&h, .them, level: -26, seconds: 3.5, from: 0.2, thenSilentFor: 51.5)
    chime(&h, .them, level: -34, seconds: 0.7, from: 55.2, thenSilentFor: 60)
    #expect(!h.snapshot.heard.contains(.them))
    chime(&h, .them, level: -29, seconds: 1.0, from: 1400, thenSilentFor: 60)
    #expect(!h.snapshot.heard.contains(.them))
}

@Test func aSilentTapWithChimesNeverFallsSilentAndResumes() {
    // Chimes on a side with no speech must never be reported as speech resuming.
    // Raise a missing-side warning instead.
    var h = health()
    var changes: [HealthChange] = []
    feed(&h, .them, level: AudioLevel.floor, seconds: 0.2, from: 0)
    changes += chime(&h, .them, level: -26, seconds: 3.5, from: 0.2, thenSilentFor: 51.5)
    changes += chime(&h, .them, level: -34, seconds: 0.7, from: 55.2, thenSilentFor: 10)
    for block in 0..<20 {                                   // Me carries the whole call, transcribed
        let start = 66 + Double(block) * 65
        changes += talk(&h, .me, peak: -38, floor: -50, seconds: 60, from: start)
        changes += say(&h, .me, from: start, to: start + 60)
        changes += h.observeTime(start + 65)
    }
    changes += chime(&h, .them, level: -29, seconds: 1.0, from: 1400, thenSilentFor: 60)
    #expect(raised(changes, .silentWhileOtherTalks, on: .them).isEmpty)
    #expect(cleared(changes, .silentWhileOtherTalks, on: .them).isEmpty)
    #expect(h.snapshot.unheard == [.them])
    // What the session should have said instead, once, and said loudly.
    #expect(raised(changes, .oneSidedRecording, on: .them).count == 1)
}
