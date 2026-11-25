import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch


BOT_DIR = Path(__file__).resolve().parents[1] / "tools" / "discord-bot"
sys.path.insert(0, str(BOT_DIR))

import bot  # noqa: E402
from notifications import NotificationPoller
from state import BotState


class TestDiscordFeedbackLifecycle(unittest.IsolatedAsyncioTestCase):
    async def test_context_feedback_creates_issue_and_later_notifies(self):
        with tempfile.TemporaryDirectory() as directory:
            state = BotState(Path(directory) / "bot.sqlite3")
            state.initialize()
            issues = []
            delivered = []

            async def github(method, path, **kwargs):
                if method == "GET" and path == "":
                    return {"private": False}
                if method == "GET" and path == "/search/issues":
                    return {"items": []}
                if method == "GET" and path == "/releases":
                    return []
                if method == "GET" and path == "/issues":
                    return list(issues)
                if method == "POST" and path == "/issues":
                    payload = kwargs["json"]
                    issue = {
                        "number": 123,
                        "title": payload["title"],
                        "body": payload["body"],
                        "html_url": "https://github.example/issues/123",
                        "state": "open",
                        "labels": [],
                        "updated_at": datetime.now(timezone.utc).isoformat(),
                    }
                    issues.append(issue)
                    return issue
                raise AssertionError(f"Unexpected mocked GitHub request: {method} {path}")

            async def deliver(message):
                delivered.append(message)

            poller = NotificationPoller(state, github, deliver, bot.REPO)
            self.assertTrue(await poller.poll_once())
            self.assertEqual(delivered, [])

            message = SimpleNamespace(
                guild_id=bot.GUILD,
                channel=SimpleNamespace(id=bot.CHANNEL),
                author=SimpleNamespace(id=202),
                content="The dashboard freezes when I open history.",
                attachments=[
                    SimpleNamespace(
                        content_type="image/png",
                        url="https://cdn.discordapp.com/attachments/1/2/freeze.png",
                    )
                ],
            )
            preview_interaction = SimpleNamespace(
                guild_id=bot.GUILD,
                channel_id=bot.CHANNEL,
                user=SimpleNamespace(id=202),
                response=SimpleNamespace(
                    send_message=AsyncMock(),
                    send_modal=AsyncMock(),
                ),
            )

            with patch.object(bot, "STATE", state):
                await bot.submit_own_message.callback(
                    preview_interaction,
                    message,
                )
                modal = preview_interaction.response.send_modal.await_args.args[0]
                modal.subject = SimpleNamespace(value="History dashboard freezes")
                submit_interaction = SimpleNamespace(
                    id="e2e-feedback",
                    guild_id=bot.GUILD,
                    channel_id=bot.CHANNEL,
                    response=SimpleNamespace(defer=AsyncMock()),
                    followup=SimpleNamespace(send=AsyncMock()),
                )
                with patch.object(bot, "github", new=AsyncMock(side_effect=github)):
                    await modal.on_submit(submit_interaction)

            self.assertEqual(len(issues), 1)
            self.assertIn("Discord image 1", issues[0]["body"])
            self.assertEqual(state.get_submission("e2e-feedback")[1], "submitted")

            self.assertTrue(await poller.poll_once())
            self.assertEqual(len(delivered), 1)
            self.assertIn("New issue #123", delivered[0])
            self.assertEqual(state.pending_notification_count(), 0)
            self.assertEqual(poller.last_poll_status, "ok")


if __name__ == "__main__":
    unittest.main()
