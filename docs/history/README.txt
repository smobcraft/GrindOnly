GRIND ONLY v0.6.0 (EXPERIMENTAL)

Install: close WoW, replace Interface/AddOns/GrindOnly, restart.
Keep your existing WTF/Account/.../SavedVariables/GrindOnly.lua file.
Commands: /wgf, /wgf stats, /wgf debug, /wgf reset.

Analytics tabs:
Overview: existing session totals and recent session chart.
Mobs: observed mob kills and vendor value; click for drops and approximate timing.
Loot: all collected item totals, click for observed mob sources.
Zones: zone/subzone gold/hour based on new per-location collection.
Trends: day/week/month earnings graphs (new data from v0.6 onward).
Notable: highest unit vendor value or least frequent recorded item.
Combat: target-based approximate fight duration and between-kill gaps.

Important limitations:
- WoW Forever blocked COMBAT_LOG_EVENT_UNFILTERED registration in prior builds.
  This version does not register it. Kills are observed only when the target
  remains selected from alive through death. Timings include target idle time.
- Loot-to-mob attribution is conservative and may be incomplete.
- Item frequency is items per observed kill, NOT an exact drop probability.
- Historical v0.5.x data is retained; new daily/zone/time buckets cannot be
  backfilled accurately from previous records.
- Data is saved in GrindOnlyDB SavedVariables on logout/reload.
- Gold/hour includes idle time and reflects vendor values, not AH prices.

Please test login without protected-action popup, then tabs, clicks, zone
changes, and a few kills. In-game Lua runtime not available for this build.

v0.6.1 item interactions:
- Hover an item row in Loot, Notable, or a mob's Attributed Drops list to see its native tooltip.
- Click item rows to open their existing analytics details.
- Shift-click an item row while chat input is open to insert its item link.
- Ctrl-click equipment to request a dressing-room preview where supported.
- Hover the item title on Item Details to see the tooltip there too.
- New loot saves the complete hyperlink for random suffixes; old records fall back to item ID.
- This build does not register any additional WoW events and does not modify the SavedVariables schema.


v0.6.2 - Strict mob loot filtering
- CHAT_MSG_LOOT and CHAT_MSG_MONEY only count within 12 seconds of a single observed dead hostile NPC target.
- Excludes rewards while mailbox is open.
- Does not retroactively alter existing history.
- Conservative: loot from untargeted kills or multi-corpse pulls may be missed.
- Source is inferred from timing; the client does not prove which corpse produced each chat message.
