import Foundation

/// Reads `whisper-cli -oj` output into transcript segments.
///
/// The JSON carries each segment's bounds twice: `timestamps` as `HH:MM:SS,mmm` strings and
/// `offsets` as integer milliseconds. Only `offsets` is read — it needs no parsing and no locale.
public enum WhisperTranscript {
    private struct Output: Decodable {
        struct Segment: Decodable {
            struct Offsets: Decodable { let from: Int; let to: Int }
            let offsets: Offsets
            let text: String
        }
        let transcription: [Segment]
    }

    /// Segments in session time, from a re-read that began at `offsetBy` seconds into the session.
    ///
    /// Whisper pads its text with a leading space and emits bracketed markers — `[BLANK_AUDIO]`,
    /// `(silence)` — for stretches with nothing on them. Those are not speech and must not reach the
    /// transcript as a speaker's line; a gap that recovers nothing should read as having recovered
    /// nothing.
    public static func parse(_ data: Data, channel: Channel, offsetBy: TimeInterval) throws -> [TranscriptSegment] {
        let output = try JSONDecoder().decode(Output.self, from: data)
        return output.transcription.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !isMarker(text) else { return nil }
            return TranscriptSegment(channel: channel,
                                     start: offsetBy + Double(segment.offsets.from) / 1000,
                                     end: offsetBy + Double(segment.offsets.to) / 1000,
                                     text: text)
        }
    }

    /// A whole line of nothing but a bracketed marker, e.g. `[BLANK_AUDIO]` or `(speaking softly)`.
    static func isMarker(_ text: String) -> Bool {
        (text.hasPrefix("[") && text.hasSuffix("]")) || (text.hasPrefix("(") && text.hasSuffix(")"))
    }
}
