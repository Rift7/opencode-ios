# Phases — repository numbering against the audit plan

The audit plan (`audit/PLAN.md`) numbers the work P2–P14. This document maps that numbering to what the
repository actually contains, so a later phase is never announced as "done" because an earlier one looked
finished. Statuses here are the same vocabulary as `PARITY.md`: `not started`, `scaffold`, `partial`, `done`.
`done` means the behaviour exists in this repository **and** a test demonstrates it.

## Map

| Audit phase | Scope in the plan | Status | Evidence |
| --- | --- | --- | --- |
| P1 | Read-only reconstruction audit | done | `docs/ios-migration/audit/` |
| P2 | `ios` branch, baseline, reproducible project, gate | done — merged into `ios` as `143d8f86` (PR #1) | `BASELINE.md`, `ios/project.yml`, `ios/scripts/` |
| **P3** | **Core: store, dependencies, sharing, tokens, logging, haptics** | **done on `ios-core`** | checklist below |
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
| Dependency clients as `DependencyKey`s with inert test values | done | `ConnectionProbe`, `DateClient`, `UuidClient` (`OpenCodeCore/Dependencies/FoundationClients.swift`), `HapticsClient` (`.../Haptics/HapticsClient.swift`), `HTTPTransport` (`.../Transport/HTTPTransport.swift`); every key's test value is inert and `DependencyIsolationTests` fails a key that omits one |
| `Shared` storage, including Keychain | done | `UserDefaultsStorage`, `InMemoryStorage`, `KeychainStorage(service:operations:)`; `SharedStore` + `SharedKeys`; every operation returns an explicit outcome |
| Design tokens: colour | done | `Design/OpenCodeColorTokens.swift`; every token resolves and body/link text clears WCAG AA in both appearances |
| Design tokens: type | done | `Design/OpenCodeTypeTokens.swift`; system font, system monospaced for code/logs |
| Design tokens: radii, spacing | done | `Design/OpenCodeLayoutTokens.swift`; grid and radius scale are data, with a corner clamp; `LayoutTokenTests` |
| `MotionRole` equivalents | done | `Motion/OpenCodeMotion.swift`: fourteen roles, per-phase curves, Reduce Motion collapse, pose and stagger helpers; `MotionTests` |
| `AppLog` categories | done | `Logging/AppLog.swift` (`send`, `network`, `stream`, `voice`, `app`, `perf`) |
| Log redaction | done | `LoggingTests` (addresses, emails, long tokens) |
| Haptics vocabulary | done | `Haptics/HapticsClient.swift`: eleven named haptics, platform-neutral feedback table, injectable client whose test value is inert; `HapticsTests` |
| Gate: path-indexed cancellation | done | `OpenCodeAppTests/StoreSemanticsTests.swift` (`CancellationIdentityTests`, `PresentedChildCancellationTests`) — cancellation is by identity, and a presented child's effects die with the path element |
| Gate: `ifLet` child-first ordering | done | `StoreSemanticsTests` (`ChildFirstIfLetTests`) — the parent observes the child's post-reduction state |
| Gate: presented-child cancellation on dismissal | done | `StoreSemanticsTests` (`PresentedChildCancellationTests`) — dismissal and identity change both cancel; a clock advance after each receives nothing |
| Gate: Keychain round-trip | done | `KeychainProbeTests` runs it in the app process (a hostless test bundle has no keychain entitlement); `KeychainFailureTests` covers denied/unavailable/missing outcomes without a real keychain |
| Gate: every shared key's default | done | `SharedStoreTests` asserts each key's default, the registry's uniqueness and each key's storage routing |
| Gate: redaction | done | as above |

The gate runs on the maintained TCA store (1.26.2, pinned). The compositions under test are this
migration's own representative shapes — a parent with a child `ifLet`, a presented sheet, a worker with
identified effects — not a re-test of TCA's suite. TCA's documented semantics are adopted rather than
reproduced: child-before-parent reduction, navigation-scoped effect cancellation, and dismissal leaving
the parent to clear the presented state.

## The categories named in the handoff

- **Architecture.** The layer split exists (core/server/app logic in the package, views in the app target)
  and five dependency clients are in place, all with inert test values. The sharing layer (Keychain, shared
  keys, defaults), the haptics client and the motion vocabulary are complete.
- **Parity ledger.** `PARITY.md` marks only demonstrated behaviour as `done`. Store semantics are `done` for
  the four migration gates; `ifLet` ordering, cancellation identity and presentation dismissal are tested
  against representative compositions, not against a ported reducer tree, because no feature reducer exists yet.
- **Navigation.** The app currently switches between four launch states. The App → Home → Session store
  topology, `@Presents` children and page stack belong to P5–P7 and are not started.
- **Platform decisions.** Implementation decisions D-1…D-20 are recorded. Plan questions still open: `P-2`
  (transcript motion), `P-3` (text input), `P-4` (photo picking), `P-5` (glass), `P-9` (push). `P-7`
  (identifiers) is partially resolved: the Keychain service is application-defined and configurable (D-15), and
  production naming must be settled before real credentials are stored — it is not a blocker for core work.
  `DECISIONS.md` maps the two ID namespaces.
- **Previews.** Preview support is enabled, two launch-state previews exist, and the dependency context under
  Xcode previews resolves inert values, so a preview cannot reach the network and cannot play a haptic.

## Prerequisites before P4 (networking)

1. **PR for `ios-core` reviewed by the owner.** P4 branches from the updated `ios`, not from this task branch.
2. Nothing blocks on the code side. Production identifiers (bundle id, App Group, Keychain service) must be
   settled before real credentials are stored, but they do not block fixtures or transport work.
3. The haptics live path needs a physical device to observe; the vocabulary and the seam are verified without one.

P4 (networking) starts only after the P3 gate is green, or after the owner explicitly reorders the phases.
