import Foundation
import Testing
@testable import FeedbackCore

@Test func sessionStateRoundTripsThroughJSONWithExpectedKeys() throws {
    var state = SessionState(startedAt: Date(timeIntervalSince1970: 1_756_830_612), mode: .call,
                             input: InputDevice(name: "Jabra Evolve2 65", uid: "AppleUSBAudioEngine:1"),
                             systemAudio: true,
                             engine: EngineInfo(name: "apple-speech", module: "SpeechTranscriber", locale: "en-US"),
                             appVersion: "1.0.0")
    state.counts.segments = 3; state.counts.shots = 1; state.durationSeconds = 42
    let data = try SessionState.encoder.encode(state)
    let json = String(decoding: data, as: UTF8.self)
    #expect(json.contains("\"state\" : \"recording\""))
    #expect(json.contains("\"stopReason\" : null"))
    #expect(json.contains("\"startedAt\" : \"2025-09-02T"))   // ISO 8601, UTC
    let back = try SessionState.decoder.decode(SessionState.self, from: data)
    #expect(back == state)
}

@Test func stopSetsStateAndReason() {
    var state = SessionState(startedAt: Date(timeIntervalSince1970: 0), mode: .room,
                             input: InputDevice(name: "MacBook Pro Microphone", uid: "BuiltIn"),
                             systemAudio: false,
                             engine: EngineInfo(name: "apple-speech", module: "SpeechTranscriber", locale: "en-US"),
                             appVersion: "1.0.0")
    state.stop(reason: .silence, at: Date(timeIntervalSince1970: 600))
    #expect(state.state == .stopped)
    #expect(state.stopReason == .silence)
    #expect(state.durationSeconds == 600)
}

@Test func heardStartsEmptyAndIsCarriedThroughJSON() throws {
    // Requesting system audio does not prove that speech arrived. Preserve the sides
    // actually heard separately from the requested capture configuration.
    var state = SessionState(startedAt: Date(timeIntervalSince1970: 1_756_830_612), mode: .call,
                             input: InputDevice(name: "MacBook Pro Microphone", uid: "BuiltInMicrophoneDevice"),
                             systemAudio: true,
                             engine: EngineInfo(name: "apple-speech", module: "SpeechTranscriber", locale: "en-US"),
                             appVersion: "1.0.0")
    #expect(state.heard.isEmpty)
    state.heard = [.me]
    let data = try SessionState.encoder.encode(state)
    #expect(String(decoding: data, as: UTF8.self).contains("\"heard\" : [\n    \"me\"\n  ]"))
    #expect(try SessionState.decoder.decode(SessionState.self, from: data) == state)
}
