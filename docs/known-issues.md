# Known issues and deferred work

- Audio-level fallback is heuristic. Quiet microphones, noise and notification sounds can make speech detection unreliable. Silence auto-stop still uses a fixed −50 dBFS threshold and may not trigger on some microphones.
- System-audio capture is not automatically re-established after some output-device changes or sleep interruptions. A warning is written; a new session may be needed.
- A pinned microphone that fails during a device restart can emit more than one diagnostic note.
- Transcript/metadata write failures are retried on a later debounce tick; not every persistent write failure produces an immediate stop or notification.
- An audio-file removal failure during transcoding can skip remaining channels. Retained WAVs should be checked before deleting a session.
- Optional gap recovery needs a separately installed local executable and model. Its process timeout is ten minutes per invocation; a stop can therefore take substantially longer than live transcription finalization.
- Timestamp parsing accepts some noncanonical forms. Session recovery and session creation do not apply identical URL normalization.
- The platform audio writer has no direct unit coverage. Core logic tests do not establish actual capture quality or correct menu placement on every display arrangement.
- Source builds use a local signing identity and are not notarized releases. There is no automatic updater.
- There is no automatic retention cleanup, application-level encryption, in-app transcript editor, launch-at-login option or verified speaker diarization.
