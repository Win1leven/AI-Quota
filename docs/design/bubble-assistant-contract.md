# Desktop assistant contract

Visual Gate Receipt: PASS — HOOK_DISPLAY_MODE_APPROVE.
- Visible alternatives: bubble-assistant-directions.png, 3 low-fidelity candidates.
- User selection: B, compact dual-service capsule; reason: compact, both values always visible.
- Calibration: reliability comes first. Claude's authoritative zero-usage/null-reset response means waiting for the first message, confirmed by the user in desktop Usage. Unknown/reset/loading/cache states must not be invented or hidden.
- Handoff Authority Check: PASS. This contract governs the selected surface; no global redesign.

## Frozen scope

- Dark capsule, 180×48 points, two inline service names/remaining percentages, subtle divider and shadow. Match existing dark cards and teal/green provider colors.
- Each service uses its most constrained known quota window. Tooltip states its window, sample time, freshness and supplied reset/waiting state. Unknown data is a dash; cache/error uses an amber status dot without obscuring saved values.
- Click opens/brings forward the existing detail panel. Drag moves the capsule and saves its position. Right click: refresh, settings, return to menu-bar mode, quit.
- General Settings selects menu bar only (default), desktop assistant only, or both. Preserve existing settings on decode; no implicit opt-in during upgrade. Reuse existing all-spaces/always-on-top preferences.
- Start bottom-right of the visible screen when no valid saved position exists; restore within an available screen. Never take keyboard focus or disappear when another app activates.
- Existing Provider → QuotaStore remains the sole data source. No assistant-specific quota fetches, credentials, estimates or duplicate caches.
- No decorative animation, avatar, sound, new dependency or release configuration changes.

Verification: model regression for most-constrained windows and unknown state, old settings decode and persistence, manual drag/click/context settings, mode switching, restart and source/freshness parity.
