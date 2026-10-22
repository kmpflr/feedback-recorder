# Manual checks

Run against the installed build with a **synthetic conversation**, unrelated private apps closed and a reviewed clipboard. Unit tests and CI do not substitute for this hardware pass. Record what was actually tested; do not claim checks were run merely because they are listed here.

## Menu and multiple displays

1. With menu bars visible on two displays, right-click the recorder on each in turn. The menu must appear at the pointer on that same display, including the first click after switching displays.
2. Repeat with Control-click and Command-click. Cancel with Escape and by clicking outside. Submenus, keyboard navigation and menu actions must still work.
3. During a synthetic recording, repeat plain left-clicks: they open the menu on the clicked display. A plain click while idle starts recording; a hotkey stops it. Stop remains a deliberate menu action.
4. Change which display is primary, try a display positioned above or left of the other, and reconnect a display. Repeat the first three checks. Test an automatically hidden menu bar if used.
5. Confirm that menu timers stop on dismissal and that the clock and image count update while open.

## Recording and recovery

1. On first launch, check the microphone, system-audio and notification prompts. Verify the chosen input appears in the menu.
2. Start a two-track session. Speak a synthetic sentence, play synthetic speech through the Mac and copy a harmless image. Stop and verify both tracks play, timestamps increase, the image link resolves, and `session.json` reports the actual heard channels.
3. Turn system audio off. Record a room-mode sentence; verify `Room` labels and one microphone track.
4. Switch inputs mid-recording and reconnect a microphone. Check the session folder and clock remain the same and device-change notes match what happened.
5. In call mode, leave system audio silent while the microphone carries a conversation for the warning period. Check a one-sided warning appears and that microphone lines become `Room`. Then play speech through system audio and check that the warning clears and channel labels return.
6. Test a heard side falling silent, speech without transcription, device disconnection and wake from sleep. Check the orange state and warning text; use the known-issues document to distinguish detection from automatic recovery.
7. Enable and disable level meters. Confirm microphone/system-audio bars move independently and that the icon remains legible.
8. Test silence auto-stop. Check its fixed noise threshold against the microphone in use; it may not trigger on every device.
9. Quit normally during a synthetic session and verify finalization. Separately, force-quit a disposable synthetic session, relaunch and check crash recovery and retained WAVs.
10. With optional local gap-recovery dependencies installed, verify recovery annotations; without them, verify an explanatory note and preservation of existing audio/transcript.

## Agent handoff

1. Install each agent's skill in a test destination or its documented personal folder. Verify the helper runs there, independently of the checkout's working directory.
2. Choose Codex in **Feedback agent**. Copy a command and stop a synthetic recording; both clipboard results must start with `$feedback`.
3. Choose Claude Code and repeat; both must start with `/feedback`. Restart and confirm the selection persists.
4. In each agent, run the synthetic fixture command from [the demo](demo.md). Confirm the disabled Save request, ambiguous sort-order question and export-column request are identified. Answer “none”; verify no project code changes.
5. Repeat after appending synthetic transcript content. Check only the new material is listed and prior items remain recorded.
