# iOS migration — status

## Baseline

| Item | Value |
| --- | --- |
| Integration branch | `ios` |
| Base commit | `7358160e808fb1870eeb20f5da8df832667019d1` (`origin/dev`, branch `dev`) |
| Base commit subject | `chore(deps): update Compose to 1.13 (#265)` |
| Verified against | audit of 2026-11-21 (`docs/ios-migration/audit/AUDIT.md`) |
| Remote `dev` at branch creation | same SHA — no intervening changes to audit |
| Worktree | `<migration-worktree>` (the Android checkout at `<repository-root>` is untouched) |

The integration branch was created directly from the audited commit in a separate worktree. No existing branch
was reset or overwritten.

## Phase status

| Phase | Scope | Status |
| --- | --- | --- |
| 1 | Read-only reconstruction audit | complete (`docs/ios-migration/audit/`) |
| 2 | `ios` branch, baseline record, `ios-foundation` scaffold | in progress |
| 3 | Core: store, dependencies, sharing, tokens, logging, haptics | in progress (foundation subset) |
| 4 | Server: transport, retry, models, SSE, pairing | not started |
| 5 | App shell: launch, connection, pairing, reconnect | not started |
| 6 | Home, drawer, projects, Catch Up, What's New | not started |
| 7 | Session, subagents, background work, request review | not started |
| 8 | Transcript | not started |
| 9 | Composer | not started |
| 10 | Media | not started |
| 11 | Settings, experiments, diagnostics, onboarding | not started |
| 12 | System integrations | not started |
| 13 | Voice (Experimental, off) | not started |
| 14 | Hardening | not started |

## Verified in this phase

_Filled in by the foundation commit; see the bottom of this file._

## Not verified

- Device-only paths: camera QR scanning, haptics, audio.
- Anything requiring signing identity, App Group, or push credentials: none are configured.
- Visual comparison with the original app: the original app is unavailable; October screenshots are evidence,
  not a target for pixel parity.

## Next

1. `ios-networking`: transport, retry, wire models, SSE, pairing (phase 4).
2. Foundation follow-ups: dependency clients for clock/date/id, shared-key storage plumbing.
