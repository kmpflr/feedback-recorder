import Foundation
import AVFAudio

public enum FormatConverterError: Error { case cannotConvert(String), conversionFailed(String) }

/// Holds the one input buffer a `convert(_:)` call has yet to hand to the converter.
///
/// `AVAudioConverterInputBlock` is marked `@Sendable` by the SDK even though
/// `converter.convert(to:error:withInputFrom:)` invokes it synchronously, on the calling thread,
/// before returning. Capturing a raw `var` (or a raw, non-Sendable `AVAudioPCMBuffer`) directly in
/// that block trips the Swift 6 Sendable-capture checker even though nothing actually runs
/// concurrently here. Boxing the pending buffer in this `@unchecked Sendable` reference type lets
/// the block read and clear it without a false-positive warning; it's never touched from more than
/// one thread because the call that creates it is the same call that consumes it.
private final class PendingInput: @unchecked Sendable {
    var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

/// Wraps a single persistent AVAudioConverter for one direction; not thread-safe, one instance per channel.
///
/// This is a STREAMING converter: it keeps the same `AVAudioConverter` (and its internal
/// filter/resampler history) across every call to `convert(_:)`. Resetting the converter per
/// call, or sending `.endOfStream` per call, would zero the resampler's history and introduce a
/// transient at every chunk boundary — and once a reused converter has been sent `.endOfStream`
/// it is permanently finished (later calls return zero frames). So each `convert(_:)` hands the
/// input buffer over exactly once and returns whatever the converter produced for it, which is a
/// variable, not fixed, number of frames — that variability is expected for a streaming resampler.
/// Call `flush()` once, after the last `convert(_:)`, to drain the samples the converter is still
/// holding internally.
public final class FormatConverter {
    private let converter: AVAudioConverter
    public let inputFormat: AVAudioFormat
    public let outputFormat: AVAudioFormat

    public init(from: AVAudioFormat, to: AVAudioFormat) throws {
        guard let c = AVAudioConverter(from: from, to: to) else {
            throw FormatConverterError.cannotConvert("\(from) -> \(to)")
        }
        converter = c; inputFormat = from; outputFormat = to
    }

    public func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        // Same format in and out: hand back the caller's buffer by reference intentionally —
        // there is nothing to convert, and copying would just waste a buffer allocation.
        if input.format == outputFormat { return input }

        let ratio = outputFormat.sampleRate / input.format.sampleRate
        // Generous capacity: streaming output size varies call to call, and running short would
        // clamp real output. Extra unused frames cost nothing but frameCapacity.
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw FormatConverterError.conversionFailed("buffer")
        }
        let pending = PendingInput(input)
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, statusPtr in
            guard let buffer = pending.buffer else {
                statusPtr.pointee = .noDataNow
                return nil
            }
            pending.buffer = nil
            statusPtr.pointee = .haveData
            return buffer
        }
        if let error { throw FormatConverterError.conversionFailed(error.localizedDescription) }
        switch status {
        case .error:
            throw FormatConverterError.conversionFailed("AVAudioConverter reported .error with no NSError")
        case .haveData, .inputRanDry, .endOfStream:
            return out
        @unknown default:
            return out
        }
    }

    /// Drains whatever samples the converter is still holding internally after the last
    /// `convert(_:)` call. Call this once, at the end of a session, per channel.
    ///
    /// After `flush()` the underlying `AVAudioConverter` has received `.endOfStream` and is
    /// finished: it must not be reused for further `convert(_:)` calls. Session teardown creates
    /// a fresh `FormatConverter` per session, so this is a one-shot per instance by design.
    public func flush() throws -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 8192) else {
            throw FormatConverterError.conversionFailed("buffer")
        }
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, statusPtr in
            statusPtr.pointee = .endOfStream
            return nil
        }
        if let error { throw FormatConverterError.conversionFailed(error.localizedDescription) }
        if status == .error {
            throw FormatConverterError.conversionFailed("AVAudioConverter reported .error with no NSError")
        }
        return out.frameLength > 0 ? out : nil
    }
}
