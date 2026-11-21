# Phases — repository numbering against the audit plan

The audit plan (`audit/PLAN.md`) numbers the work P2–P14. This document maps that numbering to what the
repository actually contains, so a later phase is never announced as "done" because an earlier one looked
finished. Statuses here are the same vocabulary as `PARITY.md`: `not started`, `scaffold`, `partial`, `done`.
`done` means the behaviour exists in this repository **and** a test demonstrates it.

## Map

| Audit phase | Scope in the plan | Status | Evidence |
| --- | --- | --- | --- |
| P1 | Read-only reconstruction audit | done | `docs/ios-migration/audit/` |
| P2 | `ios` branch, baseline, reproducible project, gate | done on `ios-foundation` | `BASELINE.md`, `ios/project.yml`, `ios/scripts/` |
| **P3** | **Core: store, dependencies, sharing, tokens, logging, haptics** | **partial** | checklist below |
| P4 | Server: transport, retry, models, SSE, pairing | not started | only address validation (`ServerEndpoint`) |
| P5 | App shell: launch, connection, pairing, reconnect | scaffold | launch states and an inert probe; no pairing, no reconnect |
| P6 | Home, drawer, projects, Catch Up, What's New | not started | folders only |
| P7 | Session, subagents, background work, request review | not started | folders only |
| P8 | Transcript | not started | folders only |
| P9 | Composer | not started | folders only |
| P10 | Media | not started | folders only |
| P11 | Settings, experiments, diagnostics, onboarding | not started | folders only |
| P12 | System integrations | not started | folders only |
| P13 | Voice (Experimental, off) | not started | folders only |
| P14 | Hardening | not started | — |

**P2 is not P3.** The scaffold proves the project builds and the launch states exist; it does not prove store
semantics, sharing, motion or haptics. P4 (networking) is therefore **not** the immediate next phase.

## P3 checklist

| Requirement (audit `PLAN.md` P3) | Status | Evidence or gap |
| --- | --- | --- |
| Dependency clients as `DependencyKey`s with inert test values | partial | `ConnectionProbe`, `DateClient`, `UuidClient` (`OpenCodeCore/Dependencies`), `HTTPTransport` (inert) |
| `Shared` storage, including Keychain | partial | `UserDefaultsStorage`, `InMemoryStorage`; **Keychain missing** (blocked on the owner-supplied service name, D-7) |
| Design tokens: colour | done | `Design/OpenCodeColorTokens.swift`; every token resolves and body/link text clears WCAG AA in both appearances |
| Design tokens: type | done | `Design/OpenCodeTypeTokens.swift`; system font, system monospaced for code/logs |
| Design tokens: radii, spacing | **missing** | no `OpenCodeRadius`/`OpenCodeSpacing` equivalent yet |
| `MotionRole` equivalents | **missing** | no motion vocabulary or reduce-motion policy yet |
| `AppLog` categories | done | `Logging/AppLog.swift` (`send`, `network`, `stream`, `voice`, `app`, `perf`) |
| Log redaction | done | `LoggingTests` (addresses, emails, long tokens) |
| Haptics vocabulary | **missing** | no client or vocabulary |
| Gate: path-indexed cancellation | **missing** | no test; TCA linkage is not a test |
| Gate: `ifLet` child-first ordering | **missing** | no test |
| Gate: presented-child cancellation on dismissal | **missing** | no test |
| Gate: Keychain round-trip | **missing** | blocked on D-7 |
| Gate: every shared key's default | **missing** | no shared keys defined yet |
| Gate: redaction | done | as above |

## The categories named in the handoff

- **Architecture.** The layer split exists (core/server/app logic in the package, views in the app target) and
  four dependency clients are in place. The sharing layer (Keychain, shared keys, defaults) and the haptics
  client are not, so the original architecture requirement is partially met.
- **Parity ledger.** `PARITY.md` now marks only demonstrated behaviour as `done`; TCA linkage is recorded as
  `scaffold`, because no reconstructed reducer ordering, cancellation identity or presentation semantics are
  tested yet.
- **Navigation.** The app currently switches between four launch states. The App → Home → Session store
  topology, `@Presents` children and page stack belong to P5–P7 and are not started.
- **Platform decisions.** D-1…D-13 are recorded. Still open and blocking later work: D-2 (transcript motion),
  D-3 (text input), D-4 (photo picking), D-5 (glass), D-7 (identifiers/Keychain service), D-9 (push).
- **Previews.** Preview support is enabled, two launch-state previews exist, and the dependency context under
  Xcode previews resolves inert values, so a preview cannot reach the network.

## Remaining prerequisites before the next implementation phase (P3)

1. **PR #1 merged into `ios` by the owner.** The next task branch starts from the updated `ios`, not from the
   documentation-only commit, and must not recreate the scaffold.
2. **D-7 (owner-supplied identifiers).** The Keychain service name and bundle identifiers are needed for the
   Keychain and shared-key items; those two gate items cannot be finished without them.
3. Nothing else blocks: radii/spacing tokens, motion vocabulary, haptics, and the TCA semantics tests
   (cancellation, child-first `ifLet`, presentation dismissal) can be built and verified without owner input.

P4 (networking) starts only after the P3 gate is green, or after the owner explicitly reorders the phases.
