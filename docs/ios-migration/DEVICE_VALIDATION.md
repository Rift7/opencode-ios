# Physical-iPhone validation — Phase 12 device checklist

Status: **complete for the checks that a connected development iPhone and a local fixture can
answer**. Two checks remain blocked by hardware/fixture prerequisites, and real memory pressure was
not reproduced. This record keeps automated, manual, real-network, compatible-server and
simulator-only evidence separate.

## Base and head

| Item | Value |
| --- | --- |
| Integration base | `6681feed` (`origin/ios`, PR #10 squash merge) |
| Base tree | `b49d0917`, byte-identical to the corrected P11 head `d0fcee29`; `git diff d0fcee29 6681feed -- ios docs/ios-migration` is empty |
| Validation branch | `ios-device-validation`, created from updated `origin/ios` in a separate worktree |
| Final head | the branch head that carries this document and the one scanner fix |
| Android checkout | untouched |

## Environment

| Item | Value |
| --- | --- |
| Toolchain | Xcode 27.2 (27B52), Swift 6.4.2, iOS 27.2 SDK |
| Device | iPhone Air, **iOS 27.3 (24C5049f)** |
| Requested device OS | iOS 27.2 |
| Signing | owner-supplied Apple Development identity and existing team profile for the unchanged app bundle identifier |
| Build | Debug, signed for the device, installed in place without uninstalling the existing container |
| Fixture | disposable LAN HTTP/SSE fixture on a private port, synthetic project/session/skill data |

The phone is one minor version newer than the requested 27.2. No simulator was substituted and no
beta or OS change was installed. Checks whose applicability is clear across 27.2/27.3 were run;
the OS mismatch is recorded rather than hidden.

## Evidence categories

1. **Host package tests** — `swift test --package-path ios/OpenCodeKit`.
2. **Automated tests on the physical iPhone** — XCUITest with the app's deterministic in-app
   fixture; no socket.
3. **Device probes** — launch-argument probes in the signed app process (Keychain, saved-server
   restore, local-network transport, haptics).
4. **Manually observed physical-iPhone behaviour** — camera/QR, permission toggles, VoiceOver and
   IME feel/reading.
5. **Real LAN fixture/network behaviour** — actual sockets from the phone to a disposable local
   server, including auth, SSE and reconnect.
6. **Compatible-server read-only checks** — none run: no owner-configured production-like endpoint
   and credentials were supplied, and routes were not rewritten to force a match.
7. **Simulator-only regressions** — the P7–P11 simulator evidence remains simulator evidence and is
   not promoted to a device pass here.

## Results by category

| Run | Tests | Result |
| --- | --- | --- |
| Device core: Keychain, saved-server restore, launch states, preferences | 20 | 20 passed |
| Device feature journeys (Home, session, transcript, composer, media, settings) | 49 | 46 passed; 3 intermittent under the grouped run |
| Device real LAN, header persistence, unreachable hint | 2 | 2 passed (the unreachable assertion was corrected to the actual unreachable copy) |
| Device share-sheet presentation | 1 | sheet presented; the automated query could not see the system share-sheet process |
| Device performance traces | 6 | 6 passed |
| Device final affected suite after the fix | 12 | 12 passed |
| Host package suite | 628 | 628 passed on a clean full run of the follow-up code (626 at the initial device run; two new setup-scan tests) |

The three grouped-run failures were reproduced in isolation with two iterations each and passed
6/6:

- `ComposerUITests.testRelaunchRestoresAnUnsentDraft` relaunched into the real (empty) store rather
  than the injected fixture store; the failure snapshot showed `root-phase-disconnected` and
  “No server is configured yet”. This is a test-harness launch-environment race, not a product
  restoration failure.
- `ComposerUITests.testSendWhileRunningShowsQueuedInputsAndMovesDelivery` did not reach the session
  screen within 10 s.
- `ComposerUITests.testLongMultilineDraftScrollsInsideTheCap` did not insert the second edit after
  the scroll/tap on the device-sized composer.

They remain recorded as unresolved device-timing failures, not relabelled as fixed by the passing
reruns.

Two host package timing failures were also observed without being caused by this change:

- `HomeFeatureTests.lateDeleteResultIgnoredAfterVerification` failed once in a full run; it passed
  5/5 in isolation and in the clean full run.
- `BoundedChannelTests.waiterHandoff` failed in one full run and 5/5 in isolation; its exact
  `remaining` expectation depends on whether the consumer has already consumed the handed-off
  value. The clean full run passed.

## Checklist result

| # | Check | Status | Observation and evidence |
| --- | --- | --- | --- |
| 1 | Haptic vocabulary | passed | Debug probe played all eleven named haptics on the phone; the owner reported all distinct and `tap` lighter than `warning`/`error`. Probe printed one line per haptic and `done`; no identifiers or addresses. |
| 2 | Local-network denial | passed | Local Network was disabled for the app; relaunch produced **zero** fixture requests. The screen showed “Couldn’t reach the OpenCode server.” and the Local Network hint, with no false “permission denied” claim. |
| 3 | Local-network allow | passed | The transport probe reached the fixture; a manual server entry connected, Home loaded the synthetic project/sessions, and the SSE stream opened. |
| 4 | Real-socket foreground/background recovery | passed | The app was backgrounded by opening Settings, the fixture was stopped and restarted, then the app was reactivated in the **same process**: one `/api/info`, one `/api/project`, one session read and exactly one `/api/event` stream. Header persisted across the reconnect. |
| 5 | Camera permission denied | passed after fix | First build dismissed the full-screen scanner as soon as denial was reported, hiding the typed message. Fixed by keeping the scanner cover presented while `scanProblem` is non-nil (D-107). Rebuilt, reinstalled and retested: “Camera access is off for OpenCode…” with usable Done/Cancel, and Settings remained usable afterwards. |
| 6 | Camera restricted/unavailable | unverified | This phone has no restriction or missing camera that can be reproduced without changing device restrictions or enrolling the phone. |
| 7 | QR scan and confirmation | passed | A synthetic QR displayed on the Mac was captured by the real camera. The confirmation appeared **before** redemption (`/auth/connect` count = 0); tapping Pair produced exactly one redemption and one connection. The scanner stops after the first frame, so repeated frames did not redeem again. |
| 8 | Expired/used pairing code | passed | A second synthetic QR carried an expired code. Confirmation still appeared first; Pair produced one `401`, the typed “This pairing code expired or was already used…” copy, no new credentials and no disturbance to the existing connection. |
| 9 | Header persistence and Keychain | passed, with one unverified sub-check | Device Keychain probe added, read, updated, deleted and confirmed absence; saved-server probe restored a disposable server pair. A synthetic custom header survived termination/relaunch and was present on real LAN requests; it was not sent on a refused cross-origin redirect (observer received zero requests). A denied-Keychain write inside the signed app was not injected, so that failure-retention sub-check remains unverified. |
| 10 | Photo/file permission and provider eviction | blocked | Personal Photos/Files were deliberately not browsed or imported. Picker cancellation/import, permission states and provider eviction were not reproduced on a synthetic-only library; the synthetic paste path, staging, relaunch and annotation are covered by device UI tests. |
| 11 | Playback interruption | blocked | The repository has no synthetic video/audio fixture and no compatible server media; disconnecting headphones also needs owner participation. Viewer dismissal and share presentation were exercised instead. |
| 12 | Share presentation | passed (manual) | The native share sheet presented for a synthetic opened file; the shared payload was the synthetic file text. The automated assertion could not see the system share-sheet process, and no screenshot was retained because the sheet showed personal contact suggestions. |
| 13 | IME marked text and suggestions | passed | With a Japanese keyboard, `@rev` stayed underlined and **no suggestions appeared**; after 確定 the app issued the skill/file requests and the synthetic **Review** suggestion appeared and inserted. Editing before/after the mention chip preserved the typed text. |
| 14 | Hardware Shift+Return | blocked | No hardware keyboard is connected. |
| 15 | Keyboard dismissal and insets | passed | Device journeys for multiline input with Dynamic Type/dark mode, interactive dismissal, search-keyboard dismissal and detail sheets passed without draft loss. |
| 16 | VoiceOver reading order | passed (owner report) | VoiceOver was enabled on the device. The owner traversed Home, a session, Settings, the model/agent picker and suggestions and reported no unnamed or out-of-order controls; switch state and focus restoration worked. Automated labels alone were not used as the evidence. |
| 17 | Selection and scrolling | passed | Copy, quote hand-off, native selection, long-transcript scrolling, jump-to-latest and Dynamic Type AX L/XXXL journeys passed on device. At AX XXXL the Home header/project path truncates, but rows remain usable and nothing is dropped. |
| 18 | Memory pressure and device performance | partial | Frame times, hitches and memory were measured (below). A real OS memory-pressure event was not produced; the app's injected warning handler is unit/UI evidence only and is not described as an OS pressure pass. |
| 19 | Production identifiers and signing | passed for development | The signed development build launched, Keychain worked and credentials restored across relaunch. No production identifier, App Group, push entitlement or historical identifier was added; production configuration remains a release decision. |
| 20 | Push notifications | blocked | The feature is not implemented and is off; no relay or credentials exist. This run cannot make it pass. |

## Real LAN fixture

- Synthetic project, two synthetic sessions, one skill (`Review`) and one file suggestion; Basic
  auth on every API route; `/api/event` sends `server.connected` then keepalives.
- The fixture logged route templates, statuses, header **names**, query **names** and stream counts
  only. It never logged header values, query values, credentials, addresses or bodies.
- Observed: health → project → session/active → one SSE stream; header save reconnected once with
  the header present; termination/relaunch restored the server and header; Local Network denial
  produced zero requests; re-enabling and Try Again produced one fresh stream and a full re-read.
- A cross-origin redirect was refused: the observer origin recorded no request and the probe
  classified `crossOriginRedirect`.
- An initial “no autocomplete” observation was traced to the fixture returning bare arrays instead of
  the client's `{data: …}` envelopes. Fixing the fixture made the real LAN suggestion appear; this
  was tooling, not an app defect.

## Keychain and persistence

- `KeychainProbeTests` passed on the signed app: missing → write → read → update → read → delete →
  missing, using a disposable service.
- `SavedServerProbeTests` passed: a disposable two-server record was written, read back through the
  production restore path and removed.
- The real server and custom header persisted across app termination/relaunch, and the header was
  attached to the LAN origin after restoration.
- Cleanup: the owner removed the synthetic server entry through Settings; the owner's added Japanese
  keyboard was left in place as a user setting.

## Performance

All numbers are from the physical iPhone Air (iOS 27.3), Debug build. Frame probes are app-side
display-link samples; XCTest clock/memory metrics include the test driver's taps and waits.

| Trace | Configuration | Result |
| --- | --- | --- |
| Home drawer scroll | 300-session fixture, 3 iterations | 83.0–84.6 fps; 0 hitches; p50/p95/max 16.7 ms; 141–142 frames |
| Transcript long scroll | long synthetic transcript, 3 iterations | 78.1–84.6 fps; 5–11 hitches; hitch time 75–150 ms; p50 16.7 ms, p95 25–26 ms, max 33–39 ms |
| Transcript while streaming | streaming fixture, 3 iterations | 83.3–84.2 fps; 0–3 hitches; p50/p95 16.7 ms |
| Media-heavy transcript scroll | media fixture, 3 iterations | 82.9–84.1 fps; 1–3 hitches; p50/p95 16.7 ms |
| Large image open/close | 3 iterations | XCTest clock 5.27–5.30 s including UI-test waits; peak physical memory ≈18.2 MB |
| Typing latency | 900-entry fixture | 1195 ms from XCTest typing to state; main-thread turn 4.7/13.9/39 ms |
| Typing during streaming | streaming fixture | 864 ms end to end; main-thread turn 7.5/15.2/17 ms |
| Memory across traces | all scroll/open traces | peak physical ≈18.2–18.5 MB; no jetsam observed |

The earlier simulator measurements (including the ~2.0 s autocomplete trace) remain simulator
evidence and are not compared as equivalent.

## Failures, fixes and unresolved items

- **Fixed:** camera-denial scanner presentation. `SettingsFeature.State.isScanPresented` keeps the
  full-screen cover up while a typed problem is shown; `scanCancelled` clears both scanning and the
  problem. Regression tests cover denial presentation, problem dismissal and cancel. Rebuilt and
  verified on the phone.
- **Tooling only:** the real LAN fixture initially returned bare catalogue arrays and an invalid
  empty new-session payload, which produced a broken session and no suggestions. After correcting
  the fixture envelopes, suggestions and insertion worked. No app code was changed for this.
- **Unresolved device timing:** the three composer journeys above and the host Home/BoundedChannel
  timing tests are recorded, not hidden.
- **Blocked/unverified:** camera restriction, photo/file provider permissions and eviction, playback
  interruption, hardware Shift+Return, real memory pressure, denied-Keychain write injection and a
  compatible live-server read-only pass.

## Privacy

No device identifier, signing identity, server address, pairing code, credential, header value,
message body or file content is included in this document or its committed artifacts. Raw traces,
fixture logs, QR images and device screenshots remain outside the repository. Screenshots that
showed the home screen, personal contacts or the server address were deleted rather than committed.

## Owner review follow-ups

These came from the owner after the first device record was published. They are kept separate from
the checklist rows above.

- **Initial setup had no QR scan.** The disconnected screen offered manual entry and paste only; the
  scanner was reachable only inside Settings. Added a **Scan QR Code** button that presents Settings
  with a one-shot `scanOnOpen` flag, so the existing scanner, typed problems and confirmation flow
  are reused. Covered by `LaunchSmokeTests.testSetupScanShowsConfirmationWithoutRedeeming` and
  `SettingsFeatureTests.setupScanStartsOnOpen`; both passed on the device. The initial screen did
  not contact a server before confirmation.
- **“Couldn’t send message.” on an existing real-server session.** The observed screen was already
  showing a stopped/aborted run with one queued message; the app left the typed text in the
  composer. This was not reproduced against the synthetic fixture, and no additional paid prompt was
  sent to investigate. It is treated as an open product/server question, not a checklist pass or a
  validation fix. The server response status and whether a fresh session behaves differently are
  still needed.
- **Layered transcript text.** The observed frame showed a code block at a scrolled position under
  the translucent navigation bar, which can look doubled. It was not reproduced with synthetic
  content and is not classified as a defect without a reproducible case; a screenshot after
  scrolling away and back, or a synthetic transcript that shows the same overlap, would settle it.
