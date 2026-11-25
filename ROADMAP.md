# Roadmap

| Phase | Deliverable | Exit gate |
|---|---|---|
| 00 Foundation | Audit, conservative cleanup, docs, baseline tests | Local package verified; publication blockers recorded |
| 01 Repository | Repository readiness, issue labels, branch protection, public conversion | Repository is public and source/asset rights and license are confirmed; GitHub requires changes through a pull request, with exact rule configuration to review |
| 02 CI/releases | PR checks, packaging, manually authorized releases, stable ZIP link | Tested release artifact and download |
| 03 Discord | Feedback commands, issue creation (including Discord-hosted image links), consent and status notifications | Mocked lifecycle tests pass; maintainer completes live verification |
| 04 AI worker | Deferred: isolated worker, independently verified approval provenance, optional draft PRs | Separate authorization and safety review before implementation |
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
| 03B.5 | Message context menu and image links | Consent preview links supported Discord-hosted images; link expiry and public visibility are disclosed |
| 03B.6 | Operational reliability and Windows startup | Redacted logs, bounded backoff, graceful shutdown, and single-instance behavior are tested; startup registration remains manual |
| 03B.7 | End-to-end validation and phase completion | Mocked end-to-end suite passes; live checks and any remaining blockers are documented |

Automated tests are required in every implementation slice. Phase 04 autonomous coding and PR creation are explicitly deferred and are not an exit criterion for Phase 03. The `ai-ready` label remains metadata only; any later worker must independently verify approval provenance and content integrity.
