# iOS migration — status

## Baseline

| Item | Value |
| --- | --- |
| Integration branch | `ios` |
| Base commit | `7358160e808fb1870eeb20f5da8df832667019d1` (`origin/dev`, branch `dev`) |
| Base commit subject | `chore(deps): update Compose to 1.13 (#265)` |
| Verified against | audit of 2026-11-21 (`docs/ios-migration/audit/AUDIT.md`) |
| Remote `dev` at branch creation | same SHA — no intervening changes to audit |
| `ios` head when Phase 3 started | `143d8f86687b49c053f92bd7c36b69f6c3e21457` (PR #1, squash-merged into `ios`) |
| Phase 3 branch | `ios-core`, created from that `ios` head |
| Worktree | `<migration-worktree>` (the Android checkout at `<repository-root>` is untouched) |

See `BASELINE.md` for the branch-creation evidence and the refresh check.

## Phase status

| Phase | Scope | Status |
| --- | --- | --- |
| 1 | Read-only reconstruction audit | complete (`docs/ios-migration/audit/`) |
| 2 | `ios` branch, baseline record, scaffold and gate | complete — merged into `ios` as `143d8f86` (PR #1) |
| 3 | Core: store, dependencies, sharing, tokens, logging, haptics | complete on `ios-core` — draft PR open, not merged |
| 4 | Server: transport, retry, models, SSE, pairing | not started (address validation and an inert transport seam only) |
| 5 | App shell: launch, connection, pairing, reconnect | scaffold only |
| 6 | Home, drawer, projects, Catch Up, What's New | not started |
| 7 | Session, subagents, background work, request review | not started |
| 8 | Transcript | not started |
| 9 | Composer | not started |
| 10 | Media | not started |
| 11 | Settings, experiments, diagnostics, onboarding | not started |
| 12 | System integrations | not started |
| 13 | Voice (Experimental, off) | not started |
| 14 | Hardening | not started |

## Phase 3 — what landed

| Area | New path | Gate |
| --- | --- | --- |
| Spacing and radius tokens | `ios/OpenCodeKit/Sources/OpenCodeCore/Design/OpenCodeLayoutTokens.swift` | `OpenCodeCoreTests/LayoutTokenTests.swift` |
| Motion vocabulary and Reduce Motion | `ios/OpenCodeKit/Sources/OpenCodeCore/Motion/OpenCodeMotion.swift` | `OpenCodeCoreTests/MotionTests.swift` |
| Haptics vocabulary and injectable client | `ios/OpenCodeKit/Sources/OpenCodeCore/Haptics/HapticsClient.swift` | `OpenCodeCoreTests/HapticsTests.swift` |
| Dependency-key test values | (all five keys) | `OpenCodeCoreTests/DependencyIsolationTests.swift` |
| Shared-key defaults and storage routing | `.../Storage/SharedKeys.swift` (`SharedStorage` becomes `Equatable`) | `OpenCodeCoreTests/SharedStoreTests.swift` |
| Store semantics | — | `OpenCodeAppTests/StoreSemanticsTests.swift` |

Values and their freshness (all compared against `dev` at `7358160e`, nothing superseded):

| New token | Android source (`dev`) | File last changed | Treatment |
| --- | --- | --- | --- |
| Spacing grid, radius scale, corner clamp | `core/src/main/kotlin/ai/opencode/core/ui/OpenCodeShapes.kt` | `f79a895e`, 2026-11-14 | values adopted as native point tokens (D-17) |
| Fourteen motion roles, curves, reduce-motion collapse | `core/src/main/kotlin/ai/opencode/core/motion/{MotionRole,MotionConstants,MotionReduce}.kt` | `cd3cbffa` / `583487e7`, 2026-11-18 | vocabulary adopted; SwiftUI curve mapping is a native decision (D-18) |
| Eleven haptics and their feels | `core/src/main/kotlin/ai/opencode/core/haptics/HapticsClient.kt` | `f79a895e`, 2026-11-14 | vocabulary adopted; UIKit generator mapping is a native decision (D-19) |
| Store ordering, cancellation, presentation | `core/src/main/kotlin/ai/opencode/core/store/{Reducer,Effect}.kt` | `583487e7`, 2026-11-18 | semantics adopted through maintained TCA (D-20) |

No recovered iOS source file exists in this repository for these four areas, so none of the values is
labelled a port. The audit's iOS dossier is cited where it exists; these are native design decisions that
carry the current `dev` behaviour.

## Verified in this phase

Toolchain: Xcode 27.2 (27B52), Swift 6.4.2, iOS simulator SDK 27.2, macOS 27.2.1 arm64. Simulator:
iPhone 18 Pro Max on iOS 27.2, derived from installed devices (`OPENCODE_SIM_NAME` unset).

| Gate | Command | Result |
| --- | --- | --- |
| Toolchain | `ios/scripts/env.sh` | Xcode 27.2, Swift 6.4.2, SDK 27.2 |
| Package build (host) | `swift build --package-path ios/OpenCodeKit` | succeeds |
| Focused suites | `swift test --package-path ios/OpenCodeKit --filter <suite>` | layout, motion, haptics, dependencies, store semantics, path-indexed cancellation pass |
| Package tests | `swift test --package-path ios/OpenCodeKit` | 61 core tests in 13 suites, 14 app tests in 7 suites; all pass |
| App build | `xcodebuild … -skipMacroValidation build` | `BUILD SUCCEEDED` (compiles the UIKit haptics path) |
| App unit tests | `xcodebuild … -only-testing:OpenCodeTests test` | 3 tests pass |
| Launch smoke | `xcodebuild … -only-testing:OpenCodeUITests test` | 4 tests pass (disconnected, failed, loading, Keychain probe) |
| Full gate | `ios/scripts/verify.sh` | passes; logs in `ios/.build-results/` |

Semantics proven by `StoreSemanticsTests`: sibling reducer order over one action; `.concatenate` effect
ordering; cancellation by identity (one id cancels, another keeps running; restarting an id cancels the
in-flight effect); child-before-parent `ifLet` reduction; presented-child effects cancelled on dismissal
and on identity change, with a clock advance after each receiving nothing.

The path-indexed acceptance check (`PathIndexedCancellationTests`) is one parent with two optional children
of the same reducer, both using the local cancellation id `"ticker"` through TCA's `.cancellable`/`.cancel`.
On a `TestClock` both start and both tick; stopping the primary child leaves the secondary ticking for two
more intervals; the secondary is then dismissed and `store.finish()` confirms no effect is left in flight.
The check was verified non-vacuous by temporarily removing the child's `.cancel`: the run then failed with
the stopped child's ticks arriving, so the assertion is testing the cancellation rather than an idle timer.

## Not verified

- **Physical-device haptics.** No generator was observed on hardware. The vocabulary, the feedback table and
  the injectable seam are verified; whether the feels are right on a device is an owner check. Reported as
  unverified, never passed.
- Simulator haptics: the simulator has no Taptic Engine, so the live path is compiled and guarded by
  `applicationState == .active` but not exercised.
- Device-only paths: camera QR scanning, audio, push.
- Signing identity, App Group, Keychain service: none configured; simulator builds need none.
- Live server behaviour: no live check was run; the transport phase adds it behind opt-in variables.
- Visual comparison with the original app: unavailable; October screenshots are evidence, not a pixel target.
  The motion vocabulary is data; no screen animates yet, so there is nothing to compare.

## Next

1. **Review the `ios-core` draft PR** (owner), then branch Phase 4 from the updated `ios`.
2. Phase 4 (`ios-networking`): transport behind `HTTPTransport`, retry, wire models, SSE batching, pairing,
   with fixtures on `.invalid` hosts and live checks behind opt-in environment variables.
3. Phase 5 (`ios-shell`): launch, connection, pairing and reconnect on top of the real transport.
