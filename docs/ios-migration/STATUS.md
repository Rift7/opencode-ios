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

See `BASELINE.md` for the branch-creation evidence and the refresh check.

## Phase status

| Phase | Scope | Status |
| --- | --- | --- |
| 1 | Read-only reconstruction audit | complete (`docs/ios-migration/audit/`) |
| 2 | `ios` branch, baseline record, scaffold and gate | complete on `ios-foundation`; PR #1 open, **not merged** |
| 3 | Core: store, dependencies, sharing, tokens, logging, haptics | **partial** — radii/spacing, motion, haptics and the store-semantics tests remain; see `PHASES.md` |
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

## Verified in this phase

Toolchain: Xcode 27.2 (27B52), Swift 6.4.2, iOS simulator SDK 27.2, macOS 27.2.1 arm64. Simulator:
iPhone 18 Pro Max on iOS 27.2, derived from installed devices (`OPENCODE_SIM_NAME` unset).

| Gate | Command | Result |
| --- | --- | --- |
| Toolchain | `ios/scripts/env.sh` | Xcode 27.2, Swift 6.4.2, SDK 27.2 |
| Scheme discoverable | `xcodebuild -project OpenCode.xcodeproj -list` | `OpenCode` present (plus package schemes) |
| Dependencies resolve | `xcodebuild … -resolvePackageDependencies` | TCA 1.26.2 and transitive pins resolved |
| Simulator build | `xcodebuild … -destination <derived> -skipMacroValidation build` | `BUILD SUCCEEDED` |
| Dependency isolation | `swift test --package-path OpenCodeKit` | isolated environments, deterministic ids, network guard, transport boundary |
| Transport boundary | `OpenCodeCoreTests/TransportBoundaryTests` | unoverridden test dependency throws `blocked`; no source owns a `URLSession` |
| App unit tests | `xcodebuild … -only-testing:OpenCodeTests test` | 3 tests pass |
| Launch smoke | `xcodebuild … -only-testing:OpenCodeUITests test` | 3 tests pass (disconnected, failed, loading) |
| Keychain round-trip | `… -only-testing:OpenCodeUITests/KeychainProbeTests` | add, read, update, remove pass in the app process |
| Previews | `#Preview` in `RootView.swift` | compiles with the app target; dependency context is inert |
| Full gate | `ios/scripts/verify.sh` | passes; logs in `ios/.build-results/` |

The scaffold launches into explicit disconnected, loading, failed and connected states. The live connection
probe is inert (`notConfigured`) and never touches the network, so first launch cannot contact anything.

This phase verified the build, the launch states, tokens, redaction and test isolation. It did **not** verify
reconstructed reducer ordering, cancellation identity, presentation semantics, sharing, motion or haptics; those
are Phase 3 items (`PHASES.md`).

## Not verified

- Device-only paths: camera QR scanning, haptics, audio, push.
- Signing identity, App Group, Keychain service: none configured; simulator builds need none.
- Live server behaviour: no live check was run; the transport phase adds it behind opt-in variables.
- Visual comparison with the original app: unavailable; October screenshots are evidence, not a pixel target.

## Next

1. **Merge PR #1 into `ios`** (owner), then branch the next task from the updated `ios`.
2. Finish Phase 3 on that branch: radii/spacing tokens, motion vocabulary, haptics client, and the
   store-semantics tests (cancellation, child-first `ifLet`, presentation dismissal). Keychain and shared-key
   defaults are implemented and tested.
3. Only then `ios-networking` (Phase 4): transport, retry, wire models, SSE, pairing, with fixtures and opt-in
   live checks.
