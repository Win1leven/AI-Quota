# Trustworthy quota implementation plan

Goal: implement the approved M1 contract in PROGRESS.md using existing providers, store and views. Swift 6, macOS 13+, no new dependencies. Execute inline with test-first bug reproduction. No visual redesign or credential changes.

## G1 — Samples and cache
1. Add isolated path injection to Claude provider and expose Codex JSON parsing internally for fixture tests.
2. Write tests for two Codex windows, per-limit precedence, fresh collector versus desktop fallback, invalid timestamp/percentage, and sample aging. Run and record failures.
3. Parse primary and secondary; reject invalid windows. Select a recent valid collector before history; otherwise select newest valid fallback. Keep source and observedAt.
4. Derive freshness from sample time in model/store/UI. Preserve refresh errors and last valid snapshot. Display reset/sample/source state without redesign.
5. Run relevant tests, review diff, create a verified PR linked to M1.

## G2 — Collector lifecycle
1. Inject temporary home/support paths into collector manager. Test real generated script with stdin JSON and paths with spaces; test existing statusLine output and config restoration.
2. Fix statusLine object handling, shell quoting, script parsing and atomic writes; installation must be idempotent and preserve unrelated settings. Restoration must refuse conflicting edits.
3. Connect settings controls with explicit user-triggered install/restore. Tests never write live configuration.
4. Connect history retention/default range/menu modes; disable unsupported launch-at-login control. Verify only these affected behaviors.
5. Run focused tests, review sensitive config boundaries, publish G2 PR.

## G3 — Acceptance
1. Inspect both PRs for secrets, regressions and incomplete claims; run combined regression/build once.
2. Prepare live verification procedure. Compare official usage and samples only when current activity and UI access are available.
3. Update progress with exact results; leave gates and blocked acceptance explicit. No release, credential changes or live config installation without the applicable approval.
