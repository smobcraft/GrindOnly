# Validation evidence

Executed locally: `python tools/validate.py` — manifest and all six Lua files passed individual syntax compilation using texluac (Lua 5.3.6). `texlua tests/prediction.lua` — seven assertions passed, covering equal-level XP, gray mobs, elites, rested bonus, worldboss fallback, hourly forecast and missing history. These test the existing formula, not its accuracy in WoW Forever. Lua 5.1/client runtime, UI, migrations, and live dependency behavior are not verified.

Environment limitation for Phase 03B.0: no Lua compiler was found during the 2026-11-25 assessment. Lua and addon validation remain unrelated to Python-only Discord development and were not installed globally. The existing bot virtual environment remains the only authorized Python runtime used for this work.

Phase 03B.1 automated evidence: the existing bot virtual environment ran `python -m unittest discover -s tests -p "test*.py" -v`; 18 mocked tests passed in 0.115 seconds. This covers the existing Discord callbacks plus configuration validation, secret-safe config representation and SQLite restart persistence. No live Discord or GitHub calls were made.

Phase 03B.2 automated evidence: the existing bot virtual environment ran `python -m unittest discover -s tests -p "test*.py" -v`; 25 mocked tests passed in 0.248 seconds. This covers normalized fingerprints, atomic duplicate claims, exact open-issue reuse, uncertain GitHub failures and retry protection. No live Discord or GitHub calls were made.

Phase 03B.3 automated evidence: the existing bot virtual environment ran `python -m unittest discover -s tests -p "test*.py" -v`; 34 mocked tests passed. This covers exact-ID and guild/channel authorization, missing-ID fail-closed behavior, open-issue checks, deterministic revision hashing, durable approval records and uncertain label failure. No live GitHub writes or approvals were made.

Phase 03B.4 automated evidence: the existing bot virtual environment ran `python -m unittest discover -s tests -p "test*.py" -v`; 46 mocked tests passed in 0.902 seconds. This covers public-repository gating, quiet first-run baselines, stable-release and issue-status notifications, pagination, cursor preservation on API failure, retryable outbox delivery, and channel guild/mention restrictions. No live GitHub or Discord operations were performed.

Phase 03B.5–03B.7 final automated evidence: `C:\grindonly\tools\discord-bot\.venv\Scripts\python.exe -m unittest discover -s tests -p "test*.py" -v` — 65 mocked tests passed in 1.137 seconds. Coverage includes attachment allowlisting and preview/confirmation, end-to-end issue creation and later notification, authorization, duplicate handling, approval integrity, SQLite persistence, notification retries/backoff, log redaction/rotation, single-instance locking, health output, and graceful shutdown. No live Discord interaction, GitHub write, approval, or notification was performed.

Required addon validation attempted: `C:\grindonly\tools\discord-bot\.venv\Scripts\python.exe tools\validate.py` — blocked with `Install Lua compiler (luac) before validation` (exit code 1). `texlua tests\prediction.lua` — not run because `texlua` is unavailable in this environment (PowerShell command-not-found, exit code 1). Lua was not installed globally.

In-game verification gap: no live WoW Forever client was available; image preview/issue behavior has only been validated with mocked Discord/GitHub services. The bot must be restarted before the updated context-menu command and `/health` command become available.

Public visibility: after explicit maintainer approval, GitHub settings were used to make the repository public; the settings page confirmed the public state. GitHub warned that Actions history/logs become visible and push rulesets are disabled on public conversion. The settings review showed no branch-protection rule or repository ruleset configured for `master`. No workflow, branch rule, or automation setting was changed. No addon release, live Discord bot operation, or GitHub issue write was performed.
