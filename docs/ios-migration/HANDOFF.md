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
  Head at Phase 5 start: `5f143ea7` (PR #3 merge).
- `ios-foundation` — the scaffold. Squash-merged into `ios` as `143d8f86` (PR #1, closed).
- `ios-core` — Phase 3 (tokens, motion, haptics, store gates). Merged into `ios` as `d0fdf2f5` (PR #2).
- `ios-networking` — Phase 4. Squash-merged into `ios` as `5f143ea7` (PR #3); the merged tree is
  byte-identical to `2326a49b`.
- `ios-shell` — Phase 5: launch, connection, pairing and reconnect. Draft PR into `ios`:
  https://github.com/Rift7/opencode-ios/pull/4
- Later task branches from `ios` (`ios-home`, …) are pushed to the fork and opened as **draft**
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

`scripts/verify.sh` checks the toolchain and runs `scripts/test.sh`, which stops on the first failure:

```sh
xcodegen generate
xcodebuild -project OpenCode.xcodeproj -scheme OpenCode \
  -destination '<derived simulator destination>' \
  -skipMacroValidation build
xcodebuild -project OpenCode.xcodeproj -scheme OpenCode \
  -destination '<derived simulator destination>' \
  -skipMacroValidation test          # OpenCodeTests + OpenCodeUITests
swift test --package-path OpenCodeKit
```

`destination.sh` derives the simulator from what is installed. `-skipMacroValidation` is scoped to the
build/test invocations in `test.sh`; see `TOOLCHAIN.md`. Do not add it to a global configuration or to
Xcode defaults.

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
| Live read-only server | `ios/OpenCodeKit/Tests/OpenCodeServerTests/LiveServerTests.swift` | `swift test` with env vars; skipped by default; records contract mismatches rather than hiding them |
| App reducer, connection child, launch scenarios, store semantics | `ios/OpenCodeKit/Tests/OpenCodeAppTests` | `swift test` on the host |
| Platform checks (UserDefaults, endpoint encoding, launch mapping) | `ios/OpenCodeTests` | `xcodebuild test` on the simulator |
| Launch, connection, pairing and failure UI | `ios/OpenCodeUITests` | `xcodebuild test` on the simulator |
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

`PHASES.md` maps this repository onto the audit plan's P2–P14 numbering. P1–P4 are merged into `ios`;
P5 (`ios-shell`) is implemented and ready for review. P6 starts from the updated `ios` after P5 merges.

What P5 added, in one paragraph: `AppFeature` restores the last server, saved list and a small project
cache from the Keychain/UserDefaults through explicit `AppRestoreResult` outcomes; unreadable saved
data is write-protected until a retry succeeds or the person explicitly replaces it; `ConnectionFeature`
races every address with `ServerLink`, refreshes `/api/project`, and owns one event stream with awaited
`EventStreamPhase` callbacks; every stream callback carries an attempt/stream token; one eligibility
gate keeps work out of the background and offline until the path returns; reconnection and overflow
re-read REST before the next socket; pasted and deep-linked pairing flows parse without network, with
deep links held behind a confirmation; and `RootView` renders the disconnected, connecting, loading,
connected, reconnecting, failure, storage and corrupt-data states from a String Catalog. Manual entry
works from both storage-error screens, and the resulting connection keeps a Replace warning.

Useful entry points:

| Need | File |
| --- | --- |
| App restore, form, pairing, persistence | `OpenCodeKit/Sources/OpenCodeApp/AppFeature.swift` (`AppFeature`) |
| Connection lifecycle and identity guards | same (`ConnectionFeature`, `ConnectionFeature.Token`, `canAttempt`) |
| Saved-data trust and explicit replacement | same (`SavedDataState`, `replaceSavedDataConfirmed`) |
| Address race | `OpenCodeKit/Sources/OpenCodeServer/Address/ServerLink.swift` |
| Network path and retry environment | `OpenCodeCore/Network/NetworkPathClient.swift`, `OpenCodeServer/Retry/NetworkPathRetry.swift` |
| Stream phases | `OpenCodeServer/Events/EventStream.swift` (`EventStreamPhase`) |
| Launch scenarios for UI tests | `OpenCodeApp/AppLaunchConfiguration.swift` |
| Connection UI and copy keys | `ios/OpenCode/App/RootView.swift`, `ios/OpenCode/Resources/Localizable.xcstrings` |
| Compatible fixture connection | `OpenCodeServerTests/LocalFixtureServerTests.compatibleFixtureConnection` |
| Device lifecycle fixture | `ios/OpenCode/App/UITestFixture.swift`, `OpenCodeUITests/ConnectionLifecycleUITests.swift` |
| Device Keychain restore probe | `ios/OpenCode/App/SavedServerProbe.swift`, `OpenCodeUITests/SavedServerProbeTests.swift` |

Session and stream ownership (D-26/D-27): one request session per transport, one per stream connection;
every connection exit closes its tasks and session. The connect deadline covers response headers.
Overflow protection clears only after healthy consumption, not on `server.connected` (D-29); the
transport's chunk buffer overflows into the same recoverable path (D-30); an HTML 2xx is an
`.incompatibleAPI` failure, distinct from auth and connectivity (D-31).

Device work (one iPhone Air, debug build, configured development identity):

- local-network prompt denied → `URLError -1009`, no request at the Mac fixture;
- reinstalled, prompt allowed → `status=200` from the Mac's LAN fixture;
- foreground haptics: first run nothing felt (System Haptics off), second run all eleven felt and
  distinct after enabling it. Reported as one-device observations, not automated results.

P5 device status: the existing local development identity (not recorded here) builds, signs, installs
and launches the app on the connected iPhone. `SavedServerProbeTests` reads two fake servers through
`AppRestoreResult` using a disposable Keychain service, and `ConnectionLifecycleUITests` runs the real
shell with a deterministic in-app client through connected → Home → activate → connected. Both pass on
the device. A real LAN server, the local-network prompt and a real socket's background/foreground
reconnect remain **unverified on hardware**.

Live read-only smoke: `OPENCODE_LIVE_SERVER` + `OPENCODE_LIVE_PASSWORD` + `swift test --filter
LiveServerTests` passed in P4 against `opencode serve 0.0.0-dev-202611170722` for `/api/session`,
`/api/session/active`, `/api/event`, and for the compatibility classification.

That build does not implement the audited `/api/info` and `/api/project`; unknown `/api/*` paths return
its web shell (200 `text/html`), and `/project` has a different shape. The cause is the server build's
route set, not auth (401 JSON works), prefix (`/api/session` works) or a proxy. The client does not
remap routes. A compatible server must serve `/api/info` (`{version,pid}`), `/api/project` (bare array
with `canonical`), `/api/session`, `/api/session/active` and `/api/event`; these requirements are in
`PROTOCOL_COVERAGE.md`.

Flaky test record: one first `verify.sh` run failed `BoundedChannelTests.waiterHandoff` on a 20 ms
timing assumption. The test was not changed; later green runs do not establish the cause, and P5 is
not claimed to have fixed it.

Known unverified items:

- `/api/info` and `/api/project` against a real V2 server (version mismatch above).
- A real LAN server on the device, the local-network prompt and a real socket's background/foreground
  reconnect. The device lifecycle check uses the deterministic in-app client.
- Haptic feel beyond the one device; the local-network denial classification on other iOS versions.
- Camera QR scanning, custom request headers and the copied error report (deferred in P5).
- No live mutation was performed: the live suite is read-only by construction.

## Phase-end checklist

1. `scripts/verify.sh` passes.
2. No credential, server address, pairing code, message text or file content can reach a log — public log text
   carries only event names and numeric/boolean fields, free text is private, and the tests cover it.
3. `STATUS.md`, `PARITY.md`, `DECISIONS.md`, `HANDOFF.md` updated with completed behaviour, paths and the base SHA.
4. Screenshots, if any, are captured on a simulator with no personal data in frame and no machine identifiers in
   filenames.
5. Commit only files this phase owns; review the staged diff for personal information first.
