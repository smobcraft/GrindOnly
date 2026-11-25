Grind Only v0.7.0 — Live Grinding Efficiency
===========================================
Install: exit WoW, back up your GrindOnly folder and WTF SavedVariables, then replace Interface/AddOns/GrindOnly with this folder.

New:
- Efficiency button on main dashboard toggles compact live panel.
- Rolling 5, 15 and 30 minute observed kills/hour.
- Observed target-to-death timing and average gap between observed kills.
- New Efficiency tab in /wgf stats with kill counts and 5-minute trend bars.
- /wgf eff or /wgf efficiency opens efficiency stats.
- /wgf reset also clears rolling efficiency observations.

Preserved:
- v0.6.2 conservative mob-loot gate and mailbox exclusion.
- All old history, existing item tooltips, buff reminders, zone/mob/loot/trend tabs.
- No COMBAT_LOG_EVENT_UNFILTERED registration.

Limitations:
- Only counts hostile targets seen alive and subsequently dead while targeted.
- Observed target-to-death time may include idle time and is not precise combat duration.
- Kills/hour is based on observed kills, not all kills. First-minute estimates are volatile.
- Between-kill gap can include travel, healing, looting and time away from keyboard.
- No retroactive efficiency timeline; new observations start with v0.7.0.
- WoW client testing still required.
