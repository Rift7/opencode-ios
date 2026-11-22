# iOS migration — status

## Baseline

| Item | Value |
| --- | --- |
| Integration branch | `ios` |
| Behaviour baseline | `7358160e808fb1870eeb20f5da8df832667019d1` (`origin/dev`) |
| P7 base | `7966dcfea6348a70dee7df05ddc2bec9a4b95048` (`origin/ios`, PR #5) |
| P7 branch | `ios-session`, created from `origin/ios` after `git fetch origin` |
| Worktree | a separate worktree; the Android checkout and unrelated branches are untouched |

`git fetch origin` moved `origin/ios` from `3b34932c` to `7966dcfe`. PR #5 (`ios: add the native Home,
drawer, projects and Catch Up`) is **MERGED** into `ios`. Its merge commit tree is `25b6d297`, byte-
identical to the reviewed `ios-home` tree at `eff8b45f`; `git diff eff8b45f 7966dcfe -- ios
docs/ios-migration` is empty. The squash merge means the task commit is not an ancestor, so tree equality
is the hand-off check.

## Phase status

| Phase | Scope | Status |
| --- | --- | --- |
| 1 | Read-only reconstruction audit | complete (`docs/ios-migration/audit/`) |
| 2 | `ios` branch, baseline, scaffold and gate | complete — `143d8f86` (PR #1) |
| 3 | Core: store, dependencies, sharing, tokens, logging, haptics | complete — `d0fdf2f5` (PR #2) |
| 4 | Server: transport, retry, models, SSE, pairing | complete — `5f143ea7` (PR #3, tree `2326a49b`) |
| 5 | App shell: launch, connection, pairing, reconnect | complete — `3b34932c` (PR #4) |
| 6 | Home, drawer, projects, Catch Up, What's New | complete — `7966dcfe` (PR #5, tree `25b6d297`) |
| 7 | Session, subagents, background work, request review | **complete on `ios-session`** (draft PR #6) |
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
| Home reducer, local records, search/paging, pins, read state, deletion, Catch Up, What's New | `OpenCodeKit/Sources/OpenCodeDrawer/HomeFeature.swift` | `HomeFeatureTests` — 35 Swift Testing cases (pins, unread, server isolation, visibility, search and paging retries, stale responses, read watermarks, deletion reconciliation, Catch Up, What's New, snapshots and cold attention) |
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
| Deletion | A confirmed delete leaves a tombstone, so a refresh that started before the delete cannot resurrect the row. An unsettled delete survives disconnect and is resolved by a **targeted `GET /api/session/{id}`**, never by absence from the first 50-session page. A 404 (not a missing location) confirms absence; a present session only fails the delete when the operation is no longer running; auth, connectivity, server errors and ambiguous reads preserve the backup, pins and read history and report that verification was inconclusive. Late results are operation-ID guarded and cannot reverse a newer reconciliation. | `laterPageDeleteUnknownOutcome`, `laterPageDeleteConfirmedByTargetedRead`, `inconclusiveDeletionVerification`, `runningDeletionSurvivesExistenceCheck`, `lateDeleteResultIgnoredAfterVerification`, `oldRefreshCannotResurrectDelete` |
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

## Phase 7 — what landed

| Area | New or changed path | Gate |
| --- | --- | --- |
| Session reducer, refresh identity, run lifecycle, family pages, request review, shell panel | `OpenCodeKit/Sources/OpenCodeSession/SessionFeature.swift`, `SessionModels.swift` | `SessionFeatureTests` — 25 Swift Testing cases (coalescing, races, settlement, interrupt ambiguity/resume, stranded steer, validation, duplicate submit, conflict, permission rules, root/child/sibling navigation, uncached load/retry/reconnect, stale read, shell poll timing, byte ranges, drain/failure/cancel) |
| Session destination and App → Home → Session ownership | `OpenCodeKit/Sources/OpenCodeApp/AppFeature.swift`, `ios/OpenCode/App/RootView.swift`, `ios/OpenCode/Session/SessionView.swift` | `AppFeatureTests.sessionOwnership`, `sessionServerIsolation`, `sessionEventForwarding`; `SessionUITests.testSessionAndSubagentNavigation` |
| Request models: fields, values, conditions, defaults, validation, permissions, form state and settlement | `OpenCodeServer/Models/RequestModels.swift` | `RequestModelsTests` — 6 cases (value order, defaults/visibility, typed validation, hidden answers, strict type decoding, global question) |
| Family and shell models, selection moved down to the server layer | `OpenCodeServer/Models/SessionModels.swift` | `SessionFamilyTests` — breadth-first, cycle/dedupe, 100-session cap, running descendant |
| Client operations: interrupt, active, family BFS, pending requests, permission/form replies with settlement, inbox, shells/output/stop, jobs/cancel | `OpenCodeServer/Client/OpenCodeClient.swift`, `SessionOperations.swift` | `SessionFamilyTests` through `OpenCodeClient.live`; request-model tests; no live host |
| Mark All as Read | `HomeFeature.markAllReadTapped`, drawer menu and Catch Up menu action | `HomeFeatureTests.markAllReadOnlyUnread`, `markAllFailureRestores`; `HomeUITests.testMarkAllReadFromTheCatchUpMenu` |
| Permission/form review UI | `ios/OpenCode/Session/SessionView.swift` | `SessionUITests` form validation/submit, approve, reject path, failed reply retry |
| Copy and accessibility identifiers | `ios/OpenCode/Resources/Localizable.xcstrings` | 84 new English keys; `session-review-requests`, `request-permission-*`, `request-field-*`, `background-*`, `shell-output*`, `session-subagents`, `session-page-back` |
| Colour provider crash found by the form UI test | `OpenCodeCore/Design/OpenCodeColorTokens.swift` | `OpenCodeColors.color` is `nonisolated`; the dynamic `UIColor` provider no longer asserts a main-queue executor when SwiftUI resolves it off-main |

### Refresh, runs and settlement

- `RefreshReason` keeps all eight audited labels (`open`, `resume`, `reconnect`, `runState`,
  `invalidation`, `settlement`, `watchdog`, `snapshot`). `invalidation`, `settlement` and `runState`
  require a follow-up. At most one authoritative read is in flight: lifecycle duplicates coalesce, and a
  racing mutation earns exactly one follow-up instead of cancelling the read (`.cancellable(id:)` without
  `cancelInFlight`).
- Responses are fenced by session ID and request ID. Events received while a read is in flight are queued
  (bounded at 512), then replayed onto the snapshot; execution and request events also schedule one
  follow-up. A settlement read sleeps the audited 200 ms coalescing window first.
- Stop increments a run generation and cancels the previous interrupt, settle, run-end and stranded-steer
  work. An ambiguous interrupt reads `/api/session/active` and the inbox before trying again: a finished run
  or a resumed steering message is settled, never interrupted twice. An acknowledged stop polls at 1, 2, 4
  and 8 seconds.
- Stranded steering queues first when the message is still marked steer, then steers, reads the inbox and
  checks the run state after 1.5 s.
- A connection loss invalidates the in-flight read and clears the refresh; a return re-reads once.

### Subagents, requests and background work

- Family discovery is breadth-first with at most six child pages in flight, a visited set and a 100-session
  cap; running descendants outside the cap are resolved through bounded metadata ancestry (24 lookups).
  Responses are consumed in queue order, so the family is deterministic.
- Subagent pages are a logical stack (session ID + page identity). The active page reads with `resume`
  when it returns; the root's metadata, requests, pending inputs and shell state stay in the parent, so a
  covered page loses nothing.
- Permission and form models decode strictly. Forms apply defaults, external steps start false, conditions
  hide dependent fields, hidden answers are not sent, and validation returns a typed problem plus the
  active-field index. Submitting marks the request responding, so a second tap cannot send twice; a
  settled request is completed and cannot be actioned again.
- Form replies settle through a read-back: success, a matching read-back, a conflicting state, or a
  `still pending` form resent once. A `409` is never blindly repeated. Conflicts are typed and shown.
- Shell output reads 64 KiB pages, tails from the last 256 KiB, retains 1 MiB and can grow to 4 MiB with
  Load Earlier. A trimmed range advances its start by the exact bytes discarded, including newline and
  UTF-8 alignment, so `startCursor + output.utf8.count == endCursor` always holds. Load Earlier never
  exceeds 4 MiB and joins at the retained start.
- Polling starts only when the sheet is visible and the initial tail is loaded; the two can arrive in
  either order. Stop cancels the poll, drains every remaining page to the current capture size, and only
  then deletes. A failed or incomplete drain keeps the output and requires an explicit Discard Unread
  Output choice; cancellation never deletes.
- Mark All acknowledges only rows whose indicator is `unread`; waiting (attention) and running rows are
  left untouched. Receipts run four at a time with a per-session backup, and a failure restores that row's
  read date, viewed watermark, manual-unread mark and unread floor.

### Reviewed Phase 7 corrections

| Finding | Change | Regression |
| --- | --- | --- |
| The connection boundary dropped session events | `ConnectionFeature.streamEvent` forwards every event except `projectUpdated`, `connected`, `modelsChanged` and `agentsChanged`; token checks stay in place. | `AppFeatureTests.sessionEventForwarding` sends shell, job, inbox, durable content, revert and shell-ended events through App/Connection and observes Session state. |
| A child refresh replaced the family root | The read always discovers the family from its original root; a narrower subtree can no longer replace a known family. | `familyIdentityAcrossPages`: root → child → sibling → back with a client that returns a subtree for each supplied root; inactive child clears the run and unsent answers survive. |
| A selection with no cache rejected its first snapshot | The refresh identity guard accepts the selected session when root and family are still empty; reconnect is allowed during the initial load. | `uncachedInitialLoad`: success, failure, retry, and interruption followed by reconnect. |
| Shell polling could miss its only start | `isVisible` is tracked; prepared or appeared starts exactly one poll when both are ready; reconnection restarts it. | `shellPollTiming`: appearance before load, load before appearance, dismissal during load, reconnect. |
| Trimmed output ranges were not contiguous | Trimming returns the discarded byte count, which advances `startCursor`; Load Earlier joins the retained start and never exceeds 4 MiB. | `shellRangeContiguity`, `shellTrimThenEarlier`, `shellEarlierBounded` (multibyte and page crossing the cap). |
| Stop deleted after one page read | Stop cancels polling, drains to the probing completion boundary, retains bounded output, and only then deletes. Cooperative cancellation is checked throughout the drain and immediately before DELETE; a dependency that succeeds after cancellation cannot reach the stop. A failed/incomplete drain needs an explicit discard. | `shellDrainAndFailure`, `shellDrainCancellationAtProbe`, `shellDrainCancellationAtPage`, `shellDrainControl`: multiple pages, failure, discard decision, cancellation at the probe/page and a successful control. |

## Verified in this phase

| Command | Result |
| --- | --- |
| `swift test --package-path ios/OpenCodeKit` | **365 tests pass**: 174 server, 67 core, 61 app, 38 drawer, 25 session; live and loopback opt-outs behave as before |
| `ios/scripts/verify.sh` | toolchain 27.2 / Swift 6.4.2 / SDK 27.2; app build succeeds; **34 UI tests pass**; package suites pass |
| `xcodebuild ... -only-testing:OpenCodeUITests/SessionUITests` | 6 journeys: session/subagent navigation, permission approval, permission rejection, form validation/submission, failed reply retry, shell output and stop |
| `xcodebuild ... -only-testing:OpenCodeUITests/HomeUITests` | 8 tests including Mark All from the drawer menu |
| Screenshots | `docs/ios-migration/screens/p7-{session,request,background}[-dark].png` |

The counts are the numbers the package runner printed; the gate log is in `ios/.build-results/`.

## Not verified

- **Physical device**: no P7 run on hardware. VoiceOver order, Taptic feel, real LAN reconnection and the
  local-network prompt remain device checks; the simulator covers accessibility identifiers and Dynamic
  Type layout only.
- **Reduce Motion**: P7 adds no custom animation; sheets, navigation and system controls keep platform
  motion. The policy is inherited, not separately exercised.
- **Live V2 server**: no build with the audited request, family, shell or job routes was tested. The P4/P5
  `.incompatibleAPI` outcome is preserved; nothing was remapped.
- **Real session mutations**: no real interrupt, reply, shell stop or job cancel ran against a live
  server. Reducer and UI tests use the fixture client only.
- **Visual comparison with the original app**: unavailable; October captures are evidence, not a target.
- **iPad**: out of scope (D-16).

## Deferred P7 items — later phase and acceptance check

| Deferred item | Later phase | Acceptance check |
| --- | --- | --- |
| Transcript rows, grouping, markdown and the off-screen pressure policy | P8 | A 600-token stream loses no tail; 1,000 rows scroll without binding churn; settlement reads extend the P7 refresh identity |
| Composer editing, drafts, sends, queued-message sheet and steer menu | P9 | Draft survives termination; a failed send retries with a new message id; the queued INPUT model from P7 is the only data source |
| Full request dock in the composer (fold, pages, answer bar) | P9 | Keyboard Send cannot become chat input while a request is docked; the sheet path remains for large forms |
| Shell output copy/share and background subagent stop | P9/P10 | Copy uses the pasteboard dependency; stopping a subagent interrupts and cancels every job in its tree |
| Global form location directory from the composer context | P9 | A global form replies with the session's directory; the P7 client already accepts it |
| Camera QR pairing, custom headers, settings and diagnostics | P11 | Device QR redemption; header round-trip; redacted report |
| Haptics live feel and local-network prompt | P14 | Each haptic is distinguished on a device; denied prompt shows unreachable, allowed prompt reaches the fixture |

## Next

1. P8 (`ios-transcript`): transcript windows, markdown and settlement using the P7 refresh identity.
2. P9: composer, drafts, sends and the queued-input UI over the P7 inbox model.
3. P11: settings, shipped What's New catalogue, custom headers and camera pairing.
