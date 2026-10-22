import Testing
@testable import FeedbackCore

private let header = SessionHeader(title: "Feedback session 2026-09-02 14:30", mode: .call,
                                   inputName: "Jabra Evolve2 65", startedText: "2026-09-02 14:30:12")

@Test func rendersHeaderThenLinesInTimeOrderAcrossChannels() {
    let events: [TranscriptEvent] = [
        .turn(TranscriptSegment(channel: .me, start: 20, end: 23, text: "Yeah, that is the cold start.")),
        .turn(TranscriptSegment(channel: .them, start: 12, end: 18, text: "The BOM page takes ages to load.")),
    ]
    let out = TranscriptFormatter.render(header: header, events: events)
    #expect(out == """
    # Feedback session 2026-09-02 14:30

    - Mode: call (Me = microphone, Them = system audio)
    - Input: Jabra Evolve2 65
    - Started: 2026-09-02 14:30:12

    [00:12] Them: The BOM page takes ages to load.
    [00:20] Me: Yeah, that is the cold start.

    """)
}

@Test func mergesSameChannelWithinTwoSeconds() {
    let events: [TranscriptEvent] = [
        .turn(TranscriptSegment(channel: .them, start: 10, end: 12, text: "And this button")),
        .turn(TranscriptSegment(channel: .them, start: 13.5, end: 15, text: "should be disabled.")),
        .turn(TranscriptSegment(channel: .them, start: 17.5, end: 19, text: "Until a project is picked.")),
    ]
    let lines = TranscriptFormatter.mergedLines(events)
    #expect(lines == ["[00:10] Them: And this button should be disabled.",
                      "[00:17] Them: Until a project is picked."])
}

@Test func doesNotMergeAcrossChannelsOrPastTheCharacterCap() {
    let long = String(repeating: "word ", count: 58).trimmingCharacters(in: .whitespaces) // 289 chars
    let events: [TranscriptEvent] = [
        .turn(TranscriptSegment(channel: .them, start: 0, end: 5, text: long)),
        .turn(TranscriptSegment(channel: .them, start: 5.5, end: 7, text: "more words here")),
        .turn(TranscriptSegment(channel: .me, start: 7.2, end: 8, text: "ok")),
    ]
    let lines = TranscriptFormatter.mergedLines(events)
    #expect(lines.count == 3)
    #expect(lines[1] == "[00:05] Them: more words here")
    #expect(lines[2] == "[00:07] Me: ok")
}

@Test func interleavesShotsAndNotesAndNeverMergesThroughThem() {
    let events: [TranscriptEvent] = [
        .turn(TranscriptSegment(channel: .them, start: 30, end: 31, text: "Look here.")),
        .shot(ScreenshotEvent(index: 1, time: 31.2, relativePath: "shots/001.png")),
        .turn(TranscriptSegment(channel: .them, start: 31.5, end: 33, text: "This one.")),
        .note(NoteEvent(time: 3725, text: "input changed to MacBook Pro Microphone")),
    ]
    let lines = TranscriptFormatter.mergedLines(events)
    #expect(lines == ["[00:30] Them: Look here.",
                      "[00:31] ![shot 001](shots/001.png)",
                      "[00:31] Them: This one.",
                      "[1:02:05] (input changed to MacBook Pro Microphone)"])
}

@Test func eventsSharingATimestampKeepInsertionOrderAcrossRenders() {
    let events: [TranscriptEvent] = [
        .note(NoteEvent(time: 10, text: "input changed to Jabra Evolve2 65")),
        .shot(ScreenshotEvent(index: 1, time: 10, relativePath: "shots/001.png")),
        .turn(TranscriptSegment(channel: .me, start: 10, end: 11, text: "This one.")),
    ]
    let expected = ["[00:10] (input changed to Jabra Evolve2 65)",
                    "[00:10] ![shot 001](shots/001.png)",
                    "[00:10] Me: This one."]
    #expect(TranscriptFormatter.mergedLines(events) == expected)
    // A line already written must not move on the next render, so the same input renders the same.
    #expect(TranscriptFormatter.mergedLines(events) == expected)
    #expect(TranscriptFormatter.mergedLines(events + [.note(NoteEvent(time: 40, text: "later"))]).prefix(3) == expected.prefix(3))
}

@Test func newlinesInNotesAndTurnsCollapseToSpaces() {
    let events: [TranscriptEvent] = [
        .note(NoteEvent(time: 1, text: "audio file error: The file could not be saved.\nTry again.\r\nDisk full.")),
        .turn(TranscriptSegment(channel: .them, start: 2, end: 3, text: "first part\nsecond part")),
    ]
    #expect(TranscriptFormatter.mergedLines(events) == [
        "[00:01] (audio file error: The file could not be saved. Try again. Disk full.)",
        "[00:02] Them: first part second part",
    ])
}

@Test func rendersHeaderOnlyWithSingleTrailingNewlineWhenEmpty() {
    let out = TranscriptFormatter.render(header: header, events: [])
    #expect(out.hasSuffix("- Started: 2026-09-02 14:30:12\n"))
    #expect(!out.hasSuffix("\n\n"))
}

@Test func aCallOnlyTheMicrophoneCarriedLabelsItsLinesRoom() {
    // A microphone-only conversation can contain two speakers. Room describes the capture
    // channel without incorrectly claiming that every line belongs to one person.
    let events: [TranscriptEvent] = [
        .turn(TranscriptSegment(channel: .me, start: 1, end: 3, text: "Thanks for the review.")),
        .turn(TranscriptSegment(channel: .me, start: 9, end: 11, text: "Happy to help.")),
    ]
    let out = TranscriptFormatter.render(header: header, events: events, micCarriedTheCall: true)
    #expect(out.contains("- Mode: call (Room = microphone, carrying both sides; the far side never reached this Mac)"))
    #expect(out.contains("[00:01] Room: Thanks for the review."))
    #expect(out.contains("[00:09] Room: Happy to help."))
    #expect(!out.contains("Me:"))
}

@Test func aCallWithBothSidesKeepsMeAndThem() {
    let events: [TranscriptEvent] = [
        .turn(TranscriptSegment(channel: .me, start: 1, end: 3, text: "Thanks so much.")),
        .turn(TranscriptSegment(channel: .them, start: 9, end: 11, text: "Thank you.")),
    ]
    let out = TranscriptFormatter.render(header: header, events: events)
    #expect(out.contains("- Mode: call (Me = microphone, Them = system audio)"))
    #expect(out.contains("[00:01] Me: Thanks so much."))
    #expect(out.contains("[00:09] Them: Thank you."))
}

@Test func relabellingDoesNotMergeMeAndThemIntoOneTurn() {
    // Two sides relabelled to the same name are still two sides; merging them would invent a
    // single speaker saying both halves.
    let events: [TranscriptEvent] = [
        .turn(TranscriptSegment(channel: .me, start: 1, end: 2, text: "Can you do it isolated?")),
        .turn(TranscriptSegment(channel: .them, start: 2.5, end: 3, text: "That's correct.")),
    ]
    let out = TranscriptFormatter.render(header: header, events: events, micCarriedTheCall: true)
    #expect(out.contains("[00:01] Room: Can you do it isolated?"))
    #expect(out.contains("[00:02] Them: That's correct."))
}
