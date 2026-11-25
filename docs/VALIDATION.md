# Validation evidence

Executed locally: `python tools/validate.py` — manifest and all six Lua files passed individual syntax compilation using texluac (Lua 5.3.6). `texlua tests/prediction.lua` — seven assertions passed, covering equal-level XP, gray mobs, elites, rested bonus, worldboss fallback, hourly forecast and missing history. These test the existing formula, not its accuracy in WoW Forever. Lua 5.1/client runtime, UI, migrations, and live dependency behavior are not verified.
