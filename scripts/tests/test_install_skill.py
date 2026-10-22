import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class InstallSkillTests(unittest.TestCase):
    def test_both_agents_get_a_runnable_portable_skill(self):
        with tempfile.TemporaryDirectory(prefix="feedback-install-") as scratch:
            for agent in ("codex", "claude-code"):
                destination = pathlib.Path(scratch) / agent / "feedback"
                subprocess.run([str(ROOT / "scripts/install-skill.sh"), agent, "--dest", str(destination)],
                               cwd=scratch, check=True, capture_output=True, text=True)
                self.assertEqual((destination / "SKILL.md").read_bytes(), (ROOT / "skill/SKILL.md").read_bytes())
                result = subprocess.run(["python3", str(destination / "session_tail.py"),
                                         str(ROOT / "skill/tests/fixtures/session")],
                                        cwd=scratch, check=True, capture_output=True, text=True)
                self.assertIn('"state": "stopped"', result.stdout)
                self.assertIn("Save button", result.stdout)

    def test_unknown_agent_does_not_create_destination(self):
        with tempfile.TemporaryDirectory() as scratch:
            destination = pathlib.Path(scratch) / "feedback"
            result = subprocess.run([str(ROOT / "scripts/install-skill.sh"), "unknown", "--dest", str(destination)],
                                    capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(destination.exists())


if __name__ == "__main__":
    unittest.main()
