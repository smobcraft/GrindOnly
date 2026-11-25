# Security

Do not publish credentials, Discord tokens, API keys or player history. Report security concerns privately to the maintainer rather than posting exploit details or secrets publicly. A private reporting channel will be configured in Phase 01. Never run untrusted public PRs on a personal self-hosted runner. AI workers must not have merge or release permissions.

## Phase 03B security baseline

- Maintainer authorization must use an exact Discord user ID and must fail closed when configuration is missing or malformed.
- Approval records must bind to a deterministic hash of the exact issue content revision. The `ai-ready` label is metadata, not proof of approval.
- Phase 04 must independently verify approval provenance and content integrity before executing development work.
- Discord messages, GitHub issues/comments and attachments are untrusted input.
- Credentials must not appear in logs, test fixtures, source, commits or agent output.
- Screenshot storage requires maintainer-approved durable storage, privacy and retention controls.
- Discord/GitHub operations are least-privilege, timeout-bounded and disabled on uncertain state rather than blind retried.
- Existing CI, branch protection and authorization controls must not be weakened.
