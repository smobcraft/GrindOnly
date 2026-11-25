import asyncio
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch
import logging

import aiohttp
import discord

BOT_DIR = Path(__file__).resolve().parents[1] / "tools" / "discord-bot"
sys.path.insert(0, str(BOT_DIR))

import bot  # noqa: E402
from instance_lock import AlreadyRunningError, InstanceLock
from logging_setup import SecretRedactingFormatter


class TestSingleInstance(unittest.TestCase):
    def test_second_process_lock_is_rejected_until_first_releases(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bot.lock"
            first = InstanceLock(path)
            second = InstanceLock(path)
            first.acquire()
            try:
                with self.assertRaises(AlreadyRunningError):
                    second.acquire()
            finally:
                first.release()

            second.acquire()
            second.release()


class TestLogRedaction(unittest.TestCase):
    def test_configured_secrets_are_redacted_from_log_output(self):
        formatter = SecretRedactingFormatter("%(message)s", ("test-discord-secret",))
        record = logging.LogRecord(
            "test",
            logging.INFO,
            __file__,
            1,
            "startup value=%s",
            ("test-discord-secret",),
            None,
        )

        self.assertEqual(formatter.format(record), "startup value=[REDACTED]")

    def test_logging_uses_daily_rotation_and_seven_backups(self):
        root_logger = logging.getLogger()
        original_level = root_logger.level
        original_handlers = list(root_logger.handlers)
        discord_logger = logging.getLogger("discord")
        original_discord_level = discord_logger.level
        with tempfile.TemporaryDirectory() as directory:
            handlers = bot.configure_logging(Path(directory), ("fixture-secret",))
            file_handler, console_handler = handlers
            try:
                self.assertEqual(file_handler.when, "MIDNIGHT")
                self.assertEqual(file_handler.backupCount, 7)
                self.assertTrue(Path(file_handler.baseFilename).is_file())
            finally:
                for handler in handlers:
                    root_logger.removeHandler(handler)
                    handler.close()
                root_logger.setLevel(original_level)
                discord_logger.setLevel(original_discord_level)
                for handler in list(root_logger.handlers):
                    if handler not in original_handlers:
                        root_logger.removeHandler(handler)


class TestPollBackoff(unittest.IsolatedAsyncioTestCase):
    def test_backoff_is_exponential_and_capped(self):
        poller = bot.NOTIFICATION_POLLER

        with patch.object(poller, "consecutive_failures", 0):
            self.assertEqual(poller.backoff_seconds(300), 300)
        with patch.object(poller, "consecutive_failures", 1):
            self.assertEqual(poller.backoff_seconds(300), 600)
        with patch.object(poller, "consecutive_failures", 20):
            self.assertEqual(poller.backoff_seconds(300), 3600)

    async def test_poll_failure_marks_degraded_and_increases_backoff(self):
        async def github(*_args, **_kwargs):
            raise aiohttp.ClientConnectionError()

        poller = bot.NOTIFICATION_POLLER.__class__(
            state=None,
            github=github,
            deliver=AsyncMock(),
            repository="smobcraft/GrindOnly",
        )

        healthy = await poller.poll_once()

        self.assertFalse(healthy)
        self.assertEqual(poller.last_poll_status, "degraded")
        self.assertEqual(poller.consecutive_failures, 1)
        self.assertEqual(poller.backoff_seconds(300), 600)


class TestHealthCommand(unittest.IsolatedAsyncioTestCase):
    async def test_health_is_ephemeral_and_omits_credentials(self):
        interaction = SimpleNamespace(
            response=SimpleNamespace(send_message=AsyncMock()),
        )
        with patch.object(bot.STATE, "pending_notification_count", return_value=2), \
             patch.object(bot.NOTIFICATION_POLLER, "last_poll_at", "2026-11-25T12:00:00Z"), \
             patch.object(bot.NOTIFICATION_POLLER, "last_poll_status", "ok"), \
             patch.object(
                 bot,
                 "CONFIG",
                 SimpleNamespace(
                     discord_token="fixture-discord-secret",
                     github_token="fixture-github-secret",
                 ),
             ):
            await bot.health.callback(interaction)

        interaction.response.send_message.assert_awaited_once()
        message = interaction.response.send_message.await_args.args[0]
        self.assertIn("Bot online", message)
        self.assertIn("Pending Discord notifications: 2", message)
        self.assertNotIn("fixture-discord-secret", message)
        self.assertNotIn("fixture-github-secret", message)
        self.assertTrue(interaction.response.send_message.await_args.kwargs["ephemeral"])


class TestGracefulShutdown(unittest.IsolatedAsyncioTestCase):
    async def test_close_cancels_and_awaits_poll_before_closing_client(self):
        stopped = asyncio.Event()

        async def poll_forever():
            try:
                await stopped.wait()
            finally:
                stopped.set()

        poll_task = asyncio.create_task(poll_forever())
        loop = SimpleNamespace(
            get_task=lambda: poll_task,
            is_running=lambda: True,
            cancel=poll_task.cancel,
        )
        client = bot.Client(intents=discord.Intents.none())
        with patch.object(bot, "notification_poll", loop), patch.object(
            discord.Client,
            "close",
            new_callable=AsyncMock,
        ) as close_client:
            await client.close()

        self.assertTrue(poll_task.cancelled())
        close_client.assert_awaited_once()


if __name__ == "__main__":
    unittest.main()
