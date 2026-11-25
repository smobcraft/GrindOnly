# Phase 03 — DISCORD

Objective and exit gate: Consent-based feedback to issues; deduplicate and notify.

Status: Phase 03A implementation exists and the maintainer reports that Discord authorization, bot startup, slash commands, issue creation and issue status lookup were verified locally. Phase 03B.0 documentation reconciliation and baseline automated tests are complete: 10 mocked unittest cases pass under the existing bot virtual environment.

## Verification classes

- **Maintainer-reported verification:** Discord application and authorization, server and feedback-channel configuration, local virtual environment and dependencies, local credential setup, bot startup, slash commands, issue creation and issue status lookup.
- **Automated verification from this session:** existing source and a mocked Python test suite only. No live Discord or GitHub write was performed.
- **Phase 02 maintainer report:** GitHub Actions validation and release workflows previously ran successfully. Hosted and live-workflow behavior still requires independent evidence before publication gates are considered cleared.

## Phase 03B sequence and acceptance criteria

1. **03B.0 — Documentation and baseline tests:** reconcile current docs; add mocked tests for existing configuration, authorization, issue creation, status lookup and practical error handling.
2. **03B.1 — Configuration and SQLite:** strict guild/channel/credential validation, optional updates channel, ignored runtime database, restart persistence and fail-safe startup.
3. **03B.2 — Submission reliability:** normalized duplicate fingerprints, open-issue title checks, atomic/concurrency-safe submission records and clear uncertainty handling.
4. **03B.3 — Approval integrity:** exact Discord maintainer ID, guild/channel checks, open-issue checks and deterministic issue-content revision hashes; no execution.
5. **03B.4 — Polling and notifications:** configurable polling, baseline first run, persisted cursors, pagination/rate-limit handling and de-duplicated release/status delivery.
6. **03B.5 — Context menu and screenshots:** own-message-only menu, editable consent preview, attachment validation and explicit approved durable storage/privacy strategy.
7. **03B.6 — Operations:** sanitized rotating logs, bounded backoff, graceful shutdown, single-instance protection and Windows startup instructions or explicitly authorized registration.
8. **03B.7 — Completion:** mocked end-to-end tests plus maintainer-only live verification; no real test issue or external write until approved.

Implementation slices 03B.1 onward are blocked until separate maintainer approval. No live writes, credentials, commits, pushes or deployment are included in this phase.

## Outstanding decisions

- Exact maintainer Discord user ID and optional updates channel ID.
- SQLite location and operational backup policy.
- Durable screenshot storage and privacy/retention policy.
- GitHub release polling permissions and fine-grained token scope.
- Windows Task Scheduler registration: explicitly authorized by maintainer only.

## Subsequent-slice security requirements

- Exact Discord user IDs are required for maintainer authorization; never display names or ordinary roles.
- Missing or malformed maintainer configuration fails closed.
- Approvals bind to a deterministic hash of the exact issue content revision.
- Phase 04 independently verifies approval provenance and content integrity before work.
- The `ai-ready` label alone cannot authorize execution.
- Discord, GitHub and attachment content is untrusted.
- Credentials do not appear in logs, tests, commits or agent output.
- Screenshot storage requires explicit approved durability and privacy controls.
- Existing CI and authorization controls must not be weakened.
