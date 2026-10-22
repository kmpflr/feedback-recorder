import Foundation

public enum TranscriptFormatter {
    public static let mergeGap: TimeInterval = 2.0
    public static let mergeMaxChars = 300

    /// `micCarriedTheCall` is for a call whose far side never reached the Mac: the system-audio
    /// track is empty and the microphone has picked up every voice in the room, including the other
    /// party's. Labelling those lines "Me" asserts a speaker the recording cannot support, so they
    /// are labelled "Room" — the same thing this codebase already means by a single microphone
    /// carrying a whole conversation, and the cue for a reader to take the speaker from the words.
    public static func render(header: SessionHeader, events: [TranscriptEvent], micCarriedTheCall: Bool = false) -> String {
        let mode = micCarriedTheCall
            ? "call (Room = microphone, carrying both sides; the far side never reached this Mac)"
            : header.mode.transcriptDescription
        var lines = [
            "# \(header.title)", "",
            "- Mode: \(mode)",
            "- Input: \(header.inputName)",
            "- Started: \(header.startedText)",
        ]
        let merged = mergedLines(events, micCarriedTheCall: micCarriedTheCall)
        if !merged.isEmpty {
            lines.append("")  // blank line before events
            lines.append(contentsOf: merged)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Newlines in a note or a turn, which `localizedDescription` readily supplies, would split one
    /// event across several transcript lines. The transcript's grammar is one event per line and
    /// `session_tail.py` stops collecting at the first line that does not start with a timestamp,
    /// so a raw newline drops everything after the break. Collapse them to spaces instead.
    static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    /// What a side is called in the transcript. Only the microphone is ever renamed, and only when
    /// it turned out to be carrying the whole call; the merge rule still keys on the channel, so
    /// two sides that happen to share a name are never run together into one speaker's turn.
    static func label(_ channel: Channel, micCarriedTheCall: Bool) -> String {
        micCarriedTheCall && channel == .me ? Channel.room.label : channel.label
    }

    /// Time-ordered lines with the same-speaker merge rule applied.
    static func mergedLines(_ events: [TranscriptEvent], micCarriedTheCall: Bool = false) -> [String] {
        // `sorted(by:)` makes no stability guarantee, so events sharing a timestamp could swap
        // places between renders and rewrite a line the reader has already seen. Breaking ties on
        // the insertion index pins them: every render of the same prefix produces the same lines.
        let sorted = events.enumerated()
            .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
            .map(\.element)
        var out: [String] = []
        var pending: TranscriptSegment?
        func flush() {
            if let p = pending {
                let side = label(p.channel, micCarriedTheCall: micCarriedTheCall)
                out.append("[\(Timestamp.format(p.start))] \(side): \(singleLine(p.text))")
            }
            pending = nil
        }
        for event in sorted {
            switch event {
            case .turn(let seg):
                if var p = pending, p.channel == seg.channel,
                   seg.start - p.end < mergeGap,
                   p.text.count + 1 + seg.text.count <= mergeMaxChars {
                    p.text += " " + seg.text; p.end = seg.end; pending = p
                } else {
                    flush(); pending = seg
                }
            case .shot(let e):
                flush()
                out.append("[\(Timestamp.format(e.time))] ![shot \(String(format: "%03d", e.index))](\(e.relativePath))")
            case .note(let n):
                flush()
                out.append("[\(Timestamp.format(n.time))] (\(singleLine(n.text)))")
            }
        }
        flush()
        return out
    }
}
