# Validation evidence

Executed locally: `python tools/validate.py` — manifest and all six Lua files passed individual syntax compilation using texluac (Lua 5.3.6). `texlua tests/prediction.lua` — seven assertions passed, covering equal-level XP, gray mobs, elites, rested bonus, worldboss fallback, hourly forecast and missing history. These test the existing formula, not its accuracy in WoW Forever. Lua 5.1/client runtime, UI, migrations, and live dependency behavior are not verified.

Environment limitation for Phase 03B.0: no Lua compiler was found during the 2026-11-25 assessment. Lua and addon validation remain unrelated to Python-only Discord development and were not installed globally. The existing bot virtual environment remains the only authorized Python runtime used for this work.
