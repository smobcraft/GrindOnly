# Known limitations and audit backlog

- High: target-based kills undercount AoE; loot attribution is inferred from recent deaths. Chat loot can include non-grinding rewards outside the mailbox. XP history includes quests; predictions use formula XP instead of historical XP rewards but throughput is not mob-specific.
- High: Forever XP scaling, elite modifiers and rested mechanics are provisional. The formula is not verified against the live client. Database EV assumes one item per drop, incomplete vendor prices and uncertain coin coverage. Do not interpret forecasts as guarantees.
- Medium: native tooltip callback catches errors silently; restricted client fields or unsupported hooks can suppress augmentation. Add bounded diagnostics and in-game tests.
- Medium: historical baselines scan session history repeatedly; tooltip and Explorer scans may be expensive with large databases. Profile before optimizing. Session history and tooltip caches are not globally bounded.
- Medium: Explorer index is built once; loading ForeverDB after first opening may require reload. Verify database field mappings (notably item quality), full-data variants and map compatibility against fixtures.
- Medium: core is a large module with compressed statements and legacy UI paths; avoid broad refactors until coverage improves. English parsing limits localization.
- Medium: tooltip preference is read during module initialization; verify persistence across reloads. Map toggle is session-local.
- Release gate: the maintainer has confirmed redistribution rights for the included source and Tactical textures and selected GPL-3.0-only. The repository is public, but no stable addon release has been published. Branch protection, in-game smoke/regression tests and migration tests remain outstanding.
