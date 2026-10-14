# AI-Quota / Quota Monitor

A native macOS menu-bar and floating-panel monitor for Codex and Claude quota windows.

## Product contract

- Show remaining quota, reset time when available, source and actual sample time.
- Claude collects during Claude Code activity. Idle data is explicitly cached or stale; refreshing a file does not create a fresh sample.
- Claude desktop-only use is supported through opt-in desktop login access for quota and reset timestamps. Without it, local desktop history supplies cached percentages with reset unknown.
- Local token totals and API-equivalent estimates are not subscription quota or an actual bill.
- Personal reliability first; public distribution and visual redesign are separate milestones.

## Desktop assistant

Settings → General → Display selects menu bar only, desktop assistant only, or both. The compact capsule shows the lowest known remaining quota for each service; click it for existing details. An amber dot marks cached data or a refresh warning. Right-click for refresh and settings.

If Claude reports a five-hour window waiting for the first message, the app displays that state without inventing a reset date. Once the account supplies a reset timestamp, the normal countdown resumes.

## Development

Requires macOS 13+ and Swift 6 / Xcode. No external package dependencies.

```sh
swift test
```

See [progress and acceptance](docs/PROGRESS.md) and [project context](docs/PROJECT_CONTEXT.md). Existing app/DMG artifacts predate the current audit and are excluded from source control.

## Current limitations

This is a development prototype. Claude collection, cache trust, Codex window completeness, and settings have been repaired in tracked PR slices. Codex runtime parity and real desktop-only Claude quota/reset retrieval are verified. Desktop capsule, settings and details have been inspected in the installed development app. A real reset boundary remains an acceptance item. See the progress record for precise boundaries.

Desktop usage access reads only the necessary local Claude cookies and its Keychain storage key, then queries the fixed claude.ai usage endpoint. Credentials remain in memory, and chat content is not sent. The setting is off by default. The private endpoint and desktop cookie format can change; failed access keeps local history and displays a warning.

The existing analytics implementation reads local usage files and uses provider credentials for provider requests. It has not yet been redesigned for the passive Claude collection contract; credential changes require a separate review. Do not interpret the legacy in-app privacy wording as a verified privacy specification.
