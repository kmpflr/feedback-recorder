#!/bin/zsh
# Release build → FeedbackRecorder.app in the repo root, signed with the self-signed identity, then launched.
set -euo pipefail
cd "$(dirname "$0")/.."
IDENTITY="Feedback Recorder Dev"
IDENTITY_LINE=$(security find-identity -v -p codesigning | grep "$IDENTITY" || true)
if [[ -z "$IDENTITY_LINE" ]]; then
  echo "run scripts/make-cert.sh first"
  exit 1
fi
if [[ "$IDENTITY_LINE" == *CSSMERR_TP_NOT_TRUSTED* ]]; then
  echo 'identity "Feedback Recorder Dev" exists but is not trusted — approve the pending Certificate Trust dialog or set Always Trust in Keychain Access'
  exit 1
fi
swift build -c release 2>&1 | tail -3
APP=FeedbackRecorder.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/FeedbackRecorder "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/vocab.example.txt "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign "$IDENTITY" --identifier local.feedback-recorder "$APP"
codesign --verify --verbose=2 "$APP"
# `pkill` sends SIGTERM, which does not run the app's termination handler, so a session in
# progress would be abandoned: no final transcription, no WAV-to-AAC transcode, and
# `session.json` left saying `recording` until the next launch marks it `crash`. Refuse instead,
# and say how to end it.
if grep -l '"state" : "recording"' "$HOME"/FeedbackSessions/*/session.json >/dev/null 2>&1; then
  echo "a session is still recording — stop it first (press the hotkey, or use the menu) so it finalizes"
  exit 1
fi
pkill -x FeedbackRecorder 2>/dev/null || true
# `open` on a bundle whose previous process is still exiting can be treated as "already running"
# and reactivate the dying instance instead of launching the new binary. Wait for the exit, with a
# bound so a wedged process cannot hang the build.
for _ in {1..25}; do
  pgrep -x FeedbackRecorder >/dev/null || break
  sleep 0.2
done
if [[ -n "${FR_NO_LAUNCH:-}" ]]; then
  echo "built $APP"
else
  open "$APP"
  echo "launched $APP"
fi
