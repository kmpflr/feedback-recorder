import io, json, pathlib, sys, unittest
from contextlib import redirect_stdout

HERE = pathlib.Path(__file__).parent
sys.path.insert(0, str(HERE.parent))
import session_tail  # noqa: E402

FIXTURE = HERE / "fixtures" / "session"


def run(*args):
    out = io.StringIO()
    with redirect_stdout(out):
        session_tail.main([str(FIXTURE), *args])
    return out.getvalue()


class SessionTailTests(unittest.TestCase):
    def test_parse_timestamp_handles_both_shapes(self):
        self.assertEqual(session_tail.parse_ts("00:12"), 12)
        self.assertEqual(session_tail.parse_ts("1:02:05"), 3725)

    def test_without_after_prints_everything_and_footer(self):
        out = run()
        self.assertIn("# Synthetic feedback session 2026-01-01 10:00", out)
        self.assertIn("[00:12] Them: The parts page", out)
        self.assertIn("[1:02:05] Them: Last thing", out)
        self.assertIn(str(FIXTURE / "shots" / "001.png"), out)
        footer = json.loads(out.strip().splitlines()[-1])
        self.assertEqual(footer, {"state": "stopped", "lastTimestamp": "1:02:05", "lineCount": 7})

    def test_after_filters_strictly_and_lists_only_new_shots(self):
        out = run("--after", "00:31")
        self.assertNotIn("[00:31] ![shot 001]", out)
        self.assertIn("[00:34] Them: And this Save button", out)
        self.assertNotIn("shots/001.png", out.split("Shots:")[1])
        footer = json.loads(out.strip().splitlines()[-1])
        self.assertEqual(footer["lineCount"], 4)

    def test_after_past_the_end_reports_zero_lines(self):
        out = run("--after", "2:00:00")
        footer = json.loads(out.strip().splitlines()[-1])
        self.assertEqual(footer["lineCount"], 0)
        self.assertEqual(footer["lastTimestamp"], "1:02:05")


if __name__ == "__main__":
    unittest.main()
