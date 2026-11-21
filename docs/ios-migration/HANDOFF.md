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
  Head at Phase 4 start: `d0fdf2f5` (PR #2 merge).
- `ios-foundation` — the scaffold. Squash-merged into `ios` as `143d8f86` (PR #1, closed).
- `ios-core` — Phase 3 (tokens, motion, haptics, store gates). Merged into `ios` as `d0fdf2f5` (PR #2).
- `ios-networking` — Phase 4: transport, retry, models, SSE, pairing, client seam, plus the streaming
  review corrections. Draft PR into `ios`: https://github.com/Rift7/opencode-ios/pull/3 (**open for
  review, not merged**).
- Later task branches from `ios` (`ios-shell`, `ios-home`, …) are pushed to the fork and opened as **draft**
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
| Core logic (tokens, storage outcomes, logging, endpoint, network guard, isolation, transport boundary, haptics, motion, bounded channel) | `ios/OpenCodeKit/Tests/OpenCodeCoreTests` | `swift test` on the host |
| Server (address, redirects, transport, retry, pairing, SSE, events, batching, stream, client) | `ios/OpenCodeKit/Tests/OpenCodeServerTests` | `swift test` on the host |
| Loopback HTTP fixture (real URLSession delegates, socket lifetimes) | `ios/OpenCodeKit/Tests/OpenCodeServerTests/LocalFixtureServerTests.swift` | `swift test`; loopback only, opt-out env var |
| Live read-only server | `ios/OpenCodeKit/Tests/OpenCodeServerTests/LiveServerTests.swift` | `swift test` with env vars; skipped by default |
| App reducer, launch configuration, store semantics | `ios/OpenCodeKit/Tests/OpenCodeAppTests` | `swift test` on the host |
| Platform checks (UserDefaults, endpoint encoding, launch mapping) | `ios/OpenCodeTests` | `xcodebuild test` on the simulator |
| Launch smoke states | `ios/OpenCodeUITests` | `xcodebuild test` on the simulator |
| Keychain round-trip | `ios/OpenCodeUITests/KeychainProbeTests` | `xcodebuild test`; the hostless unit bundle has no keychain entitlement, so the probe runs in the app process behind `-uiTestKeychainProbe` |

The Xcode unit target is hostless and does not link TCA; see `TOOLCHAIN.md` for why, and for the keychain
entitlement note that puts the round-trip in the UI tests.

## Device and live checks (opt-in)

| Check | How |
| --- | --- |
| Loopback fixture suite | runs by default; skip with `OPENCODE_SKIP_LOOPBACK_FIXTURES=1` |
| Local-network prompt | install the debug app, launch with `-localNetworkProbeURL http://<mac-lan-ip>:<port>/api/info`, answer the prompt |
| Haptics | launch with `-hapticProbe`; System Haptics must be on and the phone in hand |
| Live server | set `OPENCODE_LIVE_SERVER` and `OPENCODE_LIVE_PASSWORD` for one test process only; unset afterwards |

The device probes print `OPENCODE_PROBE …` lines with a classification only: no address, credential,
message or file content.

## Test conventions

- Swift Testing for reducers, dependency clients, transport decoding, persistence and formatting.
- Every test uses a temporary directory, an in-memory Keychain double, a fixed clock and a deterministic ID
  generator. Storage failures are exercised with `FailingStorage`/`ScriptedKeychainOperations`, never by
  provoking a real keychain error. Reaching a real host is a failure; live checks are opt-in behind environment variables that are not
  set by default.
- Tests assert English copy for user-visible strings.

## Where the work stands

`PHASES.md` maps this repository onto the audit plan's P2–P14 numbering. P1–P4 are complete; P2 and P3 are
merged into `ios`, **P4 is on `ios-networking`** and awaits review. P5 (`ios-shell`) branches from the updated
`ios` after P4 merges.

What P4 added, in one paragraph: `OpenCodeClient` reads (`health`, `redeemPairing`, `projects`, session page,
one session, active IDs) plus the event stream; the `HTTPTransport` seam now carries `HTTPRequest`,
`HTTPResponse` and a chunked `HTTPStream` behind a live `URLSessionTransport` with origin-bound credentials
and a cleartext policy; `NetworkRetry` centralises the audited retry presets, classification and
`Retry-After`; `PairingLink` parses every audited form without contacting anything; `EventBatcher` coalesces
deltas and bounds delivery; `SSEParser` frames fragmented UTF-8; `EventStreamRunner` reconnects and stops on a
401. `docs/ios-migration/PROTOCOL_COVERAGE.md` is the route/event ledger.

Useful entry points:

| Need | File |
| --- | --- |
| Add a route | `OpenCodeServer/Client/OpenCodeClient.swift` (`Operations`), then its model under `Models/` |
| Understand a retry decision | `OpenCodeServer/Retry/RetryPolicy.swift` |
| Change event handling | `OpenCodeServer/Events/ServerEventDecoder.swift` |
| Test request construction | `OpenCodeServerTests/OpenCodeClientTests.swift` with `Fixtures.transport` |
| Inspect a live URLSession path | `OpenCodeCore/Transport/URLSessionTransport.swift` + `NetworkGuard` fixtures |
| Exercise real delegates and sockets | `OpenCodeTestSupport/LocalHTTPServer.swift`, `OpenCodeServerTests/LocalFixtureServerTests.swift` |
| Device probes (permission, haptics) | `ios/OpenCode/App/DeviceProbes.swift` |
| Live read-only server check | `OpenCodeServerTests/LiveServerTests.swift` |

Session and stream ownership (D-26/D-27): one request session per transport, one per stream connection;
every connection exit closes its tasks and session. The connect deadline covers response headers.

Device work (one iPhone Air, debug build, configured development identity):

- local-network prompt denied → `URLError -1009`, no request at the Mac fixture;
- reinstalled, prompt allowed → `status=200` from the Mac's LAN fixture;
- foreground haptics: first run nothing felt (System Haptics off), second run all eleven felt and
  distinct after enabling it. Reported as one-device observations, not automated results.

Live read-only smoke: `OPENCODE_LIVE_SERVER` + `OPENCODE_LIVE_PASSWORD` + `swift test --filter
LiveServerTests` passed against `opencode serve 0.0.0-dev-202611170722` for `/api/session`,
`/api/session/active` and `/api/event`. That snapshot serves its web shell for `/api/info` and
`/api/project`, so those routes were not exercised live; the audited fixture shapes remain their gate.

Known unverified items:

- `/api/info` and `/api/project` against a real V2 server (version mismatch above).
- Haptic feel beyond the one device; the local-network denial classification on other iOS versions.
- No live mutation was performed: the live suite is read-only by construction.

## Phase-end checklist

1. `scripts/verify.sh` passes.
2. No credential, server address, pairing code, message text or file content can reach a log — public log text
   carries only event names and numeric/boolean fields, free text is private, and the tests cover it.
3. `STATUS.md`, `PARITY.md`, `DECISIONS.md`, `HANDOFF.md` updated with completed behaviour, paths and the base SHA.
4. Screenshots, if any, are captured on a simulator with no personal data in frame and no machine identifiers in
   filenames.
5. Commit only files this phase owns; review the staged diff for personal information first.
