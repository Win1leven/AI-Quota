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
