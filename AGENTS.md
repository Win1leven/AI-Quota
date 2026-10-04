# AI-Quota

- Communicate in Chinese; use English code identifiers.
- Follow DevOS Core: evidence before edits, small reversible PR slices, relevant tests, durable lessons. Continue ordinary work without repeated approval.
- Product: reliable personal macOS Codex/Claude quota monitor, with eventual public release. Repository stays private until explicitly approved.
- Claude: collect during Claude Code activity, show sampled time and cached/stale data during inactivity. Never infer reset dates or quota from token counts.
- Keep the existing Provider → QuotaStore → SwiftUI structure. No new packages, major redesign, credential changes, release/CI changes, or production deployment without the applicable gate.
- Preserve existing Claude status line and unrelated settings. Test installation/restoration in temporary directories; do not modify live global configuration during automated tests.
- Reuse map and lessons: `docs/PROJECT_CONTEXT.md`. Milestones and verification: `docs/PROGRESS.md`.
- Source tests: `CLANG_MODULE_CACHE_PATH=/tmp/aiquota-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/aiquota-swift swift test --disable-sandbox --scratch-path /tmp/aiquota-build`.
- Never commit local usage history, credentials, generated apps, or DMGs. Do not print secrets. Existing binaries are not evidence of current source behavior.
