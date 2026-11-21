# iOS migration — handoff

Everything here is repository-relative. Local paths are given as placeholders.

## Layout

| Path | Contents |
| --- | --- |
| `ios/` | native iPhone app (SwiftUI, Swift 6.4, iOS 27.2) |
| `ios/OpenCode/` | app target: entry point, scene, resources |
| `ios/OpenCodeKit/` | local Swift package with all logic and tests |
| `ios/OpenCodeShare/` | share extension (later phase) |
| `ios/OpenCodeWidgets/` | widget + Live Activity extension (later phase) |
| `ios/OpenCodeUITests/` | XCUITest (later phase) |
| `docs/ios-migration/` | status, parity, decisions, handoff, toolchain, audit copies |
| `docs/parity/` | the existing Android-side parity corpus — read-only reference, untouched |

The Android tree is not modified by this work.

## Branches

- `ios` — integration branch, base `7358160e808fb1870eeb20f5da8df832667019d1` (see `BASELINE.md`).
- `ios-foundation` — the scaffold: project generation, package targets, launch states, test isolation.
  Squash-merged into `ios` as `143d8f86` (PR #1, closed).
- `ios-core` — Phase 3: layout tokens, motion vocabulary, haptics client, store-semantics gates.
  Draft PR into `ios`: https://github.com/Rift7/opencode-ios/pull/2 (**open for review, not merged**).
- Later task branches from `ios` (`ios-networking`, `ios-shell`, …) are pushed to the fork and opened as **draft**
  PRs into `ios`. Nothing is merged, released or distributed from here.

## Prerequisites

- Xcode 27.2 with the iOS 27.2 SDK and simulator runtime.
- XcodeGen 2.48 (generates `ios/OpenCode.xcodeproj` from `ios/project.yml`; the generated project is not committed).
- No credentials, signing identity, App Group or push configuration is needed for simulator builds and tests.

## Build and test

```sh
cd ios
xcodegen generate
./scripts/verify.sh            # build for an iOS 27.2 simulator + package tests
```

`scripts/verify.sh` runs two commands and stops on the first failure:

```sh
xcodebuild -project OpenCode.xcodeproj -scheme OpenCode \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipMacroValidation build
swift test --package-path OpenCodeKit
```

`-skipMacroValidation` is scoped to that one invocation for this project; see `TOOLCHAIN.md`. Do not add it to a
global configuration or to Xcode defaults.

Package-only tests, without the app target:

```sh
swift test --package-path ios/OpenCodeKit
```

## Where tests run

| Suite | Location | Runner |
| --- | --- | --- |
| Core logic (tokens, storage outcomes, logging, endpoint, network guard, isolation, transport boundary, haptics, motion) | `ios/OpenCodeKit/Tests/OpenCodeCoreTests` | `swift test` on the host |
| App reducer, launch configuration, store semantics | `ios/OpenCodeKit/Tests/OpenCodeAppTests` | `swift test` on the host |
| Platform checks (UserDefaults, endpoint encoding, launch mapping) | `ios/OpenCodeTests` | `xcodebuild test` on the simulator |
| Launch smoke states | `ios/OpenCodeUITests` | `xcodebuild test` on the simulator |
| Keychain round-trip | `ios/OpenCodeUITests/KeychainProbeTests` | `xcodebuild test`; the hostless unit bundle has no keychain entitlement, so the probe runs in the app process behind `-uiTestKeychainProbe` |

The Xcode unit target is hostless and does not link TCA; see `TOOLCHAIN.md` for why, and for the keychain
entitlement note that puts the round-trip in the UI tests.

## Test conventions

- Swift Testing for reducers, dependency clients, transport decoding, persistence and formatting.
- Every test uses a temporary directory, an in-memory Keychain double, a fixed clock and a deterministic ID
  generator. Storage failures are exercised with `FailingStorage`/`ScriptedKeychainOperations`, never by
  provoking a real keychain error. Reaching a real host is a failure; live checks are opt-in behind environment variables that are not
  set by default.
- Tests assert English copy for user-visible strings.

## Where the work stands

`PHASES.md` maps this repository onto the audit plan's P2–P14 numbering. P2 is complete and merged into `ios`;
**P3 (core) is complete on `ios-core`** and awaits review. P4 (networking) starts only after P3 is merged or
the owner reorders the phases. Branch Phase 4 from the updated `ios`, not from `ios-core`.

What P3 added: spacing/radius tokens (`Design/OpenCodeLayoutTokens.swift`), the motion vocabulary and Reduce
Motion policy (`Motion/OpenCodeMotion.swift`), the haptics client (`Haptics/HapticsClient.swift`), and the four
store-semantics gates (`OpenCodeAppTests/StoreSemanticsTests.swift`).

Known unverified item: physical-device haptics. No device run was performed; the simulator has no Taptic
Engine. Do not record that as passing.

## Phase-end checklist

1. `scripts/verify.sh` passes.
2. No credential, server address, pairing code, message text or file content can reach a log — the redaction test
   covers it, and the Phase 3 additions log nothing at all.
3. `STATUS.md`, `PARITY.md`, `DECISIONS.md`, `HANDOFF.md` updated with completed behaviour, paths and the base SHA.
4. Screenshots, if any, are captured on a simulator with no personal data in frame and no machine identifiers in
   filenames.
5. Commit only files this phase owns; review the staged diff for personal information first.
