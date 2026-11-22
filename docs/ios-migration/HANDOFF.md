# iOS migration — handoff

Everything here is repository-relative. Local paths are given as placeholders.

## Layout

| Path | Contents |
| --- | --- |
| `ios/` | native iPhone app (SwiftUI, Swift 6.4, iOS 27.2) |
| `ios/OpenCode/` | app target: entry point, scene, Home drawer, session screen, resources |
| `ios/OpenCodeKit/` | local Swift package with all logic and tests (`OpenCodeCore`, `OpenCodeServer`, `OpenCodeDrawer`, `OpenCodeSession`, `OpenCodeApp`) |
| `ios/OpenCodeShare/` | share extension (later phase) |
| `ios/OpenCodeWidgets/` | widget + Live Activity extension (later phase) |
| `ios/OpenCodeUITests/` | XCUITest: launch, Home, session, screenshots, probes |
| `docs/ios-migration/` | status, parity, decisions, handoff, toolchain, audit copies |
| `docs/parity/` | the existing Android-side parity corpus — read-only reference, untouched |

The Android tree is not modified by this work.

## Branches

- `ios` — integration branch, base `7358160e808fb1870eeb20f5da8df832667019d1` (see `BASELINE.md`).
  Head at Phase 7 start: `7966dcfe` (PR #5 merge).
- `ios-foundation` — the scaffold. Squash-merged into `ios` as `143d8f86` (PR #1, closed).
- `ios-core` — Phase 3 (tokens, motion, haptics, store gates). Merged into `ios` as `d0fdf2f5` (PR #2).
- `ios-networking` — Phase 4. Squash-merged into `ios` as `5f143ea7` (PR #3); the merged tree is
  byte-identical to `2326a49b`.
- `ios-shell` — Phase 5: launch, connection, pairing and reconnect; review corrections at `04da03cf`.
  Merged into `ios` as `3b34932c` (PR #4).
- `ios-home` — Phase 6: Home, drawer, projects, Catch Up and What's New. Merged into `ios` as
  `7966dcfe` (PR #5); the merged tree is identical to `eff8b45f`.
- `ios-session` — Phase 7: session, subagents, background work and request review. Branched from
  `origin/ios` `7966dcfe`; draft PR into `ios`: https://github.com/Rift7/opencode-ios/pull/6
- Later task branches from `ios` are pushed to the fork and opened as **draft** PRs into `ios`. Nothing is
  merged, released or distributed from here.

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

P8 surfaces:

```sh
xcodebuild -project ios/OpenCode.xcodeproj -scheme OpenCode \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro Max' -skipMacroValidation \
  -only-testing:OpenCodeUITests/TranscriptUITests test
xcodebuild -project ios/OpenCode.xcodeproj -scheme OpenCode \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro Max' -skipMacroValidation \
  -only-testing:OpenCodeUITests/TranscriptScrollTraceUITests test
```

The fixture modes `connected-transcript-long`, `connected-transcript-older` and
`connected-transcript-stream` are synthetic and never open a socket.

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

## Transcript (P8)

- `SessionFeature` owns one authoritative read; the transcript is part of it. Older history has
  session + generation + cursor fencing. Do not add a second transcript refresh queue.
- Grouping and projection are pure (`OpenCodeTranscript`). The view renders values and sends actions; it
  does not parse Markdown in a `body` getter.
- Markdown parses off the main actor into `MarkdownBlockCache` (256 entries / 4 MiB, cleared on memory
  warning). Remote images and links are inert until the person confirms; no web view.
- The list is a SwiftUI `ScrollView` + `LazyVStack`. Do not reintroduce the UIKit follower, send flights or
  row growth. Following survives tail height changes while the reader was at the end; only a reader drag
  stops it, and browsing never re-pins. Reduce Motion replaces the jump glide with the shared reduced fade.
- Markdown publication carries a revision. A newer text or a disappeared row fences every older parse;
  `MarkdownBlockPresenter` is the only publisher and the cache stays bounded. Do not assign parse results
  straight into view state.
- Events racing a read are replayed up to 512 batches. Crossing the bound is explicit: the partial replay is
  discarded, `racedEventsIncomplete` is set, and the refresh coordinator performs one authoritative re-read.
  Do not silently drop, truncate, or raise the buffer without changing that policy and its tests.
- Media, file opening, math/Mermaid typesetting and composer quote actions belong to P9/P10.

## Test conventions

- Swift Testing for reducers, dependency clients, transport decoding, persistence and formatting.
- Every test uses a temporary directory, an in-memory Keychain double, a fixed clock and a deterministic ID
  generator. Storage failures are exercised with `FailingStorage`/`ScriptedKeychainOperations`, never by
  provoking a real keychain error. Reaching a real host is a failure; live checks are opt-in behind environment variables that are not
  set by default.
- Tests assert English copy for user-visible strings.

## Where the work stands

`PHASES.md` maps this repository onto the audit plan's P2–P14 numbering. P1–P7 are merged into `ios`
(P7 as `92a7c677`). P8 is implemented on `ios-transcript` (draft PR #7; corrections at `4c2ecd7d`); the composer is P9. The transcript's
state boundaries are P7's refresh identity plus P8's per-session `TranscriptState`.

What P6 added, in one paragraph: `HomeFeature` replaces the project-only connected destination with the
authenticated Home — projects, the drawer's pinned/recent session lists, 50-session paging, local and
server search, pins, unread/read state, attention/running dots, server switcher, delete-with-backup, Catch
Up cards with Mark Read/Keep Unread/Undo and an All Caught Up finish, and a What's New row whose seen state
persists. A versioned, bounded per-server Home snapshot (v1, 8 servers × 50 sessions) replaces the P5
project-summary cache; the shell still owns the only event stream and forwards session events to Home.
Session rows hand a stable `SessionSelection(serverID, sessionID, intent)` to the app, which renders a
labeled placeholder until P7.

What P7 added, in one paragraph: the session destination now consumes `SessionSelection` and owns the
run's Stop, the family's subagent pages, permission/form review, pending steering rows and the
shell/background panel. One authoritative read carries the audited refresh reasons, a request ID, one
follow-up and replayed raced events; Stop resolves ambiguous failures by reading the run and the inbox
before retrying, and a resumed run is a success. The family walk is bounded and cycle-safe; requests use
strict models, typed validation and read-back settlement; shells tail bounded output and drain before
stop. Mark All fans receipts out to unread Home rows only. The transcript is P8; composer editing and sends are P9.

Useful entry points:

| Need | File |
| --- | --- |
| Home reducer, local keys, search/paging, deletion, Catch Up, What's New | `OpenCodeKit/Sources/OpenCodeDrawer/HomeFeature.swift` |
| Home models, snapshot store, keys, catalogue, selection | `OpenCodeKit/Sources/OpenCodeDrawer/HomeModels.swift` |
| App ↔ Home ownership, connection delegates, server switch | `OpenCodeKit/Sources/OpenCodeApp/AppFeature.swift` |
| Home/drawer/projects/Catch Up/What's New UI | `ios/OpenCode/Drawer/HomeView.swift` |
| Session reducer: refresh, Stop, family pages, requests, shells | `OpenCodeKit/Sources/OpenCodeSession/SessionFeature.swift` |
| Session models: problems, refresh, requests, background, shell output | `OpenCodeKit/Sources/OpenCodeSession/SessionModels.swift` |
| Session screen, subagents, request sheet, background/output sheets | `ios/OpenCode/Session/SessionView.swift` |
| App ↔ Home ↔ Session ownership | `OpenCodeKit/Sources/OpenCodeApp/AppFeature.swift` |
| Request/family/shell wire models | `OpenCodeKit/Sources/OpenCodeServer/Models/{RequestModels,SessionModels}.swift` |
| New client operations | `OpenCodeKit/Sources/OpenCodeServer/Client/SessionOperations.swift` |
| Mark All receipts | `OpenCodeKit/Sources/OpenCodeDrawer/HomeFeature.swift`; drawer menu in `ios/OpenCode/Drawer/HomeView.swift` |
| Client read receipt, delete, attention | `OpenCodeKit/Sources/OpenCodeServer/Client/OpenCodeClient.swift` |
| Fixture sessions and scroll fixture | `ios/OpenCode/App/UITestFixture.swift` |
| UI journeys | `ios/OpenCodeUITests/{HomeUITests,SessionUITests}.swift` |
| Reviewed boundary regressions | `OpenCodeKit/Tests/OpenCodeAppTests/AppFeatureTests.swift` (`sessionEventForwarding`), `OpenCodeSessionTests/SessionFeatureTests.swift` (family identity, uncached load, shell poll/range/drain) |
| Screenshots and scroll trace | `ios/OpenCodeUITests/{HomeScreenshotUITests,SessionScreenshotUITests,HomeScrollTraceUITests}.swift` |
| Debug frame probe | `ios/OpenCode/Drawer/ScrollFrameProbe.swift` |

### P7 evidence

- `swift test --package-path ios/OpenCodeKit`: see `STATUS.md` for the gate count (server, core, app,
  drawer and session suites). Session has 25 reducer tests; requests 6 model tests; family 4 tests;
  App has the stream-forwarding integration test; Session UI has 6 journeys including shell stop.
- `ios/scripts/verify.sh`: app build, `OpenCodeTests`, 31 UI tests and package tests pass.
- `SessionUITests`: session/subagent navigation, permission approval, form validation/submission and a
  failed reply retry.
- Screenshots: `docs/ios-migration/screens/p7-{session,request,background}[-dark].png`.
- The form UI test exposed a latent off-main dynamic-colour crash; `OpenCodeColors.color` is nonisolated
  (D-56) and the full UI suite passes with the sheet rendered.

### P6 evidence

- `swift test --package-path ios/OpenCodeKit`: 321 tests (161 server, 67 core, 58 app, 35 drawer).
- `ios/scripts/verify.sh`: 26 UI tests pass, including 8 P6 tests; app build and `OpenCodeTests` pass.
- Screenshots: `docs/ios-migration/screens/p6-{home,drawer,catch-up}[-dark].png`.
- Review corrections: paging retries, receipt-only watermarks, targeted deletion verification/tombstones (never first-page absence), connection live gating and cold attention resolution are covered by the deterministic regressions named in `STATUS.md`.
- Scroll trace: 300-session fixture, iPhone 18 Pro Max simulator (iOS 27.2), 141–142 frames per
  iteration, p50/p95 16.7 ms, one 33.3 ms frame, deceleration 2.428 s average. Simulator measurement only.

## Deferred P5 items — owner, phase and check

| Item | Phase | Acceptance check |
| --- | --- | --- |
| Camera QR pairing | P11 | Device scan of a valid `opencode pair` code reaches the confirmation and redeems once; denied camera is a typed outcome. Simulator unverified. |
| Custom headers | P11 | Keychain round-trip; headers apply only to their server's origins; an invalid header is refused without locking out. |
| Copied error report | P11 | Copy contains typed facts only; redaction test fails on credentials/addresses/pairing codes/message text. |
| Haptics feel | P14 | Eleven haptics felt and distinguished on hardware; simulator unverified. |
| Local-network prompt / real socket | P14 | Denied prompt → no fixture request and unreachable copy; allowed → fixture request; real background/foreground socket reconnect. |
| Production identifiers (bundle/team/App Group/Keychain) | P12/P14 | Owner-supplied identity builds and signs; credentials persist across relaunch; no historical values copied. |
| Push notifications | P12 | Relay + credentials exist and the feature defaults off; without them, blocked/unverified. |
| Composer and quote intent | P9 | P8 renders transcript rows and quote cards; P9 consumes selection as a quote and owns drafts/sends. |

## Phase-end checklist

1. `scripts/verify.sh` passes.
2. No credential, server address, pairing code, message text or file content can reach a log — public log text
   carries only event names and numeric/boolean fields, free text is private, and the tests cover it.
3. `STATUS.md`, `PARITY.md`, `DECISIONS.md`, `HANDOFF.md` updated with completed behaviour, paths and the base SHA.
4. Screenshots, if any, are captured on a simulator with no personal data in frame and no machine identifiers in
   filenames.
5. Commit only files this phase owns; review the staged diff for personal information first.
