# Grind Only

A local grinding analytics addon for **World of Warcraft: Forever**. Track earnings, experience, buffs and farming history, and explore potential farming targets using ForeverDB.

**Baseline:** v1.3.19 (Phase 00 development snapshot; not yet a public release). Target client interface: 16001. English loot and buff messages are assumed.

## Installation

1. Close WoW Forever.
2. Download the addon release ZIP (GitHub Releases will be configured in Phase 02). For this repository snapshot, use the inner `GrindOnly` folder directly.
3. Copy that folder into `World of Warcraft/_forever_/Interface/AddOns/` so `AddOns/GrindOnly/GrindOnly.toc` exists. Do not nest it twice.
4. For database features, download [ForeverDB by Fatedfr](https://www.curseforge.com/wow/addons/forever-db) separately. Extract its supplied addon folders into the same AddOns directory; enable ForeverDB on the character selection AddOns screen. The inspected reference version is 2026.11.23.41. The core tracker does not require it.
5. Restart WoW, enable Grind Only, log in and type `/wgf show`. Right-click the coin minimap icon or type `/wgf stats` for analytics.

For upgrades, close the game and replace only the addon folder. Keep `WTF/Account/<account>/SavedVariables/GrindOnly.lua` and its backup. Never copy personal SavedVariables into this repository.

## Features and how to use them

| Feature | How to use |
| --- | --- |
| Live dashboard | `/wgf show`; drag/resize the panel. Rolling 15-minute gold and XP rates, session totals, buff status and efficiency. |
| Overview | `/wgf stats` → Overview for session history. |
| Mobs | Stats → Mobs; select a row for observed kills, earnings and attributed drops. |
| Loot | Stats → Loot; select an item for recorded sources; hover for native item tooltip. |
| Zones | Stats → Zones; select a zone to drill into subzones and compare rates. Historical XP may be estimated. |
| Spots | Stats → Spots or `/wgf spots` for observed farming locations. |
| Trends | Stats → Trends; choose Day, Week or Month. |
| Notable | Stats → Notable; switch value/rarity sorting. |
| Combat | Stats → Combat for approximate target timing and gaps. |
| Efficiency | Stats → Efficiency or `/wgf eff`; compare gold and XP rates with comparable historical sessions. |
| Buffs | Stats → Buffs or `/wgf buffs`; configure tracked and custom buffs. |
| Explorer | Stats → Explorer; search by name or ID, select category, click results and page through details. Items, NPCs, quests, objects, zones and personal history. |
| Mob Atlas | `/goatlas <mob name>` to search; `/goatlas map` for map pins. Use map checkbox and level filters. |
| Notable loot | Hover a living NPC; native tooltip shows up to five selected drops when supported. |
| Predictive grinding | Hover a living NPC; estimated gold/hr and XP/hr. `/goatlas prediction detail` reveals assumptions and per-kill rates. |

## Commands

`/wgf` and `/grindonly` are aliases. No argument toggles the dashboard. Subcommands: `show`, `hide`, `stats`, `buffs`, `spots`, `eff` (or `efficiency`), `mob <row number>`, `reset` (starts a new session, not a history wipe), `debug` (cast diagnostics).

`/goatlas` opens the atlas; `/goatlas <name>` searches; `/goatlas map` opens the map; `/goatlas level <min> <max>` filters map levels; `/goatlas tooltip on|off|toggle` controls notable loot; `/goatlas prediction on|off|detail|compact` controls forecasts; `/goatlas debug` prints database/map/hook diagnostics.

## Understanding the numbers

Gold is looted coin plus vendor sell value, not auction-house profit. Mailbox rewards are excluded; other chat loot may be counted. XP tracking measures character XP changes, including quests. Kills are target-based and can miss AoE or untargeted deaths. Efficiency needs at least three comparable historical sessions of five minutes or more; live scoring begins after five minutes. Predictions use historical session throughput, database loot probabilities and a provisional solo XP formula with a rested-pool cap. They are estimates, not guaranteed rewards. Missing history or prices can prevent forecasts. See [known issues](docs/KNOWN_ISSUES.md).

## Feedback and development

Use GitHub Issues once the repository is created. Include addon/client versions, steps, expected and actual behavior, and sanitized Lua errors. Discord integration and AI-assisted PRs are planned, not active. See [CONTRIBUTING](CONTRIBUTING.md), [roadmap](ROADMAP.md), and [architecture](docs/ARCHITECTURE.md).

All tracking is local to WoW SavedVariables; this snapshot has no external feedback service or telemetry. ForeverDB is a separate project and is not bundled. Distribution license and remaining asset provenance must be approved before public publication; no open-source license is granted by this draft.
