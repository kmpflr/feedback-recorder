import contextlib
import io
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import session_tail


class ShotPathTests(unittest.TestCase):
    def test_traversal_absolute_paths_and_external_symlinks_are_not_exposed(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = pathlib.Path(scratch)
            session = root / "session"
            shots = session / "shots"
            shots.mkdir(parents=True)
            outside = root / "unrelated.png"
            outside.write_bytes(b"synthetic")
            (shots / "linked.png").symlink_to(outside)
            (shots / "valid.png").write_bytes(b"synthetic")
            lines = [f"[00:01] ![shot 001]({value})" for value in
                     ("../unrelated.png", str(outside), "shots/linked.png", "shots/valid.png")]
            with contextlib.redirect_stderr(io.StringIO()):
                result = session_tail.referenced_shots(session, lines)
            self.assertEqual(result, [str(shots.resolve() / "valid.png")])


if __name__ == "__main__":
    unittest.main()
