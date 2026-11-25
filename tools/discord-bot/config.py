from dataclasses import dataclass, field
import os
from pathlib import Path
from typing import Mapping, Optional


BOT_DIR = Path(__file__).resolve().parent
DEFAULT_DATABASE_PATH = BOT_DIR / "data" / "grindonly-bot.sqlite3"


def _required_text(environ: Mapping[str, str], name: str) -> str:
    value = environ.get(name, "").strip()
    if not value:
        raise ValueError(f"{name} is required")
    return value


def _optional_positive_id(environ: Mapping[str, str], name: str) -> Optional[int]:
    value = environ.get(name, "").strip()
    if not value:
        return None
    if not value.isdigit():
        raise ValueError(f"{name} must contain an exact positive Discord user/channel ID")
    result = int(value)
    if result <= 0:
        raise ValueError(f"{name} must contain an exact positive Discord user/channel ID")
    return result


@dataclass(frozen=True)
class BotConfig:
    discord_token: str = field(repr=False)
    github_token: str = field(repr=False)
    guild_id: int
    feedback_channel_id: int
    updates_channel_id: Optional[int]
    maintainer_id: Optional[int]
    poll_interval_seconds: int
    database_path: Path


def load_config(environ: Mapping[str, str] = os.environ) -> BotConfig:
    discord_token = _required_text(environ, "DISCORD_TOKEN")
    github_token = _required_text(environ, "GITHUB_TOKEN")

    guild_id = _optional_positive_id(environ, "DISCORD_GUILD_ID")
    feedback_channel_id = _optional_positive_id(environ, "DISCORD_FEEDBACK_CHANNEL_ID")
    if guild_id is None:
        raise ValueError("DISCORD_GUILD_ID is required")
    if feedback_channel_id is None:
        raise ValueError("DISCORD_FEEDBACK_CHANNEL_ID is required")

    updates_channel_id = _optional_positive_id(environ, "DISCORD_UPDATES_CHANNEL_ID")
    maintainer_id = _optional_positive_id(environ, "DISCORD_MAINTAINER_ID")

    poll_text = environ.get("POLL_INTERVAL_SECONDS", "300").strip()
    if not poll_text.isdigit():
        raise ValueError("POLL_INTERVAL_SECONDS must be a positive integer")
    poll_interval_seconds = int(poll_text)
    if poll_interval_seconds <= 0:
        raise ValueError("POLL_INTERVAL_SECONDS must be a positive integer")

    database_text = environ.get("BOT_DATABASE_PATH", "").strip()
    database_path = Path(database_text).expanduser() if database_text else DEFAULT_DATABASE_PATH

    return BotConfig(
        discord_token=discord_token,
        github_token=github_token,
        guild_id=guild_id,
        feedback_channel_id=feedback_channel_id,
        updates_channel_id=updates_channel_id,
        maintainer_id=maintainer_id,
        poll_interval_seconds=poll_interval_seconds,
        database_path=database_path,
    )
