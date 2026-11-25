# Discord feedback bot
Use Python 3.11+ on Windows. In PowerShell from this directory:

```powershell
py -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
Copy-Item .env.example .env
notepad .env
.\.venv\Scripts\python.exe bot.py
```
Set DISCORD_TOKEN to the bot token and GITHUB_TOKEN to a fine-grained token restricted to smobcraft/GrindOnly with Issues read/write and Metadata read. Never commit .env. Install the Discord app with bot and applications.commands scopes. Grant channel access. No privileged intents required. Commands are guild-scoped and checked against the configured channel. Try /help, /latest, then /suggest with a test request. Keep the terminal open. Feedback is public and untrusted; no automatic coding or approval occurs. Release announcements, deduplication, attachments, context menu and status notifications are future work. The bot does not yet post announcements.
