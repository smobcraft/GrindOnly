import os
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

import aiohttp


BOT_DIR = Path(__file__).resolve().parents[1] / "tools" / "discord-bot"
sys.path.insert(0, str(BOT_DIR))
import bot  # noqa: E402


class TestBotConfiguration(unittest.TestCase):
    def test_configured_guild_channel_and_repository(self):
        self.assertIsInstance(bot.GUILD, int)
        self.assertGreater(bot.GUILD, 0)
        self.assertIsInstance(bot.CHANNEL, int)
        self.assertGreater(bot.CHANNEL, 0)
        self.assertEqual(bot.REPO, "smobcraft/GrindOnly")

    def test_example_configuration_contains_only_non_secret_keys(self):
        example = (BOT_DIR / ".env.example").read_text(encoding="utf-8")
        for key in (
            "DISCORD_TOKEN",
            "GITHUB_TOKEN",
            "DISCORD_GUILD_ID",
            "DISCORD_FEEDBACK_CHANNEL_ID",
        ):
            self.assertIn(key + "=", example)
        for line in example.splitlines():
            if line.startswith(("DISCORD_TOKEN=", "GITHUB_TOKEN=")):
                self.assertEqual(line, line.split("=", 1)[0] + "=")


class TestAuthorization(unittest.IsolatedAsyncioTestCase):
    async def test_restricted_tree_accepts_correct_guild_and_channel(self):
        interaction = SimpleNamespace(
            guild_id=bot.GUILD,
            channel_id=bot.CHANNEL,
            response=SimpleNamespace(send_message=AsyncMock()),
        )
        allowed = await bot.tree.interaction_check(interaction)
        self.assertTrue(allowed)
        interaction.response.send_message.assert_not_awaited()

    async def test_restricted_tree_rejects_wrong_guild(self):
        interaction = SimpleNamespace(
            guild_id=bot.GUILD + 1,
            channel_id=bot.CHANNEL,
            response=SimpleNamespace(send_message=AsyncMock()),
        )
        allowed = await bot.tree.interaction_check(interaction)
        self.assertFalse(allowed)
        interaction.response.send_message.assert_awaited_once()

    async def test_restricted_tree_rejects_wrong_channel(self):
        interaction = SimpleNamespace(
            guild_id=bot.GUILD,
            channel_id=bot.CHANNEL + 1,
            response=SimpleNamespace(send_message=AsyncMock()),
        )
        allowed = await bot.tree.interaction_check(interaction)
        self.assertFalse(allowed)
        interaction.response.send_message.assert_awaited_once()

    async def test_modal_rejects_wrong_channel_even_after_submission(self):
        modal = bot.Feedback("Bug")
        interaction = SimpleNamespace(
            guild_id=bot.GUILD,
            channel_id=bot.CHANNEL + 1,
            response=SimpleNamespace(send_message=AsyncMock()),
        )
        await modal.on_submit(interaction)
        interaction.response.send_message.assert_awaited_once_with(
            "Wrong channel.", ephemeral=True
        )


class TestIssueCreation(unittest.IsolatedAsyncioTestCase):
    async def test_modal_creates_issue_with_feedback_fields(self):
        modal = bot.Feedback("Suggestion")
        modal.subject = SimpleNamespace(value="Improve testing")
        modal.details = SimpleNamespace(value="Add another test")
        modal.version = SimpleNamespace(value="1.3.19")

        interaction = SimpleNamespace(
            id="interaction-123",
            guild_id=bot.GUILD,
            channel_id=bot.CHANNEL,
            response=SimpleNamespace(defer=AsyncMock()),
            followup=SimpleNamespace(send=AsyncMock()),
        )

        issue = {
            "number": 42,
            "html_url": "https://github.example/issues/42",
        }
        with patch.object(bot, "github", new=AsyncMock(return_value=issue)) as github:
            await modal.on_submit(interaction)

        github.assert_awaited_once()
        method, path = github.await_args.args[:2]
        payload = github.await_args.kwargs["json"]
        self.assertEqual(method, "POST")
        self.assertEqual(path, "/issues")
        self.assertEqual(payload["title"], "[Suggestion] Improve testing")
        self.assertIn("1.3.19", payload["body"])
        self.assertIn("Add another test", payload["body"])
        self.assertIn("interaction-123", payload["body"])
        interaction.followup.send.assert_awaited_once()

    async def test_modal_discloses_uncertain_github_failure(self):
        modal = bot.Feedback("Bug")
        modal.subject = SimpleNamespace(value="Test failure")
        modal.details = SimpleNamespace(value="No private details")
        modal.version = SimpleNamespace(value="")

        interaction = SimpleNamespace(
            id="interaction-456",
            guild_id=bot.GUILD,
            channel_id=bot.CHANNEL,
            response=SimpleNamespace(defer=AsyncMock()),
            followup=SimpleNamespace(send=AsyncMock()),
        )

        with patch.object(
            bot,
            "github",
            new=AsyncMock(side_effect=aiohttp.ClientConnectionError()),
        ):
            await modal.on_submit(interaction)

        interaction.followup.send.assert_awaited_once()
        message = interaction.followup.send.await_args.args[0]
        self.assertIn("could not be confirmed", message)
        self.assertIn("Check existing issues", message)


class TestIssueStatus(unittest.IsolatedAsyncioTestCase):
    async def test_status_lookup_reports_issue_state(self):
        interaction = SimpleNamespace(
            response=SimpleNamespace(defer=AsyncMock()),
            followup=SimpleNamespace(send=AsyncMock()),
        )
        issue = {
            "state": "open",
            "html_url": "https://github.example/issues/42",
        }
        with patch.object(bot, "github", new=AsyncMock(return_value=issue)):
            await bot.status.callback(interaction, 42)

        interaction.followup.send.assert_awaited_once()
        message = interaction.followup.send.await_args.args[0]
        self.assertIn("#42: open", message)
        self.assertIn("https://github.example/issues/42", message)

    async def test_status_lookup_handles_github_error(self):
        interaction = SimpleNamespace(
            response=SimpleNamespace(defer=AsyncMock()),
            followup=SimpleNamespace(send=AsyncMock()),
        )
        with patch.object(
            bot,
            "github",
            new=AsyncMock(side_effect=TimeoutError()),
        ):
            await bot.status.callback(interaction, 42)

        interaction.followup.send.assert_awaited_once_with(
            "Unable to retrieve issue.",
            ephemeral=True,
        )


if __name__ == "__main__":
    unittest.main()
