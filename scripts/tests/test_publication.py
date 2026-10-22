import importlib.util
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("publication", ROOT / "scripts/check-publication.py")
publication = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publication)


class PublicationTests(unittest.TestCase):
    def test_clean_email_in_latest_commit_does_not_hide_old_metadata(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = pathlib.Path(scratch)
            def git(*args):
                return subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True)
            git("init", "-b", "main")
            git("config", "user.name", "Example")
            git("config", "user.email", "person" + "@" + "company.test")
            (root / "README.md").write_text("Synthetic test repository\n")
            git("add", ".")
            git("commit", "-m", "Initial")
            git("config", "user.email", "example" + "@" + "users.noreply.github.com")
            git("commit", "--allow-empty", "-m", "Use private email")
            self.assertIn("commit metadata: non-placeholder email address", publication.check(root))

    def test_recordings_are_rejected_even_if_force_added(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = pathlib.Path(scratch)
            subprocess.run(["git", "-C", scratch, "init"], check=True, capture_output=True)
            subprocess.run(["git", "-C", scratch, "config", "user.name", "Example"], check=True)
            subprocess.run(["git", "-C", scratch, "config", "user.email", "example@example.com"], check=True)
            (root / "private.wav").write_bytes(b"synthetic")
            subprocess.run(["git", "-C", scratch, "add", "."], check=True)
            subprocess.run(["git", "-C", scratch, "commit", "-m", "Example"], check=True, capture_output=True)
            self.assertIn("private.wav: recording or credential-like file", publication.check(root))


if __name__ == "__main__":
    unittest.main()
