# Project context

## Decisions — 2026-10-04

- User approved a reliable personal dual-provider monitor, with future public release.
- User accepts activity-driven Claude samples and explicit idle cache state.
- Keep present UI layout; visual directions remain unselected. No broad architecture rewrite.
- DevOS L0 Core inherited; L1 lightweight engineering; L2 this file, AGENTS and progress; no full L3 document suite.
- Single-session implementation; independent review may be delegated only when useful and authorized.

## Reuse map

| Existing component | Responsibility |
| --- | --- |
| Models/QuotaModels.swift | Quota windows, snapshots, freshness, settings |
| Providers/ClaudeQuotaProvider.swift | Parse/select local Claude samples |
| Providers/ClaudeDesktopUsageService.swift | Opt-in desktop-session usage requests; native SQLite, Keychain and Chromium cookie decoding |
| Providers/CodexQuotaProvider.swift | Codex app-server RPC and window parsing |
| ClaudeCollector/ClaudeCollectorManager.swift | Status-line installation and restoration |
| Stores/QuotaStore.swift | Refresh lifecycle, cache, published state |
| Stores/HistoryStore.swift | Local trend persistence and retention |
| UI/ServiceCardView.swift | Provider quota and status presentation |

Global module index was checked; no existing global Swift quota/collector module fits this work. Extend these components rather than introduce a framework.

## Lessons from audit

- A passing parser test does not establish that the production refresh path calls it.
- Freshness must follow observedAt, not the time a local file was read.
- Generated collector scripts must be executed against synthetic JSON in temporary paths containing spaces, not only inspected as strings.
- Installed collectors and bundled binaries can differ from source. Verify each separately and do not reinstall old source over working settings.
- Keep fixture data synthetic; never copy local credentials or conversation records into tests or GitHub.

- A global last-activity fingerprint fails with multiple idle sessions. Deduplicate activity per session, keep only opaque hashes, and serialize atomic sample updates.
- Clearing imported history requires a persistent cutoff; otherwise the next refresh or restart silently imports cleared data again.
- The live legacy status line uses an unquoted path with spaces. Exact known installer forms can be migrated reversibly; custom/compound commands require review.
- A desktop-only user must not be required to send Claude Code messages. Desktop history preserves percentages but omits reset timestamps; the desktop's own usage response contains them.
- Fixing source and generating a temporary app does not update the installed application. Verify the running binary and install the validated build with a recoverable backup.
- Git transport can fail while GitHub REST works. The fallback uploads the same Git objects and verifies blob/tree/commit hashes before creating a ref/PR.

## Desktop support decision — 2026-10-13

- User requires Claude desktop-only quota and reset support. Existing desktop history remains the credential-free fallback.
- User explicitly authorized reuse of the desktop login for read-only usage, with no credential export or conversation transmission.
- Desktop session access is disabled by default and persisted separately from legacy settings. Only Claude's sessionKey/lastActiveOrg cookies and its named Safe Storage key are read. Secrets stay in memory; requests go only to the fixed claude.ai usage endpoint, with cookies/caching/redirects disabled in the transport.
- Cookie decryption uses native platform libraries. Unknown encryption or Keychain failures preserve local history and expose a safe warning. No external dependency, release configuration change or UI redesign.
- Private desktop API and cookie storage are compatibility risks; public release needs further review, explicit opt-in and rollback/fallback.
