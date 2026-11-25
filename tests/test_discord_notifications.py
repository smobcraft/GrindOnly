import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

import aiohttp


BOT_DIR = Path(__file__).resolve().parents[1] / "tools" / "discord-bot"
sys.path.insert(0, str(BOT_DIR))

import bot  # noqa: E402
from notifications import NotificationDeliveryError
from notifications import NotificationPoller
from state import BotState


def issue(number=12, state="open", labels=None, title="Example issue", updated_at=None):
    return {
        "number": number,
        "state": state,
        "state_reason": None,
        "title": title,
        "updated_at": updated_at or datetime.now(timezone.utc).isoformat(),
        "labels": [{"name": name} for name in (labels or [])],
        "html_url": f"https://github.example/issues/{number}",
    }


def release(release_id=7, tag="v1.4.0", prerelease=False):
    return {
        "id": release_id,
        "tag_name": tag,
        "name": f"Release {tag}",
        "published_at": "2026-11-25T12:00:00Z",
        "draft": False,
        "prerelease": prerelease,
    }


class TestNotificationPoller(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp_directory = tempfile.TemporaryDirectory()
        self.state = BotState(Path(self.temp_directory.name) / "bot.sqlite3")
        self.state.initialize()
        self.addCleanup(self.temp_directory.cleanup)
        self.releases = [release(1, "v1.3.19")]
        self.issues = [issue()]
        self.repo_private = False
        self.github = AsyncMock(side_effect=self.fetch_github)
        self.deliver = AsyncMock()
        self.poller = NotificationPoller(
            self.state,
            self.github,
            self.deliver,
            "smobcraft/GrindOnly",
        )

    async def fetch_github(self, method, path, **kwargs):
        if path == "":
            return {"private": self.repo_private}
        if path == "/releases":
            return self.releases
        if path == "/issues":
            return self.issues
        raise AssertionError(f"Unexpected mocked endpoint: {path}")

    async def test_first_poll_baselines_without_historical_notifications(self):
        await self.poller.poll_once()

        self.deliver.assert_not_awaited()
        self.assertEqual(self.state.get_cursor("baseline_releases"), "complete")
        self.assertEqual(self.state.get_cursor("baseline_issues"), "complete")
        self.assertIsNotNone(self.state.get_cursor("issue_updated_at"))

    async def test_private_repository_content_is_not_polled_or_announced(self):
        self.repo_private = True
        await self.poller.poll_once()

        self.assertEqual(self.github.await_args_list[0].args, ("GET", ""))
        self.assertEqual(len(self.github.await_args_list), 1)
        self.deliver.assert_not_awaited()
        self.assertIsNone(self.state.get_cursor("baseline_releases"))
        self.assertIsNone(self.state.get_cursor("baseline_issues"))

    async def test_new_release_and_issue_status_change_are_delivered(self):
        await self.poller.poll_once()
        self.releases.insert(0, release(2, "v1.4.0"))
        changed_issue = issue(
            state="closed",
            labels=["released"],
            updated_at=(datetime.now(timezone.utc) + timedelta(seconds=2)).isoformat(),
        )
        self.issues = [changed_issue]

        await self.poller.poll_once()

        messages = [call.args[0] for call in self.deliver.await_args_list]
        self.assertEqual(len(messages), 2)
        self.assertTrue(any("New Grind Only release" in message for message in messages))
        self.assertTrue(any("Issue status updated #12" in message for message in messages))
        self.assertTrue(all("github.com/smobcraft/GrindOnly" in msg for msg in messages))

        pending = self.state.pending_notifications()
        self.assertEqual(pending, [])

    async def test_initial_baseline_excludes_prereleases(self):
        self.releases = [
            release(1, "v1.3.19"),
            release(2, "v1.4.0-rc1", prerelease=True),
        ]
        await self.poller.poll_once()
        self.releases = [
            release(2, "v1.4.0"),
            release(1, "v1.3.19"),
        ]

        await self.poller.poll_once()

        messages = [call.args[0] for call in self.deliver.await_args_list]
        self.assertEqual(len(messages), 1)
        self.assertIn("v1.4.0", messages[0])

    async def test_title_only_edit_does_not_send_status_notification(self):
        await self.poller.poll_once()
        self.issues = [
            issue(
                title="Updated wording",
                updated_at=(datetime.now(timezone.utc) + timedelta(seconds=3)).isoformat(),
            )
        ]

        await self.poller.poll_once()

        self.deliver.assert_not_awaited()

    async def test_delivery_failure_is_queued_and_retried(self):
        await self.poller.poll_once()
        self.issues = [
            issue(
                state="closed",
                updated_at=(datetime.now(timezone.utc) + timedelta(seconds=4)).isoformat(),
            )
        ]
        self.deliver.side_effect = [TimeoutError(), None]

        await self.poller.poll_once()
        pending = self.state.pending_notifications()
        self.assertEqual(len(pending), 1)
        self.assertEqual(pending[0][3], 1)

        self.issues = []
        await self.poller.poll_once()

        self.assertEqual(self.state.pending_notifications(), [])
        self.assertEqual(self.deliver.await_count, 2)

    async def test_github_failure_does_not_advance_issue_cursor(self):
        await self.poller.poll_once()
        cursor = self.state.get_cursor("issue_updated_at")

        async def fail_issue_fetch(method, path, **kwargs):
            if path == "":
                return {"private": False}
            if path == "/issues":
                raise aiohttp.ClientConnectionError()
            return self.releases

        self.github.side_effect = fail_issue_fetch
        await self.poller.poll_once()

        self.assertEqual(self.state.get_cursor("issue_updated_at"), cursor)

    async def test_fetch_pages_follows_full_pages_until_short_page(self):
        calls = []

        async def paginated_github(method, path, **kwargs):
            calls.append(kwargs["params"]["page"])
            if kwargs["params"]["page"] == 1:
                return [{"id": number} for number in range(100)]
            return [{"id": 101}]

        self.poller.github = paginated_github
        results = await self.poller._fetch_pages("/releases", {})

        self.assertEqual(calls, [1, 2])
        self.assertEqual(len(results), 101)


class TestNotificationDestination(unittest.IsolatedAsyncioTestCase):
    async def test_sends_only_to_configured_guild_without_mentions(self):
        channel = SimpleNamespace(
            guild=SimpleNamespace(id=bot.GUILD),
            send=AsyncMock(),
        )
        with patch.object(
            bot,
            "CONFIG",
            SimpleNamespace(updates_channel_id=None),
        ), patch.object(bot.client, "get_channel", return_value=channel):
            await bot.deliver_notification("release update")

        channel.send.assert_awaited_once()
        allowed_mentions = channel.send.await_args.kwargs["allowed_mentions"]
        self.assertFalse(allowed_mentions.everyone)
        self.assertFalse(allowed_mentions.roles)
        self.assertFalse(allowed_mentions.users)
        self.assertFalse(allowed_mentions.replied_user)

    async def test_rejects_channel_outside_configured_guild(self):
        channel = SimpleNamespace(
            guild=SimpleNamespace(id=bot.GUILD + 1),
            send=AsyncMock(),
        )
        with patch.object(
            bot,
            "CONFIG",
            SimpleNamespace(updates_channel_id=None),
        ), patch.object(bot.client, "get_channel", return_value=channel):
            with self.assertRaises(NotificationDeliveryError):
                await bot.deliver_notification("private details")

        channel.send.assert_not_awaited()


if __name__ == "__main__":
    unittest.main()
