import Foundation
import AVFAudio
import FeedbackCore

enum AudioTrackError: LocalizedError {
    case bufferAllocationFailed

    var errorDescription: String? {
        switch self {
        case .bufferAllocationFailed: "Failed to allocate a PCM buffer for AAC transcoding."
        }
    }
}

/// WAV while recording (playable even after a crash); AAC on clean stop.
final class AudioTrackWriter: TrackWriting, @unchecked Sendable {
    private var files: [Channel: AVAudioFile] = [:]
    private var urls: [Channel: URL] = [:]
    private let lock = NSLock()

    func start(channels: [Channel], format: AVAudioFormat, folder: SessionFolder) throws {
        lock.lock(); defer { lock.unlock() }
        for channel in channels {
            let url = folder.audioURL.appendingPathComponent("\(channel.rawValue).wav")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            files[channel] = try AVAudioFile(forWriting: url, settings: settings,
                                             commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            urls[channel] = url
        }
    }

    func write(_ chunk: AudioChunk) throws {
        lock.lock(); defer { lock.unlock() }
        try files[chunk.channel]?.write(from: chunk.buffer)
    }

    func finish() async throws {
        // NSLock.lock()/unlock() are `noasync` in Swift 6 mode and cannot be called
        // directly from an `async` function body; route through a synchronous helper.
        let pending: [Channel: URL] = withLock {
            files = [:]                       // closes the WAV files
            let urls = self.urls
            self.urls = [:]
            return urls
        }
        for (_, wav) in pending {
            let m4a = wav.deletingPathExtension().appendingPathExtension("m4a")
            try Self.transcode(wav: wav, to: m4a)
            try FileManager.default.removeItem(at: wav)
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    static func transcode(wav: URL, to m4a: URL) throws {
        let input = try AVAudioFile(forReading: wav)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: input.processingFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,
        ]
        let output = try AVAudioFile(forWriting: m4a, settings: settings,
                                     commonFormat: input.processingFormat.commonFormat, interleaved: input.processingFormat.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8192) else {
            throw AudioTrackError.bufferAllocationFailed
        }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
    }
}
