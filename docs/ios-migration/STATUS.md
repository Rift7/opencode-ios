# iOS migration — status

## Baseline

| Item | Value |
| --- | --- |
| Integration branch | `ios` |
| Behaviour baseline | `7358160e808fb1870eeb20f5da8df832667019d1` (`origin/dev`) |
| `ios` head when P6 started | `3b34932c8c3d1e7dcc9f4985264bcec49ec64782` (PR #4) |
| P6 branch | `ios-home`, created from `origin/ios` after `git fetch origin` |
| Worktree | a separate worktree; the Android checkout and unrelated branches are untouched |

`git fetch origin` moved `origin/ios` from `5f143ea7` to `3b34932c`. PR #4 (`ios: wire launch,
connection, pairing and reconnect`) is **MERGED** (`mergedAt=2026-11-22T04:08:50Z`, merge commit
`3b34932c`, base `ios`, head `ios-shell`). The review correction `e64c1154` (“word the saved-data
warning for a connecting server”) is not an ancestor because the merge was squashed; its copy is present
in `origin/ios:ios/OpenCode/Resources/Localizable.xcstrings`, and the gate was checked before any P6 work.

## Phase status

| Phase | Scope | Status |
| --- | --- | --- |
| 1 | Read-only reconstruction audit | complete (`docs/ios-migration/audit/`) |
| 2 | `ios` branch, baseline, scaffold and gate | complete — `143d8f86` (PR #1) |
| 3 | Core: store, dependencies, sharing, tokens, logging, haptics | complete — `d0fdf2f5` (PR #2) |
| 4 | Server: transport, retry, models, SSE, pairing | complete — `5f143ea7` (PR #3, tree `2326a49b`) |
| 5 | App shell: launch, connection, pairing, reconnect | complete — `3b34932c` (PR #4) |
| 6 | Home, drawer, projects, Catch Up, What's New | **complete on `ios-home`** (draft PR #5) |
| 7 | Session, subagents, background work, request review | not started |
| 8 | Transcript | not started |
| 9 | Composer | not started |
| 10 | Media | not started |
| 11 | Settings, experiments, diagnostics, onboarding | not started |
| 12 | System integrations | not started |
| 13 | Voice (Experimental, off) | not started |
| 14 | Hardening | not started |

## Phase 6 — what landed

| Area | New or changed path | Gate |
| --- | --- | --- |
| Home reducer, local records, search/paging, pins, read state, deletion, Catch Up, What's New | `OpenCodeKit/Sources/OpenCodeDrawer/HomeFeature.swift` | `HomeFeatureTests` — 18 Swift Testing cases (pin/unpin, unread, server isolation, visibility, search, stale search, paging, stale refresh, delete failure, Catch Up, supersede, What's New, snapshot bounds, receipt failure) |
| Home models, server-scoped keys, bounded/versioned snapshot store, What's New catalog | `.../OpenCodeDrawer/HomeModels.swift` | snapshot write/read, version rejection, server separation and legacy-cache removal tested |
| Client read receipt, delete, attention read | `OpenCodeKit/Sources/OpenCodeServer/Client/OpenCodeClient.swift` | `OpenCodeClientTests` request shape; Home effect tests for success and failure |
| First-page request | `OpenCodeKit/Sources/OpenCodeServer/Models/OpenCodeSession.swift` (`SessionPageRequest.first`) | `OpenCodeClientTests` |
| Stream forwarding to Home without a second stream | `.../OpenCodeApp/AppFeature.swift` (`ConnectionFeature.Delegate.sessionEvent`, `.resynchronized`) | `ConnectionFeatureTests` order; App switch test |
| App → Home → Session ownership | same (`AppFeature.home`, `sessionDestination`); `OpenCode/Drawer/HomeView.swift`; `OpenCode/App/RootView.swift` (`SessionPlaceholderView`) | `AppFeatureTests.homeServerSwitch`; UI journey opens a session selection |
| Native drawer, project rows, rows with status dots, server switcher, What's New page | `ios/OpenCode/Drawer/HomeView.swift` | `HomeUITests` + screenshots |
| Catch Up card interaction, mark/keep/undo, finish row | same (`CatchUpView`); `HomeFeature` (`catchUpFinished`) | unit + UI tests; the last card closes Catch Up onto the drawer's **All Caught Up** row, as audited |
| Deterministic fixture sessions and second server | `ios/OpenCode/App/UITestFixture.swift` | UI tests use the fixture only; no socket |
| Debug frame probe for the scroll trace | `ios/OpenCode/Drawer/ScrollFrameProbe.swift` | DEBUG-only `CADisplayLink`; exposes an accessibility label read by the trace test |
| Copy, including What's New entries | `ios/OpenCode/Resources/Localizable.xcstrings` | UI tests assert English text |
| UI automation | `ios/OpenCodeUITests/{HomeUITests,HomeScreenshotUITests,HomeScrollTraceUITests}.swift` | 8 tests: drawer search/select, server switch, Catch Up, Dynamic Type, accessibility/keyboard, What's New, screenshots, scroll trace |
| Screenshots | `docs/ios-migration/screens/p6-{home,drawer,catch-up}[-dark].png` | light and dark, iPhone 18 Pro Max simulator, synthetic data only |

### Authoritative refresh and identity

- `HomeFeature.Refresh` reads `SessionPageRequest.first` (50 roots) and `/api/session/active` in one
  effect. It is debounced 250 ms and `cancelInFlight`, matching the audited `refreshSnapshot`; a result
  whose `generation`/`request` no longer matches is ignored.
- The shell remains the only stream owner. `ConnectionFeature` forwards session-scoped events as a
  delegate; Home re-reads REST on reconnect, overflow resynchronization and execution end.
- Pins, read dates, manual-unread marks, mutes, hidden sessions, last-viewed sessions and What's New seen
  state use `serverPersistenceID|sessionID` keys (or per-server maps), so switching servers cannot read
  another server's records.
- `HomeSnapshot` is version 1, at most 8 servers and 50 sessions per server, written atomically to
  `home-snapshots.json` in Caches by an actor. A decode/version failure is reported, never trusted.
  A successful write removes that server's P5 project-summary entry from `cachedServerSummaries`, which
  is the safe migration off the temporary cache.

### Catch Up semantics

- Candidates are root, unarchived, unmuted sessions whose indicator is attention or unread; running
  sessions are excluded. Attention sorts first, then newest.
- Mark Read applies the local read state immediately and sends `POST /api/session/{id}/view` with the
  idle watermark. A failed receipt restores the previous viewed/read/ manual-unread state and reports on
  the stack. Undo cancels the in-flight receipt, restores the snapshot and puts the card back.
- Keep Unread moves the card without a server call and leaves the session unread. The last handled card
  closes Catch Up to the drawer, whose row reads **All Caught Up** until new work arrives.


### Reviewed P6 corrections

| Path | Correction | Regression |
| --- | --- | --- |
| Paging retry | The footer's Try Again now retries the failed page instead of being refused by `canLoad`. A failed first search re-issues the same query with a fresh token; a failed search append retries its cursor; a failed ordinary page retries its cursor. Each sets `failed = false` before starting so the spinner replaces the button. | `failedInitialSearchRetries`, `failedSearchPageRetries`, `failedOrdinaryPageRetries` |
| Read watermark | A view receipt acknowledges only its own `idle` value. Newer activity B arriving while A is in flight stays unread. Explicit Mark Unread and Catch Up Undo record an unread floor; a delayed view event at or below it is ignored, while a genuinely newer view clears it. | `receiptAcknowledgesOnlyItsWatermark`, `delayedViewAfterMarkUnread`, `delayedViewAfterCatchUpUndo` |
| Deletion | A confirmed delete leaves a tombstone, so a refresh that started before the delete cannot resurrect the row. In-flight deletes survive disconnect; the first authoritative refresh after reconnect reconciles presence (failure: restore the row and notice) or absence (success: purge and keep the tombstone until a later read). Late answers are ignored. | `oldRefreshCannotResurrectDelete`, `deleteFailureReconcilesAfterReconnect`, `deleteSuccessReconcilesAfterReconnect` |
| Connection status | Home is live only when the app is in front, the path is usable and the shell phase is `connected`. Scene/path changes forward that fact; stream interruption marks Home unavailable; a handshake/overflow available signal resumes exactly one authoritative refresh, replacing any read that started before it. A fresh `.task` never starts a second read over a resync. | `homeStaysInactiveWhileAuthenticating`, `homeStaysInactiveWhileOffline`, `homeFollowsPathAndReconnect`, `homeStopsOnInterruption`, `connectionStatusResume`, `taskDoesNotDuplicateResyncRead` |
| Attention events | A cold root or subagent event resolves at most eight ancestry hops, then reads only its own location directory. The root indicator updates without a project scan; a missing root row gets one coalesced Home refresh. Hint directories are bounded to eight for later full reads. | `attentionEventColdRoot`, `attentionEventSubagent` |

### Scroll trace (measured)

| Item | Value |
| --- | --- |
| Fixture | `connected-scroll`, 300 root sessions, two projects, no paging |
| Device/runtime | iPhone 18 Pro Max simulator, iOS 27.2 (runtime `24B8117`) |
| Test | `HomeScrollTraceUITests.testDrawerScrollDeceleration`, 3 iterations, fast up/up/down |
| Frame probe | 141–142 frames per iteration; p50 **16.7 ms**, p95 **16.7 ms**, max **33.3 ms** (one deferred frame) |
| Deceleration metric | 2.416–2.450 s, average 2.428 s, relative standard deviation 0.647% |

This is a simulator trace, not a device claim. The 33.3 ms maximum means one frame took two display
intervals during the measured swipes; the p95 stays at one interval.

## Verified in this phase

| Command | Result |
| --- | --- |
| `swift test --package-path ios/OpenCodeKit` | **317 tests pass**: 161 server, 67 core, 58 app, 31 drawer; live and loopback-opt-out suites behave as before |
| `ios/scripts/verify.sh` | toolchain 27.2 / Swift 6.4.2 / SDK 27.2; app build succeeds; `OpenCodeTests` passes; **26 UI tests pass** (18 existing + 8 P6); package suites pass |

## Not verified

- **Physical device**: no P6 run on hardware. VoiceOver order, Taptic feel, real LAN reconnection and the
  local-network prompt remain device checks; the simulator covers accessibility labels and Dynamic Type
  layout only.
- **Reduce Motion**: P6 adds no custom animation; sheets, navigation and system controls keep platform
  motion. The Reduce Motion policy is therefore inherited, not separately exercised.
- **Live V2 server**: no build with the audited `/api/info`, `/api/project` and new Home routes was
  tested in P6. The P4/P5 `.incompatibleAPI` outcome is preserved; no route was remapped.
- **Real session mutations**: none. Delete/read receipts were exercised against fixture clients only.
- **Visual comparison with the original app**: unavailable; October captures are evidence, not a target.
- **iPad**: out of scope (D-16).

## Deferred P5 items — later phase and acceptance check

| Deferred item | Later phase | Acceptance check |
| --- | --- | --- |
| Camera QR pairing (`PairingScanner`) | P11 (Settings › Servers) | On a device, scanning a valid `opencode pair` code presents the pairing confirmation and redeems once; denied camera shows a typed outcome. Simulator records **unverified**. |
| Custom request headers in the manual form | P11 (Settings › Servers) | A saved header round-trips through Keychain, is sent only to its server's origins, and an invalid name/value is refused without locking the person out. |
| Copied error report | P11 (Diagnostics/connection) | The copied report contains status/feature/typed facts only; a redaction test fails if a credential, address, pairing code or message text appears. |
| Haptics live feel | P14 (hardware hardening) | Each of the eleven haptics is felt and distinguished on a device with System Haptics on; simulator remains **unverified**. |
| Local-network prompt / real LAN socket | P14 (hardware hardening) | Denied prompt → unreachable copy, no request at the fixture; allowed → request reaches the Mac fixture; background/foreground reconnect over the real socket. |
| Production identifiers (bundle id, team, App Group, Keychain service) | P12/P14 owner configuration | Owner-supplied values build/sign; credentials survive relaunch in the configured service; no historical team or group is copied. |
| Push notifications | P12 (Experimental, off) | Relay credentials exist; notifications default off; a fixture push reaches the app only after opt-in. Without a relay the path is **blocked/unverified**. |
| Session/transcript/composer | P7–P9 | P6 carries a stable `SessionSelection` to a placeholder only; P7 adds the session destination, P8 the transcript, P9 the composer. |

## Next

1. P7 (`ios-session`): `SessionFeature`, subagent pages, background work, request review. Consume
   `SessionSelection` (server ID + intent) rather than adding a second navigation model.
2. P8: transcript and the off-screen event pressure policy (D-23).
3. P11: settings, the shipped What's New catalogue, custom headers, camera pairing and report copy.
