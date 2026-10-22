import Testing
@testable import FeedbackCore

@Test func laterFirstBufferShiftsThatChannelForward() {
    var clock = ChannelClock(sessionStartHostTime: 1_000, secondsPerHostTick: 0.001)   // 1 tick = 1 ms
    clock.noteBuffer(channel: .me, hostTime: 1_000)
    clock.noteBuffer(channel: .them, hostTime: 1_400)                                 // tap started 400 ms late
    clock.noteBuffer(channel: .them, hostTime: 9_999)                                 // later buffers ignored
    #expect(clock.sessionTime(channel: .me, analyzerTime: 10) == 10)
    #expect(abs(clock.sessionTime(channel: .them, analyzerTime: 10) - 10.4) < 1e-9)
    #expect(abs(clock.sessionTime(hostTime: 3_500) - 2.5) < 1e-9)
}

@Test func unknownChannelHasZeroOffsetAndNeverGoesNegative() {
    let clock = ChannelClock(sessionStartHostTime: 5_000, secondsPerHostTick: 0.001)
    #expect(clock.sessionTime(channel: .room, analyzerTime: 3) == 3)
    #expect(clock.sessionTime(hostTime: 4_000) == 0)
}
