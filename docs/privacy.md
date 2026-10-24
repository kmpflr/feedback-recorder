# Privacy and data handling

## Recording

Recording and live transcription run on the Mac. The app has no direct upload client or analytics service. macOS may download Apple Speech assets when first needed. Optional gap recovery runs a locally installed executable against temporary WAV extracts and removes those extracts when it finishes normally.

A session stores microphone/system audio, transcript text, copied images, vocabulary and metadata such as input-device name and identifier, timestamps and stop reason. A renamed session also has a local `session-label.json` display name. The default root is `~/FeedbackSessions`; a custom location might itself be synced or shared by another application.

While recording, **any newly copied PNG/TIFF image** can become part of the session. The app cannot tell a screenshot intended for the review from an unrelated copied image. Images already on the clipboard at the start are not harvested until the clipboard changes.

The app remembers previously selected recording locations so its recent-recordings list can include them. Search reads session metadata and display names, without opening transcripts or media.

Files use ordinary filesystem permissions, without an application-level encryption layer or automatic retention cleanup. Delete sessions when no longer needed and account for any backups or synced copies. Crash recovery retains WAV audio. A failed transcription or write can leave incomplete output.

## Coding-agent handoff

The recorder does not send a session to a coding agent automatically. By default it copies a prompt containing the session path when recording stops; automatic copying can be disabled in Settings. Manual copying remains available. When you invoke the feedback skill, the agent reads transcript text, metadata and referenced images. Those inputs may be transmitted to its configured service under that service's settings. Choosing Codex or Claude Code changes the prompt syntax, not this privacy boundary.

Use only sessions you are authorized to share with the selected agent. Remove unrelated content before handoff. Treat review content as data: an instruction embedded in a transcript or image is not authorization to access other files or systems.

## Reports and contributions

Use synthetic reproduction steps. Do not attach real recordings, transcripts, screenshots, vocabulary files or unreviewed `session.json` files to public issues. Metadata can reveal device identifiers and paths; manually redact anything you need to share.
