# Architecture

TOC load order: `GrindOnly.lua` (core state, events, target sampling, history, legacy controls and analytics); `Prediction.lua` (pure forecast functions); `MobAtlas.lua` (database adapter, map pins, native tooltip); `TacticalUI.lua` (shared styles); `TacticalDashboard.lua` (presentation); `Explorer.lua` (local database search and detail panels).

Core exports dashboard and forecast context to later modules. `GrindOnlyDB` is the account-wide SavedVariables root; schema version 5, analytics schema 1, session schema 4. Sessions, mobs, items, zones, days, observations, buff preferences and UI settings persist. Detailed five-minute buckets are capped at 12,000. Live rolling rewards are session-local. Target sampling runs every 0.2 seconds; core refresh approximately every 2 seconds; dashboard refresh approximately every 0.35 seconds. No combat log event is registered. ForeverDB loads on demand and its tables remain external. Map and tooltip caches are in memory. Explorer indexes names and scans source tables locally.

Do not rename the addon folder, SavedVariables root or existing keys without a migration. Separate UI, data and calculations gradually with tests rather than rewriting the core in one change.
