# Manual checks

Run against the installed build with a **synthetic conversation**, unrelated private apps closed and a reviewed clipboard. Unit tests and CI do not substitute for this hardware pass. Record what was actually tested; do not claim checks were run merely because they are listed here.

## Menu and multiple displays

1. With menu bars visible on two displays, right-click the recorder on each in turn. The menu must appear at the pointer on that same display, including the first click after switching displays.
2. Repeat with Control-click and Command-click. Cancel with Escape and by clicking outside. Submenus, keyboard navigation and menu actions must still work.
3. During a synthetic recording, repeat plain left-clicks: they open the menu on the clicked display. A plain click while idle starts recording; a hotkey stops it. Stop remains a deliberate menu action.
4. Change which display is primary, try a display positioned above or left of the other, and reconnect a display. Repeat the first three checks. Test an automatically hidden menu bar if used.
5. Confirm that menu timers stop on dismissal and that the clock and image count update while open.

## Recording and recovery

1. On first launch, check the microphone, system-audio and notification prompts. Try starting before setup finishes; the app must ask you to wait. Verify the chosen input appears in the menu.
2. Start a two-track session. Speak a synthetic sentence, play synthetic speech through the Mac and copy a harmless image. Stop and verify both tracks play, timestamps increase, the image link resolves, and `session.json` reports the actual heard channels.
3. Turn system audio off. Record a room-mode sentence; verify `Room` labels and one microphone track.
4. Switch inputs mid-recording and reconnect a microphone. Check the session folder and clock remain the same and device-change notes match what happened.
5. In call mode, leave system audio silent while the microphone carries a conversation for the warning period. Check a one-sided warning appears and that microphone lines become `Room`. Then play speech through system audio and check that the warning clears and channel labels return.
6. Test a heard side falling silent, speech without transcription, device disconnection and wake from sleep. Check the orange state and warning text; use the known-issues document to distinguish detection from automatic recovery.
7. Enable and disable level meters. Confirm microphone/system-audio bars move independently and that the icon remains legible.
8. Test silence auto-stop. Check its fixed noise threshold against the microphone in use; it may not trigger on every device.
9. Quit normally during startup and during a synthetic session and verify finalization. Run the build/install script during a disposable session with a custom session root; it must let the app finalize and quit before replacing the bundle. Separately, force-quit a disposable synthetic session, relaunch and check crash recovery and retained WAVs.
10. With optional local gap-recovery dependencies installed, verify recovery annotations; without them, verify an explanatory note and preservation of existing audio/transcript.

## Agent handoff

1. Install each agent's skill in a test destination or its documented personal folder. Verify the helper runs there, independently of the checkout's working directory.
2. Choose Codex in **Feedback agent**. Copy a command and stop a synthetic recording; both clipboard results must start with `$feedback`.
3. Choose Claude Code and repeat; both must start with `/feedback`. Restart and confirm the selection persists.
4. In each agent, invoke the skill on the synthetic fixture (`$feedback` or `/feedback` followed by the absolute path to `skill/tests/fixtures/session`). Confirm the disabled Save request, ambiguous sort-order question and export-column request are identified. Answer “none”; verify no project code changes.
5. Repeat after appending synthetic transcript content, extending a line at an existing timestamp, and inserting an earlier recovered turn. Check that new or revised material is identified without duplicating completed items.

## Settings

1. Open Settings from the menu bar. Close with Command-W, reopen, and check that it is the same window. Check light/dark appearance and keyboard navigation between General, Recording and Access.
2. Choose a disposable writable folder; start a synthetic session and confirm it is saved there. Choose another folder during the session: the active session must remain in its original location, and the next must use the new folder.
3. Cancel the folder picker; the saved location must stay unchanged. Try an unavailable or unwritable destination and check that the error is explained without changing the preference. Use Open Folder and Use Default.
4. Change recording defaults during a session and confirm they apply only to the next session. Change level meters and confirm the menu icon updates immediately. Switch the agent from either the menu or Settings and confirm both reflect it.
5. Disable automatic copying, place harmless text on the clipboard, then stop a synthetic recording. The text must remain and the notification must not claim a command was copied. Manual Copy feedback command must still work.
6. Restart the app and verify that folder, agent, copying, meters and recording defaults persist. Check Command-C on the displayed folder path and Command-V in the folder chooser.

## Recent recordings, access and shortcut editing

1. Create several synthetic sessions in two different recording locations. Open Recent recordings and verify both locations appear, newest first. Search by name, date, call/room mode and microphone; try a search with no results. Refresh after creating a session.
2. Rename a session, restart the app and confirm the name persists. Its folder, transcript, media and previously copied feedback command must keep the same paths. Open the selected folder and copy its command. Try an invalid or blank name and an unavailable disk.
3. In Settings → Access, verify the displayed microphone/notification state and cached system-audio/speech check result. Check Again while idle; correct a denied permission in macOS Settings, recheck and verify starting works without relaunching. Confirm checks are disabled during recording and no active or stopped session metadata is rewritten by a recheck.
4. Click the shortcut control. Test a valid new combination, an unmodified typing key, Escape, the current shortcut and an unavailable combination. Valid changes take effect immediately; rejection or cancellation keeps the previous key working. Losing window focus or changing sections must end capture. Reset restores the default. Restart to verify persistence.
5. Confirm the global recording shortcut does not start/stop a session while its editor is listening. Verify the shortened Copy feedback command label with either agent selected.
