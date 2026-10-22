import Testing
@testable import FeedbackCore

@Test func formatsUnderAnHourAsMMSS() {
    #expect(Timestamp.format(12.9) == "00:12")
    #expect(Timestamp.format(754) == "12:34")
}

@Test func formatsPastAnHourAsHMMSS() {
    #expect(Timestamp.format(3725) == "1:02:05")
}

@Test func parsesBothShapes() {
    #expect(Timestamp.parse("00:12") == 12)
    #expect(Timestamp.parse("1:02:05") == 3725)
    #expect(Timestamp.parse("abc") == nil)
}
