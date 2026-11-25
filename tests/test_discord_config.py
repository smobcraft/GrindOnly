import sys
import tempfile
import unittest
from pathlib import Path


BOT_DIR = Path(__file__).resolve().parents[1] / "tools" / "discord-bot"
sys.path.insert(0, str(BOT_DIR))

from config import load_config
from state import BotState


class TestBotConfig(unittest.TestCase):
    def valid_environment(self):
        return {
            "DISCORD_TOKEN": "discord-test-token",
            "GITHUB_TOKEN": "github-test-token",
            "DISCORD_GUILD_ID": "542025981288906772",
            "DISCORD_FEEDBACK_CHANNEL_ID": "1575205316977754122",
        }

    def test_loads_required_and_optional_configuration(self):
        environ = self.valid_environment()
        environ.update({
            "DISCORD_UPDATES_CHANNEL_ID": "123",
            "DISCORD_MAINTAINER_ID": "456",
            "POLL_INTERVAL_SECONDS": "600",
            "BOT_DATABASE_PATH": "relative/bot.sqlite3",
        })

        config = load_config(environ)

        self.assertEqual(config.guild_id, 542025981288906772)
        self.assertEqual(config.feedback_channel_id, 1575205316977754122)
        self.assertEqual(config.updates_channel_id, 123)
        self.assertEqual(config.maintainer_id, 456)
        self.assertEqual(config.poll_interval_seconds, 600)
        self.assertEqual(config.database_path, Path("relative/bot.sqlite3"))

    def test_missing_required_secret_fails_closed(self):
        environ = self.valid_environment()
        environ.pop("GITHUB_TOKEN")
        with self.assertRaisesRegex(ValueError, "GITHUB_TOKEN is required"):
            load_config(environ)

    def test_malformed_discord_id_fails_closed(self):
        environ = self.valid_environment()
        environ["DISCORD_GUILD_ID"] = "guild-name"
        with self.assertRaisesRegex(ValueError, "exact positive"):
            load_config(environ)

    def test_malformed_optional_maintainer_id_fails_closed(self):
        environ = self.valid_environment()
        environ["DISCORD_MAINTAINER_ID"] = "not-an-id"
        with self.assertRaisesRegex(ValueError, "exact positive"):
            load_config(environ)

    def test_malformed_poll_interval_fails_closed(self):
        environ = self.valid_environment()
        environ["POLL_INTERVAL_SECONDS"] = "soon"
        with self.assertRaisesRegex(ValueError, "positive integer"):
            load_config(environ)

    def test_config_repr_does_not_expose_tokens(self):
        config = load_config(self.valid_environment())
        rendered = repr(config)
        self.assertNotIn("discord-test-token", rendered)
        self.assertNotIn("github-test-token", rendered)


class TestBotState(unittest.TestCase):
    def test_initializes_and_persists_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            database_path = Path(directory) / "state" / "bot.sqlite3"
            state = BotState(database_path)

            state.initialize()
            state.set_meta("restart_marker", "preserved")

            restarted = BotState(database_path)
            self.assertEqual(restarted.get_meta("schema_version"), "4")
            self.assertEqual(restarted.get_meta("restart_marker"), "preserved")
            self.assertTrue(database_path.is_file())

    def test_schema_supports_future_delivery_and_submission_state(self):
        with tempfile.TemporaryDirectory() as directory:
            database_path = Path(directory) / "bot.sqlite3"
            state = BotState(database_path)
            state.initialize()

            connection = state.connect()
            try:
                tables = {
                    row[0]
                    for row in connection.execute(
                        "SELECT name FROM sqlite_master WHERE type='table'"
                    )
                }
            finally:
                connection.close()

            self.assertIn("metadata", tables)
            self.assertIn("submission_records", tables)
            self.assertIn("delivery_cursors", tables)
            self.assertIn("approval_records", tables)

    def test_claim_submission_is_atomic_for_duplicate_fingerprints(self):
        with tempfile.TemporaryDirectory() as directory:
            database_path = Path(directory) / "bot.sqlite3"
            state = BotState(database_path)
            state.initialize()

            first = state.claim_submission("interaction-a", "same-fingerprint")
            second = state.claim_submission("interaction-b", "same-fingerprint")

            self.assertIsNone(first)
            self.assertIsNotNone(second)
            self.assertEqual(second[0], "interaction-a")
            self.assertEqual(second[1], "pending")


if __name__ == "__main__":
    unittest.main()
