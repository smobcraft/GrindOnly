import os
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
from state import BotState


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
    def setUp(self):
        self.temp_directory = tempfile.TemporaryDirectory()
        self.state = BotState(Path(self.temp_directory.name) / "bot.sqlite3")
        self.state.initialize()
        self.state_patcher = patch.object(bot, "STATE", self.state)
        self.state_patcher.start()
        self.addCleanup(self.state_patcher.stop)
        self.addCleanup(self.temp_directory.cleanup)

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
        async def github(method, path, **kwargs):
            if method == "GET":
                return {"items": []}
            return issue

        with patch.object(bot, "github", new=AsyncMock(side_effect=github)) as github:
            await modal.on_submit(interaction)

        github.assert_awaited()
        post_call = next(call for call in github.await_args_list if call.args[:2] == ("POST", "/issues"))
        payload = post_call.kwargs["json"]
        self.assertEqual(payload["title"], "[Suggestion] Improve testing")
        self.assertIn("1.3.19", payload["body"])
        self.assertIn("Add another test", payload["body"])
        self.assertIn("interaction-123", payload["body"])
        interaction.followup.send.assert_awaited_once()

    async def test_repeated_submission_reuses_existing_issue(self):
        modal = bot.Feedback("Suggestion")
        modal.subject = SimpleNamespace(value="Improve testing")
        modal.details = SimpleNamespace(value="Add another test")
        modal.version = SimpleNamespace(value="1.3.19")

        first = SimpleNamespace(
            id="interaction-123",
            guild_id=bot.GUILD,
            channel_id=bot.CHANNEL,
            response=SimpleNamespace(defer=AsyncMock()),
            followup=SimpleNamespace(send=AsyncMock()),
        )
        second = SimpleNamespace(
            id="interaction-456",
            guild_id=bot.GUILD,
            channel_id=bot.CHANNEL,
            response=SimpleNamespace(defer=AsyncMock()),
            followup=SimpleNamespace(send=AsyncMock()),
        )

        issue = {
            "number": 42,
            "html_url": "https://github.example/issues/42",
        }

        async def github(method, path, **kwargs):
            if method == "GET":
                return {"items": []}
            return issue

        with patch.object(bot, "github", new=AsyncMock(side_effect=github)) as github:
            await modal.on_submit(first)
            await modal.on_submit(second)

        post_calls = [
            call for call in github.await_args_list
            if call.args[:2] == ("POST", "/issues")
        ]
        self.assertEqual(len(post_calls), 1)
        self.assertIn("Submitted issue #42", second.followup.send.await_args.args[0])

    async def test_exact_open_issue_title_prevents_duplicate_creation(self):
        modal = bot.Feedback("Bug")
        modal.subject = SimpleNamespace(value="Broken map")
        modal.details = SimpleNamespace(value="Pins overlap")
        modal.version = SimpleNamespace(value="")
        interaction = SimpleNamespace(
            id="interaction-open",
            guild_id=bot.GUILD,
            channel_id=bot.CHANNEL,
            response=SimpleNamespace(defer=AsyncMock()),
            followup=SimpleNamespace(send=AsyncMock()),
        )

        async def github(method, path, **kwargs):
            if method == "GET":
                return {
                    "items": [{
                        "number": 77,
                        "title": "[Bug] broken map",
                        "html_url": "https://github.example/issues/77",
                    }]
                }
            raise AssertionError("A duplicate issue must not be posted")

        with patch.object(bot, "github", new=AsyncMock(side_effect=github)) as github:
            await modal.on_submit(interaction)

        post_calls = [
            call for call in github.await_args_list
            if call.args[:2] == ("POST", "/issues")
        ]
        self.assertEqual(post_calls, [])
        self.assertIn("Matching open issue #77", interaction.followup.send.await_args.args[0])

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

    async def test_context_preview_posts_user_edited_text(self):
        modal = bot.ContextFeedback("Original message title\nOriginal message body")
        modal.subject = SimpleNamespace(value="Edited public title")
        modal.details = SimpleNamespace(value="Edited public details")
        modal.version = SimpleNamespace(value="1.3.19")
        interaction = SimpleNamespace(
            id="interaction-context",
            guild_id=bot.GUILD,
            channel_id=bot.CHANNEL,
            response=SimpleNamespace(defer=AsyncMock()),
            followup=SimpleNamespace(send=AsyncMock()),
        )
        async def github(method, path, **kwargs):
            if method == "GET":
                return {"items": []}
            return {
                "number": 84,
                "html_url": "https://github.example/issues/84",
            }

        with patch.object(bot, "github", new=AsyncMock(side_effect=github)) as github:
            await modal.on_submit(interaction)

        post_call = next(
            call for call in github.await_args_list
            if call.args[:2] == ("POST", "/issues")
        )
        self.assertEqual(
            post_call.kwargs["json"]["title"],
            "[Feedback] Edited public title",
        )
        self.assertIn("Edited public details", post_call.kwargs["json"]["body"])
        self.assertNotIn("Original message body", post_call.kwargs["json"]["body"])


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


