# Phase 03 — DISCORD

Objective and exit gate: Consent-based feedback to issues; deduplicate and notify.

Status: Phase 03A implementation exists and the maintainer reports that Discord authorization, bot startup, slash commands, issue creation and issue status lookup were verified locally. Phases 03B.0 through 03B.7 implementation and mocked validation are complete. The final suite passes 65 tests. Live verification of the new health/image-submission behavior has not been performed. Phase 04 autonomous issue-to-PR work is deferred and is not required for Phase 03 completion.

## Verification classes

- **Maintainer-reported verification:** Discord application and authorization, server and feedback-channel configuration, local virtual environment and dependencies, local credential setup, bot startup, slash commands, issue creation and issue status lookup.
- **Automated verification from this session:** existing source and a mocked Python test suite only. No live Discord or GitHub write was performed.
- **Phase 02 maintainer report:** GitHub Actions validation and release workflows previously ran successfully. Hosted and live-workflow behavior still requires independent evidence before publication gates are considered cleared.

## Phase 03B sequence and acceptance criteria

1. **03B.0 — Documentation and baseline tests:** reconcile current docs; add mocked tests for existing configuration, authorization, issue creation, status lookup and practical error handling.
2. **03B.1 — Configuration and SQLite:** strict guild/channel/credential validation, optional updates channel, ignored runtime database, restart persistence and fail-safe startup.
3. **03B.2 — Submission reliability:** normalized duplicate fingerprints, open-issue title checks, atomic/concurrency-safe submission records and clear uncertainty handling.
4. **03B.3 — Approval integrity:** exact Discord maintainer ID, guild/channel checks, open-issue checks and deterministic issue-content revision hashes; no execution.
5. **03B.4 — Polling and notifications:** complete. Configurable 5-minute default polling, quiet baseline, persisted cursors/outbox, pagination, fail-closed public-repository check, status/release de-duplication and retryable delivery.
6. **03B.5 — Context menu and images:** own-message-only context menu and editable public preview; PNG, JPEG, GIF, and WebP are linked from Discord's CDN. Links may expire, are not archived by the bot, and are included only after user confirmation. Other attachment types are excluded.
7. **03B.6 — Operations:** rotating redacted logs, bounded polling backoff, graceful shutdown, single-instance protection, health diagnostics, and a Windows launcher using the existing virtual environment. Startup-task registration is not performed.
8. **03B.7 — Completion:** mocked end-to-end tests and maintainer-only live verification; do not make real test issues or external writes without approval.

Slices 03B.1 through 03B.7 are implemented and covered by the final mocked suite. Phase 03B.5 uses Discord CDN image links under explicit maintainer direction; images remain publicly linked and may expire. The maintainer has deferred Phase 04 autonomous code/PR creation. No live Discord/GitHub writes have been performed.

## Outstanding decisions

- Exact maintainer Discord user ID and optional updates channel ID.
- Pre-create the `ai-ready` GitHub label with repository-approved color/description; the bot does not create labels.
- SQLite location and operational backup policy.
- Image links point to Discord CDN rather than durable storage; expiry is accepted for the current scope.
- GitHub release polling permissions and fine-grained token scope.
- Verify Discord bot access to the configured update channel, or retain feedback-channel fallback.
- Delivery is at-least-once across crashes; a Discord-accepted message whose local acknowledgement is interrupted may be sent again.
- Non-image attachments are excluded. Rehosting or retaining images requires a separate storage/privacy decision.
- Windows Task Scheduler registration remains manual and is not part of this implementation.

## Subsequent-slice security requirements

- Exact Discord user IDs are required for maintainer authorization; never display names or ordinary roles.
- Missing or malformed maintainer configuration fails closed.
- Approvals bind to a deterministic hash of the exact issue content revision.
- Phase 04 independently verifies approval provenance and content integrity before work.
- The `ai-ready` label alone cannot authorize execution.
- Discord, GitHub and attachment content is untrusted.
- Credentials do not appear in logs, tests, commits or agent output.
- Rehosting or retaining screenshots requires explicit approved durability and privacy controls.
- Existing CI and authorization controls must not be weakened.
- The `/approve` command records repository, issue number, exact title/body revision hash, exact maintainer ID, timestamp and approval status in SQLite. Title/body changes produce a distinct hash and require a new approval.
- On label API uncertainty, the approval record remains non-approved; operators must inspect state before retrying.
- Phase 04 must query the local approval record and compare the current GitHub issue revision itself; the label is not sufficient proof.
- Notifications are disabled unless the GitHub repository API confirms `private: false`; public repository release/issue content may then be sent to a messageable channel in the configured guild with mentions suppressed.
- Issue status notifications cover issue creation, state, and labels; title/body-only edits do not notify. Pull requests are excluded.
- First successful poll establishes baselines without historical announcements. Failed GitHub reads do not advance cursors; pending Discord deliveries retry on a subsequent poll.
- Context-menu submissions are limited to the invoking user's own message in the configured guild/channel; the user reviews and edits the public preview before submitting. Only validated PNG, JPEG, GIF, and WebP Discord CDN links are included; other attachment types are excluded.
