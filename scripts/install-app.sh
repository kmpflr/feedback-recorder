#!/bin/zsh
# Build, sign and install the app into /Applications, then launch it from there.
# The copy in the repo root is a build artifact; this is the one to keep.
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="/Applications/Feedback Recorder.app"

# build.sh checks the signing identity, refuses while a session is recording, and quits any
# running instance. Skip its launch so the installed copy is the one that starts.
FR_NO_LAUNCH=1 scripts/build.sh

if [[ ! -w /Applications ]]; then
  echo "/Applications is not writable by $(whoami) — run: sudo cp -R FeedbackRecorder.app \"$DEST\""
  exit 1
fi

rm -rf "$DEST"
# `cp -R` preserves the signature; verifying afterwards catches a copy that damaged it.
cp -R FeedbackRecorder.app "$DEST"
codesign --verify --verbose=2 "$DEST"
open "$DEST"
echo "installed $DEST"