class TestMessageContextMenu(unittest.IsolatedAsyncioTestCase):
    def make_interaction(self, user_id=202, guild_id=None, channel_id=None):
        return SimpleNamespace(
            guild_id=bot.GUILD if guild_id is None else guild_id,
            channel_id=bot.CHANNEL if channel_id is None else channel_id,
            user=SimpleNamespace(id=user_id),
            response=SimpleNamespace(
                send_message=AsyncMock(),
                send_modal=AsyncMock(),
            ),
        )

    def make_message(self, author_id=202, channel_id=None, content="Please review this"):
        source_channel_id = bot.CHANNEL if channel_id is None else channel_id
        return SimpleNamespace(
            guild_id=bot.GUILD,
            channel=SimpleNamespace(id=source_channel_id),
            author=SimpleNamespace(id=author_id),
            content=content,
            attachments=[],
        )

    async def test_own_message_opens_editable_public_preview(self):
        interaction = self.make_interaction()
        message = self.make_message(
            content="Original title\nOriginal details"
        )

        await bot.submit_own_message.callback(interaction, message)

        interaction.response.send_modal.assert_awaited_once()
        modal = interaction.response.send_modal.await_args.args[0]
        self.assertIsInstance(modal, bot.ContextFeedback)
        self.assertEqual(modal.subject.default, "Original title")
        self.assertEqual(modal.details.default, "Original title\nOriginal details")

    async def test_message_from_another_author_is_rejected(self):
        interaction = self.make_interaction(user_id=202)
        message = self.make_message(author_id=303)

        await bot.submit_own_message.callback(interaction, message)

        interaction.response.send_modal.assert_not_awaited()
        interaction.response.send_message.assert_awaited_once_with(
            "You can only submit your own message.",
            ephemeral=True,
        )

    async def test_message_from_another_channel_is_rejected(self):
        interaction = self.make_interaction()
        message = self.make_message(channel_id=bot.CHANNEL + 1)

        await bot.submit_own_message.callback(interaction, message)

        interaction.response.send_modal.assert_not_awaited()
        interaction.response.send_message.assert_awaited_once()

    async def test_context_menu_in_another_guild_is_rejected(self):
        interaction = self.make_interaction(guild_id=bot.GUILD + 1)
        message = self.make_message()

        await bot.submit_own_message.callback(interaction, message)

        interaction.response.send_modal.assert_not_awaited()
        interaction.response.send_message.assert_awaited_once_with(
            "Use the Grind Only feedback channel.",
            ephemeral=True,
        )

    async def test_empty_text_without_supported_image_is_rejected(self):
        interaction = self.make_interaction()
        message = self.make_message(content="")
        message.attachments = [
            SimpleNamespace(
                filename="notes.txt",
                content_type="text/plain",
                url="https://cdn.discordapp.com/attachments/1/2/notes.txt",
            )
        ]

        await bot.submit_own_message.callback(interaction, message)

        interaction.response.send_modal.assert_not_awaited()
        response = interaction.response.send_message.await_args.args[0]
        self.assertIn("no text or supported image", response)
        self.assertIn("other files are not included", response)

    async def test_image_attachment_is_visible_in_editable_public_preview(self):
        interaction = self.make_interaction()
        image_url = (
            "https://cdn.discordapp.com/attachments/1/2/screenshot.png"
            "?ex=fixture&is=fixture&hm=fixture"
        )
        message = self.make_message(content="The minimap is covered")
        message.attachments = [
            SimpleNamespace(
                filename="screenshot.png",
                content_type="image/png",
                url=image_url,
            )
        ]

        await bot.submit_own_message.callback(interaction, message)

        interaction.response.send_modal.assert_awaited_once()
        modal = interaction.response.send_modal.await_args.args[0]
        self.assertIn("The minimap is covered", modal.details.default)
        self.assertIn("Discord-hosted images (links may expire", modal.details.default)
        self.assertIn(f"![Discord image 1](<{image_url}>)", modal.details.default)

    async def test_image_link_is_included_in_issue_after_modal_confirmation(self):
        message = self.make_message(content="The dashboard is blocked")
        image_url = "https://cdn.discordapp.com/attachments/1/2/error.png"
        message.attachments = [
            SimpleNamespace(content_type="image/png", url=image_url)
        ]
        preview_interaction = self.make_interaction()
        await bot.submit_own_message.callback(preview_interaction, message)
        modal = preview_interaction.response.send_modal.await_args.args[0]
        modal.subject = SimpleNamespace(value="Dashboard is blocked")
        modal.version = SimpleNamespace(value="")
        submit_interaction = SimpleNamespace(
            id="interaction-image",
            guild_id=bot.GUILD,
            channel_id=bot.CHANNEL,
            response=SimpleNamespace(defer=AsyncMock()),
            followup=SimpleNamespace(send=AsyncMock()),
        )

        async def github(method, path, **kwargs):
            if method == "GET":
                return {"items": []}
            return {
                "number": 98,
                "html_url": "https://github.example/issues/98",
            }

        with tempfile.TemporaryDirectory() as directory:
            state = BotState(Path(directory) / "bot.sqlite3")
            state.initialize()
            with patch.object(bot, "STATE", state), patch.object(
                bot,
                "github",
                new=AsyncMock(side_effect=github),
            ) as github:
                await modal.on_submit(submit_interaction)

            post_call = next(
                call for call in github.await_args_list
                if call.args[:2] == ("POST", "/issues")
            )
        body = post_call.kwargs["json"]["body"]
        self.assertIn(f"![Discord image 1](<{image_url}>)", body)

    async def test_non_discord_image_url_is_rejected(self):
        interaction = self.make_interaction()
        message = self.make_message(content="Please inspect this image")
        message.attachments = [
            SimpleNamespace(
                content_type="image/png",
                url="https://example.com/image.png",
            )
        ]

        await bot.submit_own_message.callback(interaction, message)

        interaction.response.send_modal.assert_not_awaited()
        self.assertIn(
            "could not be validated",
            interaction.response.send_message.await_args.args[0],
        )

    async def test_long_image_links_cannot_overflow_preview_limit(self):
        image_url = "https://cdn.discordapp.com/attachments/1/2/image.png"
        image_only_preview, _, _ = bot.context_details("", [image_url])
        extra_length = bot.CONTEXT_DETAILS_MAX_LENGTH - len(image_only_preview)
        image_url += "?" + ("x" * (extra_length - 1))

        with self.assertRaises(ValueError):
            bot.context_details("Caption", [image_url])

    async def test_long_context_text_is_visibly_marked_as_truncated(self):
        long_text = ("Long title " * 12) + "\n" + ("details " * 300)
        modal = bot.ContextFeedback(long_text)

        self.assertEqual(len(modal.subject.default), 100)
        self.assertEqual(len(modal.details.default), 1800)
        self.assertTrue(modal.details.default.endswith("[truncated]"))


if __name__ == "__main__":
    unittest.main()
