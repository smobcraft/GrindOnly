import sys
import unittest
from pathlib import Path


BOT_DIR = Path(__file__).resolve().parents[1] / "tools" / "discord-bot"
sys.path.insert(0, str(BOT_DIR))

from submissions import normalize_text, normalized_issue_title, submission_fingerprint


class TestSubmissionNormalization(unittest.TestCase):
    def test_normalizes_case_and_whitespace(self):
        self.assertEqual(normalize_text("  Improve   TESTING  "), "improve testing")

    def test_issue_title_is_stable_and_public_shape(self):
        self.assertEqual(
            normalized_issue_title("Suggestion", "  Improve   testing "),
            "[Suggestion] Improve testing",
        )

    def test_fingerprint_is_stable_across_case_and_whitespace(self):
        first = submission_fingerprint("Bug", " Broken Map ", "  Many   pins ", "1.3.19")
        second = submission_fingerprint("bug", "broken map", "many pins", "1.3.19")
        self.assertEqual(first, second)

    def test_fingerprint_changes_when_details_change(self):
        first = submission_fingerprint("Bug", "Broken map", "Map pins overlap", "")
        second = submission_fingerprint("Bug", "Broken map", "Pins are missing", "")
        self.assertNotEqual(first, second)


if __name__ == "__main__":
    unittest.main()
