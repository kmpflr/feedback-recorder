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
APP=.build/FeedbackRecorder.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/FeedbackRecorder "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/vocab.example.txt "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign "$IDENTITY" --identifier local.feedback-recorder "$APP"
codesign --verify --verbose=2 "$APP"
# Ask the running app to finish its session before replacing any installed/built bundle.
# This also handles a custom sessionRoot and an in-progress startup. Never force-kill it.
if pgrep -x FeedbackRecorder >/dev/null; then
  osascript <<'APPLESCRIPT'
with timeout of 20 seconds
  tell application id "local.feedback-recorder" to quit
end timeout
APPLESCRIPT
  for _ in {1..100}; do
    pgrep -x FeedbackRecorder >/dev/null || break
    sleep 0.2
  done
  if pgrep -x FeedbackRecorder >/dev/null; then
    echo 'Feedback Recorder is still finishing. Wait for it to quit, then run this script again.' >&2
    exit 1
  fi
fi
rm -rf FeedbackRecorder.app
mv "$APP" FeedbackRecorder.app
APP=FeedbackRecorder.app
if [[ -n "${FR_NO_LAUNCH:-}" ]]; then
  echo "built $APP"
else
  open "$APP"
  echo "launched $APP"
fi
