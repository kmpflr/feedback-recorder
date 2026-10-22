import AVFAudio
import Testing
@testable import FeedbackCore

private func sine(_ format: AVAudioFormat, frames: Int, hz: Double = 440, startFrame: Int = 0) -> AVAudioPCMBuffer {
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    let data = buffer.floatChannelData![0]
    for i in 0..<frames {
        data[i] = Float(sin(2 * .pi * hz * Double(startFrame + i) / format.sampleRate)) * 0.5
    }
    return buffer
}

@Test func streamsTenBuffersAndFlushDeliversTheWholeSignal() throws {
    let from = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let to = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    let converter = try FormatConverter(from: from, to: to)
    var total = 0
    var largestChunk: AVAudioPCMBuffer?
    for i in 0..<10 {
        let input = sine(from, frames: 4800, startFrame: i * 4800)
        let out = try converter.convert(input)
        #expect(out.frameLength <= out.frameCapacity)
        total += Int(out.frameLength)
        if largestChunk == nil || out.frameLength > largestChunk!.frameLength {
            largestChunk = out
        }
    }
    if let flushed = try converter.flush() {
        #expect(flushed.frameLength <= flushed.frameCapacity)
        total += Int(flushed.frameLength)
        if largestChunk == nil || flushed.frameLength > largestChunk!.frameLength {
            largestChunk = flushed
        }
    }
    #expect(abs(total - 16_000) <= 64)

    let reference = sine(from, frames: 4800)
    if let chunk = largestChunk {
        #expect(abs(AudioLevel.rmsDBFS(chunk) - AudioLevel.rmsDBFS(reference)) < 1.5)
    }
}

@Test func singleCallReturnsSomeFramesWithinCapacity() throws {
    let from = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let to = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    let converter = try FormatConverter(from: from, to: to)
    let input = sine(from, frames: 4800)
    let out = try converter.convert(input)
    #expect(out.frameLength > 0)
    #expect(out.frameLength <= out.frameCapacity)
}

@Test func flushAfterEndOfStreamReturnsNilOnSecondCall() throws {
    let from = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let to = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    let converter = try FormatConverter(from: from, to: to)
    _ = try converter.convert(sine(from, frames: 4800))
    _ = try converter.flush()
    let second = try converter.flush()
    #expect(second == nil || second!.frameLength == 0)
}
