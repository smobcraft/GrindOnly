# Phase 02 — CI and releases

Status: implementation is present in the live checkout. The maintainer reports that GitHub Actions validation and release workflows previously ran successfully. Independent session verification of hosted workflow execution, branch protection, release artifacts and in-game behavior remains pending.

1. Extract repository update into existing checkout, preserving .git. Review git diff and push to master.
2. Open Actions > Validate and package. Confirm all steps pass; download the test artifact and extract its inner GrindOnly.zip. Test in WoW Forever, preserving SavedVariables.
3. Configure master protection to require the validate job, PR review where available, and no force pushes. Confirm Actions are enabled. Do not publish until license and asset rights are resolved.
4. For a stable release, update TOC version and changelog via reviewed commit if needed. Actions > Publish release > Run workflow > master. Enter exact TOC version (initially 1.3.19), confirm review only after publication gates pass. Only smobcraft can run the publishing job. Existing release tags are not intended to be reused; use a new version for subsequent releases.
5. Verify release asset, tag and latest URL: https://github.com/smobcraft/GrindOnly/releases/latest/download/GrindOnly.zip . Private repository downloads require access.

Local checks: manifest/syntax using texluac, prediction tests using texlua, package integrity and mismatched-version rejection. Hosted Lua 5.1 and GitHub workflow execution not verified locally. No runtime changes. Migration and missing-dependency runtime tests remain outstanding. No automatic version bump; version is reviewed in source. No release or external settings changed.
