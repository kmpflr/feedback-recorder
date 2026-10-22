import Foundation
import AVFAudio
import FeedbackCore

enum WhisperError: LocalizedError {
    case noExecutable([String])
    case noModel([String])
    case failed(Int32, String)
    case timedOut(Duration)

    var errorDescription: String? {
        switch self {
        case .noExecutable(let tried):
            "whisper-cli not found (looked in \(tried.joined(separator: ", "))). brew install whisper-cpp"
        case .noModel(let tried):
            "no whisper model found (looked in \(tried.joined(separator: ", ")))"
        case .failed(let status, let stderr):
            "whisper-cli exited \(status)\(stderr.isEmpty ? "" : ": \(stderr)")"
        case .timedOut(let limit):
            "whisper-cli did not finish within \(limit)"
        }
    }
}

/// Re-reads the stretches the live transcriber dropped, with whisper.cpp against the session's own
/// audio files.
///
/// Runs after the session has stopped and the tracks are final, so nothing here is on the recording
/// path: a slow or missing whisper costs a note, never a word of audio. Each gap is cut out of the
/// track and passed on its own rather than re-reading the whole file, which keeps the work
/// proportional to what was actually lost.
final class WhisperBackfill: TranscriptBackfilling, @unchecked Sendable {
    private let locale: String
    private let timeout: Duration

    init(localeIdentifier: String, timeout: Duration = .seconds(600)) {
        self.locale = String(localeIdentifier.prefix(2))
        self.timeout = timeout
    }

    func recover(gaps: [TranscriptGap], folder: SessionFolder) async throws -> [TranscriptSegment] {
        let cli = try Self.locateExecutable()
        let model = try Self.locateModel()
        var recovered: [TranscriptSegment] = []
        for gap in gaps {
            let track = folder.audioURL.appendingPathComponent("\(gap.channel.rawValue).m4a")
            guard FileManager.default.fileExists(atPath: track.path) else { continue }
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("fr-backfill-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }

            let wav = scratch.appendingPathComponent("gap.wav")
            guard try Self.extract(track, from: gap.start, to: gap.end, to: wav) else { continue }
            let stem = scratch.appendingPathComponent("gap")
            try await run(cli: cli, model: model, wav: wav, outputStem: stem)
            let json = try Data(contentsOf: stem.appendingPathExtension("json"))
            recovered += try WhisperTranscript.parse(json, channel: gap.channel, offsetBy: gap.start)
        }
        return recovered
    }

    // MARK: the subprocess

    private func run(cli: String, model: String, wav: URL, outputStem: URL) async throws {
        let result = try await LocalProcess.run(
            executable: URL(fileURLWithPath: cli),
            arguments: ["-m", model, "-f", wav.path, "-l", locale, "-oj", "-of", outputStem.path, "-np", "-nt"],
            timeout: timeout)
        if result.timedOut { throw WhisperError.timedOut(timeout) }
        guard result.status == 0 else {
            throw WhisperError.failed(result.status, String(result.stderr.suffix(300)))
        }
    }

    // MARK: cutting the gap out of the track

    /// What whisper.cpp wants: 16 kHz mono.
    static let whisperRate: Double = 16_000

    /// Writes `from`…`to` of `track` as a 16 kHz mono 16-bit WAV. Returns false when the range lies
    /// past the end of the recording, which a gap left open by a session that stopped mid-sentence
    /// can.
    ///
    /// The tracks are written at whatever format the speech engine asked for, which is 16 kHz
    /// today but is read from the hardware rather than assumed. Declaring 16 kHz in the output file
    /// while copying frames at some other rate would hand whisper a pitch-shifted recording and
    /// timings that drift against the transcript — the same mislabel this codebase has already been
    /// bitten by once — so anything else is resampled rather than relabelled.
    static func extract(_ track: URL, from: TimeInterval, to: TimeInterval, to output: URL) throws -> Bool {
        let input = try AVAudioFile(forReading: track)
        let source = input.processingFormat
        let first = AVAudioFramePosition(max(0, from) * source.sampleRate)
        guard first < input.length else { return false }
        let wanted = AVAudioFrameCount(
            max(0, min(to - max(0, from), Double(input.length - first) / source.sampleRate)) * source.sampleRate)
        guard wanted > 0 else { return false }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: whisperRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let out = try AVAudioFile(forWriting: output, settings: settings,
                                  commonFormat: source.commonFormat, interleaved: source.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 8192) else { return false }

        // Only a rate change needs the converter; at the engine's own rate the frames go straight
        // out, and AVAudioFile does the 16-bit packing on write.
        let resampler: FormatConverter? = source.sampleRate == whisperRate ? nil : try {
            guard let target = AVAudioFormat(commonFormat: source.commonFormat, sampleRate: whisperRate,
                                             channels: 1, interleaved: source.isInterleaved) else {
                throw FormatConverterError.cannotConvert("\(source) -> \(whisperRate) Hz mono")
            }
            return try FormatConverter(from: source, to: target)
        }()

        input.framePosition = first
        var remaining = wanted
        while remaining > 0 {
            try input.read(into: buffer, frameCount: min(remaining, buffer.frameCapacity))
            if buffer.frameLength == 0 { break }
            remaining -= buffer.frameLength
            if let resampler {
                let converted = try resampler.convert(buffer)
                if converted.frameLength > 0 { try out.write(from: converted) }
            } else {
                try out.write(from: buffer)
            }
        }
        if let resampler, let tail = try? resampler.flush(), tail.frameLength > 0 { try out.write(from: tail) }
        return true
    }

    // MARK: finding whisper
    //
    // A GUI app inherits almost no PATH, so the usual locations are tried by hand. Both can be
    // overridden with `defaults write local.feedback-recorder whisperExecutable|whisperModel`.

    static let executableCandidates = [
        "/opt/homebrew/bin/whisper-cli",
        "/usr/local/bin/whisper-cli",
        "/opt/homebrew/opt/whisper-cpp/bin/whisper-cli",
    ]

    static let modelCandidates = [
        "/opt/homebrew/share/whisper-cpp/models/ggml-large-v3-turbo.bin",
        "/usr/local/share/whisper-cpp/models/ggml-large-v3-turbo.bin",
        "/opt/homebrew/share/whisper-cpp/models/ggml-base.en.bin",
    ]

    static func locateExecutable() throws -> String {
        if let set = Settings.whisperExecutable, FileManager.default.isExecutableFile(atPath: set) { return set }
        guard let found = executableCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw WhisperError.noExecutable(executableCandidates)
        }
        return found
    }

    static func locateModel() throws -> String {
        if let set = Settings.whisperModel, FileManager.default.fileExists(atPath: set) { return set }
        guard let found = modelCandidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw WhisperError.noModel(modelCandidates)
        }
        return found
    }
}
