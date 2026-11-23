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
| P3 | Core: store, dependencies, sharing, tokens, logging, haptics | done — merged into `ios` as `d0fdf2f5` (PR #2) | checklist below |
| P4 | Server: transport, retry, models, SSE, pairing | done — merged into `ios` as `5f143ea7` (PR #3, tree `2326a49b`) | `PROTOCOL_COVERAGE.md`, `STATUS.md` |
| P5 | App shell: launch, connection, pairing, reconnect | done — merged into `ios` as `3b34932c` (PR #4) | `STATUS.md`, `PARITY.md` App shell, `ConnectionFeatureTests`, UI tests |
| P6 | Home, drawer, projects, Catch Up, What's New | done — merged into `ios` as `7966dcfe` (PR #5, tree `25b6d297`) | `STATUS.md` Phase 6, `PARITY.md` Home, `HomeFeatureTests`, 8 UI tests, screenshots, scroll trace |
| **P7** | **Session, subagents, background work, request review** | **done on `ios-session`** (draft PR) | `STATUS.md` Phase 7, `PARITY.md` Session, `SessionFeatureTests`, request-model and family tests, 5 UI tests, screenshots |
| P8 | Transcript | done — merged as `2823c06e` (PR #7); merged tree `1147dca8` equals reviewed head `5ea6ea65` | `STATUS.md` Phase 8, `PARITY.md` Transcript, 26 grouping/Markdown + 19 session + 11 decoding tests, 9 UI journeys, 2 scroll traces, 6 screenshots |
| **P9** | **Composer, drafts, sends, queue, request dock, quotes** | **done on `ios-composer`** (draft PR, base `ios`) | `STATUS.md` Phase 9, `PARITY.md` Composer, 10 composer + 14 session + 9 server tests, 10 UI journeys, typing traces, 10 screenshots |
| P10 | Media | not started | folders only; P9 attachment and cross-block quote boundaries recorded |
| P11 | Settings, experiments, diagnostics, onboarding | not started | folders only; P9 model/agent/mentions deferral recorded |
| P12 | System integrations | not started | folders only |
| P13 | Voice (Experimental, off) | not started | folders only |
| P14 | Hardening | not started | — |

**P2 is not P3.** The scaffold proves the project builds and the launch states exist; it does not prove store
semantics, sharing, motion or haptics. P3 is not P4: the core store and dependency layer exists, but no
server route was reached until P4 added the transport, retry, models, SSE parsing, pairing and client seam.

## P3 checklist

| Requirement (audit `PLAN.md` P3) | Status | Evidence or gap |
| --- | --- | --- |
| Dependency clients as `DependencyKey`s with inert test values | done | `DateClient`, `UuidClient` (`OpenCodeCore/Dependencies/FoundationClients.swift`), `PasteboardClient`, `SharedStore` (`.../Storage/SharedKeys.swift`), `NetworkPathClient` (`.../Network/NetworkPathClient.swift`), `HapticsClient` (`.../Haptics/HapticsClient.swift`), `HTTPTransport` (`.../Transport/HTTPTransport.swift`), `OpenCodeClient`; every key's test value is inert and `DependencyIsolationTests` fails a key that omits one |
| `Shared` storage, including Keychain | done | `UserDefaultsStorage`, `InMemoryStorage`, `KeychainStorage(service:operations:)`; `SharedStore` + `SharedKeys`; every operation returns an explicit outcome |
| Design tokens: colour | done | `Design/OpenCodeColorTokens.swift`; every token resolves and body/link text clears WCAG AA in both appearances |
| Design tokens: type | done | `Design/OpenCodeTypeTokens.swift`; system font, system monospaced for code/logs |
| Design tokens: radii, spacing | done | `Design/OpenCodeLayoutTokens.swift`; grid and radius scale are data, with a corner clamp; `LayoutTokenTests` |
| `MotionRole` equivalents | done | `Motion/OpenCodeMotion.swift`: fourteen roles, per-phase curves, Reduce Motion collapse, pose and stagger helpers; `MotionTests` |
| `AppLog` categories | done | `Logging/AppLog.swift` (`send`, `network`, `stream`, `voice`, `app`, `perf`) |
| Log privacy boundary | done | Public text is a `LogEvent` plus `LogField`s whose values are numbers and booleans only (`LogValue` has no string case), so a credential, address, path or message body cannot be published. Free-form text exists only as `LogPrivateField` and is emitted with private visibility, and no file outside `AppLog.swift` may log with public visibility (`LoggingTests`). |
| Haptics vocabulary | done | `Haptics/HapticsClient.swift`: eleven named haptics, platform-neutral feedback table, injectable client whose test value is inert; `HapticsTests` |
| Gate: path-indexed cancellation | done | `OpenCodeAppTests/StoreSemanticsTests.swift` (`PathIndexedCancellationTests`): one parent, two children, the same local cancellation id in both; stopping one child leaves its sibling ticking, then the sibling is cleaned up and the store finishes |
| Gate: `ifLet` child-first ordering | done | `StoreSemanticsTests` (`ChildFirstIfLetTests`) — the parent observes the child's post-reduction state |
| Gate: presented-child cancellation on dismissal | done | `StoreSemanticsTests` (`PresentedChildCancellationTests`) — dismissal and identity change both cancel; a clock advance after each receives nothing |
| Gate: Keychain round-trip | done | `KeychainProbeTests` runs it in the app process (a hostless test bundle has no keychain entitlement); `KeychainFailureTests` covers denied/unavailable/missing outcomes without a real keychain |
| Gate: every shared key's default | done | `SharedStoreTests` asserts each key's default, the registry's uniqueness and each key's storage routing |
| Gate: log privacy | done | structured boundary above; `AppLog` exposes no API that publishes arbitrary text |

The gate runs on the maintained TCA store (1.26.2, pinned). The compositions under test are this
migration's own representative shapes — a parent with a child `ifLet`, a presented sheet, a parent with two
independently scoped children, a worker with identified effects — not a re-test of TCA's suite. TCA's
documented semantics are adopted rather than reproduced: child-before-parent reduction, navigation-scoped
effect cancellation (including the same local id in two different paths staying independent), and dismissal
leaving the parent to clear the presented state.

## The categories named in the handoff

- **Architecture.** The layer split exists (core/server/app logic in the package, views in the app target)
  and five dependency clients are in place, all with inert test values. The sharing layer (Keychain, shared
  keys, defaults), the haptics client and the motion vocabulary are complete.
- **Parity ledger.** `PARITY.md` marks only demonstrated behaviour as `done`. Store semantics are `done` for
  the five migration gates; `ifLet` ordering, cancellation identity, path-indexed cancellation and presentation
  dismissal are tested against representative compositions, not against a ported reducer tree, because no
  feature reducer exists yet.
- **Navigation.** The app currently switches between four launch states. The App → Home → Session store
  topology, `@Presents` children and page stack belong to P5–P7 and are not started.
- **Platform decisions.** Implementation decisions D-1…D-69 are recorded. `P-3` (composer text input) is
  resolved by D-64: a focused `UITextView` bridge for selection, marked text and hardware Return. Plan questions
  still open: `P-2` (transcript motion), `P-4` (photo picking, P10), `P-5` (glass), `P-9` (push). `P-7`
  (identifiers) is partially resolved: the Keychain service is application-defined and configurable (D-15), and
  production naming must be settled before real credentials are stored — it is not a blocker for core work.
  `DECISIONS.md` maps the two ID namespaces.
- **Previews.** Preview support is enabled, two launch-state previews exist, and the dependency context under
  Xcode previews resolves inert values, so a preview cannot reach the network and cannot play a haptic.

## Roadmap after P7

P7 (Session) is complete on `ios-session`. It branched from `ios` at `7966dcfe`, the P6 squash merge;
the merged P6 tree is byte-identical to the reviewed `eff8b45f` tree (`25b6d297`), verified before work
started.

P7 consumes `SessionSelection(serverID, sessionID, intent)` from Home; the P6 placeholder is gone. The
session screen shows metadata, the run's Stop, subagent pages, permission/form review, pending inputs and
the shell/background panel. It deliberately does **not** render transcript rows or a composer.

P8 started from `origin/ios` at `92a7c677` (PR #6 merged; merged tree `e8e1db5b`, byte-identical to the
reviewed `56c10086`). The task branch is `ios-transcript`. It consumes `SessionRefresh.id`/`RefreshReason`
rather than adding a second read queue; transcript windows and settlement extend the same read plan (D-58).
The transcript target is `OpenCodeTranscript`; the UI lives in `ios/OpenCode/Transcript` (D-63).

P9 started from `origin/ios` at `2823c06e` after PR #7 merged; its tree `1147dca8` equaled the reviewed
`5ea6ea65`. The task branch is `ios-composer`.

1. P9 owns composer editing, drafts, sends, the queued-input sheet, the request dock and quote-to-composer.
2. `/api/experimental/session/{id}/wait` is now implemented in the send path with one retry owner.
3. P10 owns media, file opening, image/tool mosaics, the browser, math typesetting and Mermaid, plus the
   deferred composer attachment boundary.
4. P11 owns model/agent/mode pickers, autocomplete, mentions and commands.
5. Production identifiers, device VoiceOver/IME/selection, hardware keyboard and the local-network prompt still
   need the documented checks; they remain unverified.
