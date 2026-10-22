import Testing
import AVFAudio
@testable import FeedbackCore

@Test func silenceIsAtTheFloorAndFullScaleIsZero() {
    #expect(AudioLevel.rmsDBFS([Float](repeating: 0, count: 480)) == -120)
    let full = AudioLevel.rmsDBFS([Float](repeating: 1, count: 480))
    #expect(abs(full) < 0.01)
}

@Test func halfScaleSquareWaveIsMinusSixDB() {
    let half = AudioLevel.rmsDBFS([Float](repeating: 0.5, count: 480))
    #expect(abs(half - (-6.02)) < 0.05)
}

@Test func bufferOverloadReadsChannelZeroOfAMonoFloatBuffer() {
    let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
    buffer.frameLength = 480
    for i in 0..<480 {
        buffer.floatChannelData![0][i] = 0.5
    }
    #expect(abs(AudioLevel.rmsDBFS(buffer) - (-6.02)) < 0.05)
}

@Test func bufferOverloadReturnsFloorForZeroFrames() {
    let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
    buffer.frameLength = 0
    #expect(AudioLevel.rmsDBFS(buffer) == AudioLevel.floor)
}

@Test func bufferOverloadReadsInt16HalfScale() {
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
    buffer.frameLength = 480
    for i in 0..<480 {
        buffer.int16ChannelData![0][i] = 16384
    }
    #expect(abs(AudioLevel.rmsDBFS(buffer) - (-6.02)) < 0.05)
}

@Test func bufferOverloadReturnsFloorForInt16Silence() {
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
    buffer.frameLength = 480
    for i in 0..<480 {
        buffer.int16ChannelData![0][i] = 0
    }
    #expect(AudioLevel.rmsDBFS(buffer) == AudioLevel.floor)
}
