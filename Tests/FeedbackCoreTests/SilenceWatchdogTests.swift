import Testing
@testable import FeedbackCore

@Test func firesOnlyWhenEveryChannelHasBeenQuietForTheWholePeriod() {
    var w = SilenceWatchdog(channels: [.me, .them], period: 600, startTime: 0)
    #expect(w.observe(levelDBFS: -80, channel: .me, at: 300) == false)
    #expect(w.observe(levelDBFS: -80, channel: .them, at: 300) == false)
    #expect(w.observe(levelDBFS: -80, channel: .me, at: 599) == false)
    #expect(w.observe(levelDBFS: -80, channel: .them, at: 600) == true)
}

@Test func speechOnAnyChannelResetsThatChannel() {
    var w = SilenceWatchdog(channels: [.me, .them], period: 600, startTime: 0)
    _ = w.observe(levelDBFS: -20, channel: .them, at: 500)     // reviewer speaks
    #expect(w.observe(levelDBFS: -80, channel: .me, at: 700) == false)   // them quiet only 200 s
    #expect(w.observe(levelDBFS: -80, channel: .them, at: 1100) == true)
}

@Test func disabledNeverFiresAndUntrackedChannelsAreIgnored() {
    var off = SilenceWatchdog(channels: [.room], period: nil, startTime: 0)
    #expect(off.observe(levelDBFS: -90, channel: .room, at: 99_999) == false)
    var room = SilenceWatchdog(channels: [.room], period: 60, startTime: 0)
    #expect(room.observe(levelDBFS: -90, channel: .them, at: 1000) == false)  // .them not tracked
    #expect(room.observe(levelDBFS: -90, channel: .room, at: 1000) == true)
}
