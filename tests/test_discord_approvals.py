import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

import aiohttp


BOT_DIR = Path(__file__).resolve().parents[1] / "tools" / "discord-bot"
sys.path.insert(0, str(BOT_DIR))

import bot  # noqa: E402
from approvals import issue_revision_hash
from state import BotState


class TestIssueRevisionHash(unittest.TestCase):
    def test_hash_is_deterministic_for_same_revision(self):
        first = issue_revision_hash("smobcraft/GrindOnly", 21, "Title", "Body")
        second = issue_revision_hash("smobcraft/GrindOnly", 21, "Title", "Body")
        self.assertEqual(first, second)

    def test_hash_changes_when_issue_content_changes(self):
        first = issue_revision_hash("smobcraft/GrindOnly", 21, "Title", "Body")
        changed_title = issue_revision_hash("smobcraft/GrindOnly", 21, "Updated", "Body")
        changed_body = issue_revision_hash("smobcraft/GrindOnly", 21, "Title", "Updated")
        self.assertNotEqual(first, changed_title)
        self.assertNotEqual(first, changed_body)

    def test_hash_binds_repository_and_issue_number(self):
        original = issue_revision_hash("smobcraft/GrindOnly", 21, "Title", "Body")
        other_repo = issue_revision_hash("other/repo", 21, "Title", "Body")
        other_issue = issue_revision_hash("smobcraft/GrindOnly", 22, "Title", "Body")
        self.assertNotEqual(original, other_repo)
        self.assertNotEqual(original, other_issue)


