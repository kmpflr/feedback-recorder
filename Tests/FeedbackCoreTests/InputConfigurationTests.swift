import Testing
import AVFAudio
@testable import FeedbackCore

// MARK: tap format

@Test func tapFormatFollowsTheHardwareRateWhenTheNodeStillReportsTheOldDevice() throws {
    // AVAudioEngine's input node keeps reporting the format of whatever device it was
    // created against, so after switching to a 16 kHz headset it still says 48 kHz.
    let stale = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
    let format = try #require(InputConfiguration.tapFormat(nodeFormat: stale, hardwareSampleRate: 16_000))
    #expect(format.sampleRate == 16_000)
    #expect(format.channelCount == 1)
    #expect(format.commonFormat == .pcmFormatFloat32)
}

@Test func tapFormatKeepsTheNodeFormatWhenItAlreadyMatchesTheHardware() throws {
    let node = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
    #expect(InputConfiguration.tapFormat(nodeFormat: node, hardwareSampleRate: 48_000) === node)
}

@Test func tapFormatDefersToTheEngineWhenTheHardwareRateIsUnknown() throws {
    // Installing a tap whose rate disagrees with the hardware aborts the process inside
    // AVFAudio, so a rate we cannot verify must become "you choose" rather than a guess.
    let node = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
    #expect(InputConfiguration.tapFormat(nodeFormat: node, hardwareSampleRate: nil) == nil)
    #expect(InputConfiguration.tapFormat(nodeFormat: node, hardwareSampleRate: 0) == nil)
}

// MARK: what a configuration change should do

private func config(_ name: String, uid: String, rate: Double = 48_000) -> InputConfiguration {
    InputConfiguration(deviceUID: uid, deviceName: name, sampleRate: rate, channelCount: 1)
}

@Test func anUnchangedConfigurationIsIgnored() {
    // Selecting the input device makes CoreAudio raise a configuration change of its own.
    // Restarting for it selects the device again, which raises another — the loop that put
    // 969 "input changed" lines into a 24-minute transcript. Nothing changed, so do nothing.
    let jabra = config("Jabra Link 380", uid: "jabra-uid", rate: 16_000)
    #expect(InputConfiguration.decide(previous: jabra, current: jabra) == .ignore)
}

@Test func aDifferentDeviceRestartsAndIsWorthATranscriptNote() {
    let decision = InputConfiguration.decide(previous: config("Jabra Link 380", uid: "jabra-uid", rate: 16_000),
                                             current: config("MacBook Pro Microphone", uid: "builtin-uid"))
    #expect(decision == .restart(note: "input changed to MacBook Pro Microphone"))
}

@Test func theSameDeviceAtANewRateRestartsSilently() {
    // A headset drops to 16 kHz when its microphone opens. The capture has to follow the
    // new rate, but the reader of the transcript is still on the same device.
    let decision = InputConfiguration.decide(previous: config("Jabra Link 380", uid: "jabra-uid", rate: 48_000),
                                             current: config("Jabra Link 380", uid: "jabra-uid", rate: 16_000))
    #expect(decision == .restart(note: nil))
}

@Test func devicesWithoutUIDsAreComparedByName() {
    let unnamed = InputConfiguration(deviceUID: nil, deviceName: "Some Mic", sampleRate: 48_000, channelCount: 1)
    #expect(InputConfiguration.decide(previous: unnamed, current: unnamed) == .ignore)
    let other = InputConfiguration(deviceUID: nil, deviceName: "Other Mic", sampleRate: 48_000, channelCount: 1)
    #expect(InputConfiguration.decide(previous: unnamed, current: other) == .restart(note: "input changed to Other Mic"))
}

// MARK: telling a real change from the echo of our own device selection

private let jabra = InputConfiguration(deviceUID: "jabra-uid", deviceName: "Jabra Link 380", sampleRate: 16_000, channelCount: 1)
private let builtIn = InputConfiguration(deviceUID: "builtin-uid", deviceName: "MacBook Pro Microphone", sampleRate: 48_000, channelCount: 1)

@Test func theEchoOfOurOwnDeviceSelectionIsIgnored() {
    var tracker = InputConfigurationTracker()
    tracker.started(running: jabra, desired: jabra)
    // Selecting the device raised this notification; nothing about either device has moved.
    #expect(tracker.decide(running: jabra, desired: jabra) == .ignore)
    #expect(tracker.decide(running: jabra, desired: jabra) == .ignore)
}

@Test func aSelectionThatKeepsFailingDoesNotRestartForever() {
    // 2026-09-03: selecting the headset started returning 'nope' and the engine stayed on the
    // built-in microphone. The device asked for never becomes the device in use, so "restart
    // until they agree" would rebuild the engine on every notification for the rest of the call.
    var tracker = InputConfigurationTracker()
    tracker.started(running: builtIn, desired: jabra)
    #expect(tracker.decide(running: builtIn, desired: jabra) == .ignore)
}

@Test func unpluggingTheHeadsetRestartsAndSaysSo() {
    var tracker = InputConfigurationTracker()
    tracker.started(running: jabra, desired: jabra)
    #expect(tracker.decide(running: builtIn, desired: builtIn) == .restart(note: "input changed to MacBook Pro Microphone"))
}

@Test func theHeadsetDroppingToCallRateRestartsSilently() {
    let idle = InputConfiguration(deviceUID: "jabra-uid", deviceName: "Jabra Link 380", sampleRate: 48_000, channelCount: 1)
    var tracker = InputConfigurationTracker()
    tracker.started(running: idle, desired: idle)
    #expect(tracker.decide(running: jabra, desired: jabra) == .restart(note: nil))
}

@Test func aDeviceThatDisappearsRestarts() {
    var tracker = InputConfigurationTracker()
    tracker.started(running: jabra, desired: jabra)
    #expect(tracker.decide(running: nil, desired: nil) == .restart(note: nil))
}

@Test func theFirstNotificationBeforeAnyRestartIsTakenAtItsWord() {
    let tracker = InputConfigurationTracker()
    #expect(tracker.decide(running: jabra, desired: jabra) == .restart(note: "input changed to Jabra Link 380"))
}
