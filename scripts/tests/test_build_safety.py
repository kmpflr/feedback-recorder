"""Exercise update ordering with fake system commands; never touch a running app or keychain."""
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]


class BuildSafetyTests(unittest.TestCase):
    def run_build(self, quit_fails):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            (root / 'scripts').mkdir()
            shutil.copy2(REPO / 'scripts/build.sh', root / 'scripts/build.sh')
            (root / 'Resources').mkdir()
            for name in ('Info.plist', 'vocab.example.txt', 'AppIcon.icns'):
                (root / 'Resources' / name).write_text('fixture')
            (root / '.build/release').mkdir(parents=True)
            (root / '.build/release/FeedbackRecorder').write_text('new binary')
            (root / 'FeedbackRecorder.app').mkdir()
            (root / 'FeedbackRecorder.app/original').write_text('keep until quit')
            (root / 'running').touch()
            commands = {
                'security': "echo '1) fixture Feedback Recorder Dev'",
                'swift': 'exit 0',
                'codesign': 'exit 0',
                'pgrep': 'test -f running',
                'osascript': "test -f FeedbackRecorder.app/original || exit 9\ncat >/dev/null\n" +
                             ('exit 1' if quit_fails else 'rm running'),
            }
            (root / 'bin').mkdir()
            for name, body in commands.items():
                file = root / 'bin' / name
                file.write_text('#!/bin/sh\n' + body + '\n')
                file.chmod(0o755)
            env = dict(os.environ, PATH=str(root / 'bin') + ':/usr/bin:/bin', FR_NO_LAUNCH='1')
            result = subprocess.run(['/bin/zsh', str(root / 'scripts/build.sh')], env=env,
                                    capture_output=True, text=True, timeout=5)
            return result, (root / 'FeedbackRecorder.app/original').exists(), (root / 'FeedbackRecorder.app/Contents/MacOS/FeedbackRecorder').exists()

    def test_failed_quit_preserves_existing_bundle(self):
        result, original, replacement = self.run_build(quit_fails=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(original)
        self.assertFalse(replacement)

    def test_successful_quit_precedes_bundle_replacement(self):
        result, original, replacement = self.run_build(quit_fails=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(original)
        self.assertTrue(replacement)


if __name__ == '__main__':
    unittest.main()
