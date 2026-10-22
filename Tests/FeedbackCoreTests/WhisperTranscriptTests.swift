import Foundation
import Testing
@testable import FeedbackCore

/// The shape `whisper-cli -oj` writes, trimmed to the fields that are read.
private let sample = Data("""
{
  "systeminfo": "AVX = 0 | NEON = 1",
  "model": { "type": "large" },
  "transcription": [
    {
      "timestamps": { "from": "00:00:00,000", "to": "00:00:04,120" },
      "offsets": { "from": 0, "to": 4120 },
      "text": " So first, comma, is I don't think that we need vendor to CSI as separate."
    },
    {
      "timestamps": { "from": "00:00:04,120", "to": "00:00:06,500" },
      "offsets": { "from": 4120, "to": 6500 },
      "text": " [BLANK_AUDIO]"
    },
    {
      "timestamps": { "from": "00:00:06,500", "to": "00:00:09,000" },
      "offsets": { "from": 6500, "to": 9000 },
      "text": " Can you do it isolated?"
    }
  ]
}
""".utf8)

@Test func whisperSegmentsAreOffsetIntoSessionTime() throws {
    // A gap is re-read on its own, so whisper's clock starts at zero at the gap's start; the
    // segments have to come back where the gap was or they sort to the top of the transcript.
    let segments = try WhisperTranscript.parse(sample, channel: .me, offsetBy: 177)
    #expect(segments.count == 2)
    #expect(segments[0].channel == .me)
    #expect(segments[0].start == 177)
    #expect(segments[0].end == 181.12)
    #expect(segments[0].text == "So first, comma, is I don't think that we need vendor to CSI as separate.")
    #expect(segments[1].start == 183.5)
    #expect(segments[1].text == "Can you do it isolated?")
}

@Test func blankAudioMarkersAreNotSpeech() throws {
    // Whisper labels stretches with nothing on them rather than leaving them out, and those labels
    // would otherwise land in the transcript as something a person said.
    let segments = try WhisperTranscript.parse(sample, channel: .me, offsetBy: 0)
    #expect(!segments.contains { $0.text.contains("BLANK_AUDIO") })
    #expect(WhisperTranscript.isMarker("[BLANK_AUDIO]"))
    #expect(WhisperTranscript.isMarker("(silence)"))
    #expect(!WhisperTranscript.isMarker("That's correct."))
    #expect(!WhisperTranscript.isMarker("[inaudible] but the BOM is right"))
}

@Test func outputWithNoTranscriptionIsEmptyNotAnError() throws {
    let segments = try WhisperTranscript.parse(Data("{\"transcription\":[]}".utf8), channel: .them, offsetBy: 10)
    #expect(segments.isEmpty)
}
