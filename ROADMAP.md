# Roadmap

| Phase | Deliverable | Exit gate |
|---|---|---|
| 00 Foundation | Audit, conservative cleanup, docs, baseline tests | Local package verified; publication blockers recorded |
| 01 Repository | Private staging repo, license/asset approval, issue labels, branch protection, public conversion | Maintainer approves visibility and documentation |
| 02 CI/releases | PR checks, packaging, manually authorized releases, stable ZIP link | Tested release artifact and download |
| 03 Discord | Feedback commands, issue creation, consent and status notifications | Valid submission creates one issue |
| 04 AI worker | Isolated local Codex proof of concept, approved issue queue, draft PRs | Auth verified and approved task produces tested draft PR |
| 05 Security | Least privilege, timeouts, logs, injection tests, kill switch | Unauthorized jobs fail closed |
| 06 Integration | End-to-end feedback to release tests | Real request completes lifecycle |
| 07 Public beta | In-game regression and v1.4.0 release | Players install and submit feedback |
| 08 CurseForge | Dependency metadata, author approval and synchronized releases | Distribution verified |

Security gates apply from the start, not only Phase 05. Local Codex subscription automation is a hypothesis to validate, not a guaranteed entitlement. Cloud API billing is an alternative.

## Phase 03B implementation sequence

Implementation is split into maintainer-approved slices:

| Slice | Scope | Exit criterion |
|---|---|---|
| 03B.0 | Documentation reconciliation and baseline automated Discord bot tests | Docs distinguish verified reports from session evidence; mocked baseline tests pass |
| 03B.1 | Configuration and SQLite persistence | Configuration validation and restart-safe local state are tested |
| 03B.2 | Duplicate detection and submission reliability | Concurrent/retried submissions are deduplicated and uncertain API results are disclosed |
| 03B.3 | Maintainer authorization and approval integrity | Exact-ID authorization and content-revision approval records are tested fail closed |
| 03B.4 | Release announcements and issue status notifications | Baseline, polling, pagination, rate-limit and delivery behavior is tested |
| 03B.5 | Message context menu and screenshot support | Consent preview and only an approved durable attachment strategy are implemented |
| 03B.6 | Operational reliability and Windows startup | Redacted logs, backoff, shutdown and single-instance behavior are tested; startup remains explicitly authorized |
| 03B.7 | End-to-end validation and phase completion | Mocked end-to-end suite passes and maintainer live verification is documented |

Automated tests are required in every implementation slice. Slices 03B.1 through 03B.7 are not authorized yet. Phase 04 remains separately gated: it must independently verify immutable approval provenance and content integrity; a label alone is insufficient.