class TestApprovalCommand(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp_directory = tempfile.TemporaryDirectory()
        self.state = BotState(Path(self.temp_directory.name) / "bot.sqlite3")
        self.state.initialize()
        self.state_patcher = patch.object(bot, "STATE", self.state)
        self.state_patcher.start()
        self.addCleanup(self.state_patcher.stop)
        self.addCleanup(self.temp_directory.cleanup)
        self.config_patcher = patch.object(
            bot,
            "CONFIG",
            SimpleNamespace(maintainer_id=9001),
        )
        self.config_patcher.start()
        self.addCleanup(self.config_patcher.stop)

    def interaction(self, user_id=9001, guild_id=None, channel_id=None):
        return SimpleNamespace(
            guild_id=bot.GUILD if guild_id is None else guild_id,
            channel_id=bot.CHANNEL if channel_id is None else channel_id,
            user=SimpleNamespace(id=user_id),
            response=SimpleNamespace(
                send_message=AsyncMock(),
                defer=AsyncMock(),
            ),
            followup=SimpleNamespace(send=AsyncMock()),
        )

    def open_issue(self):
        return {
            "state": "open",
            "title": "A reviewed change",
            "body": "Issue body revision one",
            "html_url": "https://github.example/issues/21",
        }

    async def test_missing_maintainer_id_fails_closed_before_github(self):
        with patch.object(bot, "CONFIG", SimpleNamespace(maintainer_id=None)):
            interaction = self.interaction()
            with patch.object(bot, "github", new=AsyncMock()) as github:
                await bot.approve.callback(interaction, 21)

        github.assert_not_awaited()
        interaction.response.send_message.assert_awaited_once()
        self.assertIn(
            "disabled",
            interaction.response.send_message.await_args.args[0],
        )

    async def test_non_maintainer_id_is_denied(self):
        interaction = self.interaction(user_id=9002)
        with patch.object(bot, "github", new=AsyncMock()) as github:
            await bot.approve.callback(interaction, 21)

        github.assert_not_awaited()
        self.assertIn(
            "Only the configured maintainer",
            interaction.response.send_message.await_args.args[0],
        )

    async def test_wrong_guild_or_channel_is_denied(self):
        for interaction in (
            self.interaction(guild_id=bot.GUILD + 1),
            self.interaction(channel_id=bot.CHANNEL + 1),
        ):
            with self.subTest(
                guild_id=interaction.guild_id,
                channel_id=interaction.channel_id,
            ):
                with patch.object(bot, "github", new=AsyncMock()) as github:
                    await bot.approve.callback(interaction, 21)
                github.assert_not_awaited()
                interaction.response.send_message.assert_awaited_once()

    async def test_closed_issue_is_not_approved_or_labeled(self):
        interaction = self.interaction()
        issue = dict(self.open_issue(), state="closed")
        with patch.object(bot, "github", new=AsyncMock(return_value=issue)) as github:
            await bot.approve.callback(interaction, 21)

        self.assertEqual(github.await_args.args[:2], ("GET", "/issues/21"))
        self.assertEqual(
            self.state.find_approved_revision(
                21,
                issue_revision_hash(
                    bot.REPO, 21, issue["title"], issue["body"]
                ),
            ),
            None,
        )
        interaction.followup.send.assert_awaited_once_with(
            "Only open issues can be approved.",
            ephemeral=True,
        )
        self.assertEqual(len(github.await_args_list), 1)

    async def test_pull_request_is_not_approved(self):
        interaction = self.interaction()
        issue = dict(self.open_issue(), pull_request={"url": "https://github.example/pull/21"})
        with patch.object(bot, "github", new=AsyncMock(return_value=issue)) as github:
            await bot.approve.callback(interaction, 21)

        self.assertEqual(len(github.await_args_list), 1)
        interaction.followup.send.assert_awaited_once_with(
            "Only open issues can be approved.",
            ephemeral=True,
        )

    async def test_non_positive_issue_number_is_rejected(self):
        interaction = self.interaction()
        with patch.object(bot, "github", new=AsyncMock()) as github:
            await bot.approve.callback(interaction, 0)

        github.assert_not_awaited()
        interaction.response.send_message.assert_awaited_once_with(
            "Issue number must be positive.",
            ephemeral=True,
        )

    async def test_approval_records_exact_revision_and_adds_label(self):
        interaction = self.interaction()
        issue = self.open_issue()
        async def github(method, path, **kwargs):
            if method == "GET":
                return issue
            return [{"name": "ai-ready"}]

        with patch.object(bot, "github", new=AsyncMock(side_effect=github)) as github:
            await bot.approve.callback(interaction, 21)

        self.assertEqual(
            github.await_args_list[0].args[:2],
            ("GET", "/issues/21"),
        )
        self.assertEqual(
            github.await_args_list[1].args[:2],
            ("POST", "/issues/21/labels"),
        )
        self.assertEqual(
            github.await_args_list[1].kwargs["json"],
            {"labels": ["ai-ready"]},
        )
        expected_hash = issue_revision_hash(
            bot.REPO, 21, issue["title"], issue["body"]
        )
        approval = self.state.find_approved_revision(21, expected_hash)
        self.assertIsNotNone(approval)
        self.assertEqual(approval[4], "9001")
        self.assertEqual(approval[5], "approved")
        self.assertIn(expected_hash, interaction.followup.send.await_args.args[0])
        self.assertIn(
            "does not authorize automated execution",
            interaction.followup.send.await_args.args[0],
        )

    async def test_label_failure_is_not_treated_as_approval(self):
        interaction = self.interaction()

        async def github(method, path, **kwargs):
            if method == "GET":
                return self.open_issue()
            raise aiohttp.ClientConnectionError()

        with patch.object(bot, "github", new=AsyncMock(side_effect=github)):
            await bot.approve.callback(interaction, 21)

        revision_hash = issue_revision_hash(
            bot.REPO,
            21,
            "A reviewed change",
            "Issue body revision one",
        )
        self.assertIsNone(self.state.find_approved_revision(21, revision_hash))
        interaction.followup.send.assert_awaited_once()
        self.assertIn(
            "Approval is not valid",
            interaction.followup.send.await_args.args[0],
        )


if __name__ == "__main__":
    unittest.main()
