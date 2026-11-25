# Discord feedback bot

The bot is a maintainer-operated tool for collecting public GitHub issues. It does not run code or create pull requests automatically. Autonomous issue-to-PR work is deferred to a later phase.

## Run the bot

Use the already-created virtual environment from PowerShell in this directory:

```powershell
.\.venv\Scripts\python.exe bot.py
```

Or run `start-bot.cmd`. The launcher uses the existing virtual environment, keeps the process in the bot directory, and does not register a Windows startup task. Do not create a new environment or install global dependencies for routine operation.

The local `.env` must define `DISCORD_TOKEN`, `GITHUB_TOKEN`, `DISCORD_GUILD_ID`, and `DISCORD_FEEDBACK_CHANNEL_ID`. Use a fine-grained GitHub token restricted to `smobcraft/GrindOnly`, with only the permissions needed by the enabled commands. Never commit `.env` or share credential values. The bot needs the Discord `bot` and `applications.commands` scopes; privileged intents are not required. Commands are guild-scoped and restricted to the configured feedback channel.

## Feedback and privacy

Commands include `/bug`, `/suggest`, `/feedback`, `/latest`, `/status`, `/health`, and `/help`. A user can also right-click their own message in the configured channel and select **Submit my message as feedback**. The resulting modal is an editable public-issue preview; nothing is sent to GitHub until the user confirms.

The context menu includes PNG, JPEG, GIF, and WebP image attachments as Markdown image links to Discord's CDN. These links are not copied to durable storage and may expire or stop working. Other attachment types are excluded. The issue is public, so submit only information and images that are safe to publish. The text/image preview is editable before submission.

Issue text and attachments are untrusted input. The maintainer reviews issues manually. `/approve` records exact-ID maintainer approval for an issue revision and applies the `ai-ready` label, but does not start automated development or authorize an agent to create a PR. Any future Phase 04 worker must independently verify approval provenance and issue-content integrity.

The bot stores submission deduplication, approvals, polling cursors, and notification state in a local SQLite database. The default is `data/grindonly-bot.sqlite3`; set `BOT_DATABASE_PATH` to override it. Keep the database local and back it up according to the maintainer's policy. Rotating logs are stored under `logs/`; configured credentials are redacted. Do not share logs or database files publicly.

GitHub release and issue notifications are polled every `POLL_INTERVAL_SECONDS` (default 300) only after the GitHub API confirms that the repository is public. The initial poll is a silent baseline. Notifications are sent to `DISCORD_UPDATES_CHANNEL_ID` or the feedback channel fallback, and are limited to channels in the configured server. Delivery is at-least-once, so a process interruption can result in a duplicate message.
