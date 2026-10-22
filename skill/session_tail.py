#!/usr/bin/env python3
"""Print a Feedback Recorder session's transcript header, the lines after a timestamp,
the screenshots those lines reference, and a JSON footer.

Usage: session_tail.py <session-dir> [--after MM:SS]
"""
import argparse, json, pathlib, re, sys

LINE = re.compile(r"^\[(\d+:\d{2}(?::\d{2})?)\] (.*)$")
SHOT = re.compile(r"!\[shot \d+\]\(([^)]+)\)")


def parse_ts(text):
    parts = [int(p) for p in text.split(":")]
    return parts[0] * 60 + parts[1] if len(parts) == 2 else parts[0] * 3600 + parts[1] * 60 + parts[2]


def split_transcript(text):
    """Returns (header_lines, [(seconds, raw_line), ...])."""
    header, lines = [], []
    for raw in text.splitlines():
        m = LINE.match(raw)
        if m:
            lines.append((parse_ts(m.group(1)), raw))
        elif not lines:
            header.append(raw)
    return header, lines


def referenced_shots(session, lines):
    """Only expose PNGs inside this session's shots folder, including after symlink resolution."""
    shots_root = session.resolve() / "shots"
    paths = []
    for raw in lines:
        for match in SHOT.finditer(raw):
            relative = pathlib.Path(match.group(1))
            candidate = (session / relative).resolve()
            if relative.is_absolute() or not candidate.is_relative_to(shots_root) or candidate.suffix.lower() != ".png":
                print("Ignored an image reference outside the session's PNG shots.", file=sys.stderr)
                continue
            if candidate.is_file() and str(candidate) not in paths:
                paths.append(str(candidate))
    return paths


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("session", type=pathlib.Path)
    ap.add_argument("--after", help="only lines strictly after this MM:SS or H:MM:SS")
    args = ap.parse_args(argv)

    transcript = (args.session / "transcript.md").read_text(encoding="utf-8")
    header, lines = split_transcript(transcript)
    after = parse_ts(args.after) if args.after else -1
    selected = [raw for secs, raw in lines if secs > after]

    print("\n".join(header).rstrip())
    print()
    print("\n".join(selected) if selected else "(no new lines)")
    shots = referenced_shots(args.session, selected)
    print("\nShots:")
    for shot in shots:
        print(shot)

    state = "unknown"
    state_path = args.session / "session.json"
    if state_path.exists():
        state = json.loads(state_path.read_text(encoding="utf-8")).get("state", "unknown")
    last = LINE.match(lines[-1][1]).group(1) if lines else None
    print(json.dumps({"state": state, "lastTimestamp": last, "lineCount": len(selected)}))


if __name__ == "__main__":
    main()
