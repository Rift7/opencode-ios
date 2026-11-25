# iOS migration — status

## Baseline

| Item | Value |
| --- | --- |
| Integration branch | `ios` |
| Behaviour baseline | `7358160e808fb1870eeb20f5da8df832667019d1` (`origin/dev`) |
| P7 base | `7966dcfea6348a70dee7df05ddc2bec9a4b95048` (`origin/ios`, PR #5) |
| P7 branch | `ios-session`, created from `origin/ios` after `git fetch origin` |
| P8 base | `92a7c677cb1f1007f1acc1e441603af757e51dfa` (`origin/ios`, PR #6 merged) |
| P8 branch | `ios-transcript`, created from `origin/ios` |
| P8 initial head | `2619c1d5` (draft PR #7) |
| P8 previous corrected head | `1dc7f5f2` (draft PR #7 update) |
| P8 overflow-recovery head | `151b7ff5` (draft PR #7 update) |
| P8 merged head | `2823c06e` (PR #7 squash merge); tree `1147dca8` equals `5ea6ea65` |
| P9 base | `2823c06e` (`origin/ios`, PR #7 merged) |
| P9 branch | `ios-composer`, created from `origin/ios` |
| P9 implementation head | `f694adaa` (evidence and code; the review head follows this doc commit) |
| P9 review-correction head | `5aa0f40e` (draft PR #8 update: durable outbound, page targets, destination-first migration, fenced dismissal, long-input scrolling) |
| P9 second review-correction head | `fc0141e1` (draft PR #8 update: durable retry identity, retained departing drafts, content-fenced Done) |
| P9 merged head | `e42cb455` (PR #8 squash merge); merged tree `62d44987` equals the corrected P9 tree `1fd90423` |
| P10 base | `e42cb455` (`origin/ios`, PR #8 merged) |
| P10 branch | `ios-media`, created from `origin/ios` after `git fetch origin` |
| P10 implementation head | `188167c7` (code, tests, screenshots and docs) |
| P10 correction head | `b7967f5f` (durable release, upload ownership, staging namespace, bounded downloads, scoped/validated cache) |
| P10 evidence head | `0dcd0eb0` (verification record and final UI/package results) |
| P10 merged head | `0ec10ba4` (PR #9 squash merge); merge tree `02dad71e` equals reviewed P10 tree `9880eeb9` |
| P11 base | `0ec10ba4` (`origin/ios`, PR #9 merged) |
| P11 branch | `ios-settings`, created from `origin/ios` after `git fetch origin` |
| P11 review-correction head | `f553cbd7` (preference consumers, mention occurrences, catalogue ownership, server transaction and cancellation checks) |
| P11 storage-correction head | `c9cb1602` (serialized server-record ownership, collision/rollback tests) |
| Worktree | a separate worktree; the Android checkout and unrelated branches are untouched |

`git fetch origin` moved `origin/ios` to `e42cb455`; PR #8 (`ios: add the native composer, drafts, sends, queue,
request dock and quotes`) is **MERGED** into `ios`. The merge commit tree is `62d44987`, byte-identical to the
reviewed P9 correction `1fd90423`; `git diff 1fd90423 e42cb455 -- ios docs/ios-migration` is empty. The squash
merge does not preserve ancestry, so tree equality is the hand-off check.


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
| 7 | Session, subagents, background work, request review | complete — `92a7c677` (PR #6); merged tree `e8e1db5b` equals reviewed `56c10086` |
| 8 | Transcript | complete — merged as `2823c06e` (PR #7); merged tree `1147dca8` equals reviewed head `5ea6ea65` |
| 9 | Composer | complete on `ios` — PR #8 merged as `e42cb455`; merged tree `62d44987` equals reviewed `1fd90423` |
| 10 | Media | complete — merged as `0ec10ba4` (PR #9); merged tree `02dad71e` equals reviewed `9880eeb9` |
| 11 | Settings, experiments, diagnostics, onboarding, QR pairing, models, autocomplete, files | **complete on `ios-settings`** (draft PR, base `ios`); see [P11_MATRIX.md](P11_MATRIX.md) and [P12_DEVICE_CHECKLIST.md](P12_DEVICE_CHECKLIST.md) |
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
  (bounded at 512 separate batches), then replayed onto the snapshot; execution, request, invalidation and
  durable-boundary events also schedule one follow-up. Crossing the bound discards the partial replay and
  stores a persistent recovery requirement; no truncated projection is published. The recovery read keeps
  a durable boundary's audited 200 ms delay, survives failures, and clears only when the authoritative
  transcript succeeds with no new overflow. It is bounded to one immediate attempt plus one delayed retry;
  after that a manual retry/reconnect uses the same coordinator. A settlement read still sleeps 200 ms.
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

## Phase 8 — what landed

Base: `origin/ios = 92a7c677cb1f1007f1acc1e441603af757e51dfa` (PR #6 squash-merged). The merged tree is
`e8e1db5b`, byte-identical to the reviewed P7 head `56c1008632f73aea905cce41dee1e8c8b0784cb0`; the
corrections named in the P7 STATUS survived the squash merge. The Phase 8 branch `ios-transcript` was
created from that commit; no branch was reset or overwritten.

| Area | New or changed path | Gate |
| --- | --- | --- |
| Transcript wire model and decoder: message types, part identities, tool calls, images, files, compaction, notices, errors, retries, bounds, media references, prompt references and quotes | `OpenCodeKit/Sources/OpenCodeServer/Models/{TranscriptModels,TranscriptDecoder}.swift` | `TranscriptDecodingTests` — 11 cases |
| Transcript routes: newest descending window, older cursor page (20 s, 80 messages), one message | `.../OpenCodeServer/Client/{OpenCodeClient,TranscriptOperations}.swift` | request-shape tests in `TranscriptDecodingTests` |
| Grouping, stable entry identity, window/entry-start rules, newest/older reconciliation, live delta and tool projection | `OpenCodeKit/Sources/OpenCodeTranscript/{TranscriptGrouping,TranscriptProjection}.swift` | `TranscriptGroupingTests` — 17 cases, `MarkdownTests` — 9, including 600-token tail and 1,000-row identity |
| Native Markdown blocks and inline text; revision-fenced publication; bounded parse cache; no remote image fetch | `.../OpenCodeTranscript/Markdown.swift` | `MarkdownTests` — 9 cases including controlled out-of-order parse completion, replacement and disappearance; cache bound/clear tested |
| Per-session transcript state, earlier-cursor chain, page/session/generation fencing, disclosure and scroll view state | `.../OpenCodeSession/TranscriptState.swift` | `TranscriptFeatureTests` — 19 cases |
| The transcript joins the existing authoritative refresh; live content applies in order; invalidations race a read safely; >512 raced batches mark a persistent recovery that keeps settlement delay, survives failure and clears only on coherent success | `.../OpenCodeSession/{SessionFeature,SessionModels}.swift` | read-plan, race, invalidation, reconnect, settlement and bounded-recovery tests (`overflowSettlementDelaysRecovery`, `failedRecoveryStaysRequired`, `repeatedOverflowDuringRecovery`) |
| Transcript surface: user bubbles, quotes, files, assistant Markdown, tool groups, compaction, notices, run errors/retries, run-end Copy, disclosure, growth-safe follow, Jump to Latest, earlier-history states | `ios/OpenCode/Transcript/{TranscriptView,TranscriptRows,MarkdownViews}.swift`; `ios/OpenCode/Session/SessionView.swift` | `TranscriptUITests` — 9 journeys |
| Link routing boundary and explicit link opener | `OpenCodeCore/Dependencies/OpenURLClient.swift`, transcript link confirmation | reducer + UI link-confirmation tests |
| Memory-warning clearing for the parse cache | `ios/OpenCode/App/OpenCodeApp.swift` | cache clear exercised at the actor; the notification is a thin hand-off |
| Deterministic transcript fixtures, long history, streaming and 1,000-row modes | `ios/OpenCode/App/UITestFixture.swift` | UI and trace tests |
| Screenshots | `docs/ios-migration/screens/p8-{transcript,transcript-dark,transcript-tools,transcript-tools-dark,transcript-jump,transcript-jump-dark}.png` | synthetic fixture, iPhone 18 Pro Max simulator, iOS 27.2 |

### P8 acceptance matrix

| Contract | Current `dev` source (`7358160e`) | Adopted behaviour | Evidence |
| --- | --- | --- | --- |
| Routes, pagination and ordering | `server/live/LiveTranscript.kt` (`requestTranscript`, `requestHistoryPage`, `requestMessage`), `live/Payloads.kt` (`MessagesPayload`, `MessagePayload`) | Newest window is `order=desc&limit=30`; history is `limit=80` plus `cursor`, or a newest re-read when the edge is unknown; one message reads `/message/{id}`. Responses are oldest-first; duplicates are skipped by ID | `TranscriptDecodingTests.ordering`, `clientTranscriptRoute`, `clientHistoryRoutes`, `clientMessageRoute`; `TranscriptFeatureTests.earlierHistory` |
| Message/part identity and streaming | `LiveTranscript.kt` (`transcriptItems`), `SessionFeatureStream.kt` (`mergeTranscript`), `server/model/OpenCodeTranscriptItem.kt` | `<message>-text-<ordinal>` and `<message>-tool-<id>` identities match REST and SSE; a delta updates its part, an ended part is durable, and a snapshot replaces its window without reordering | `streamTailGate`, `liveAndSettlement`, `TranscriptGroupingTests.streamedTail`, `toolLifecycle` |
| Grouping and disclosure | `TranscriptEntry.kt` (`TranscriptEntry.build`, `entryStart`, `sessionStartModelIDs`) | Consecutive tools/notices group; user rows group per prompt; a finished reply ends with Copy; a session-start model switch is hidden; a running question stays out of history | `TranscriptGroupingTests.grouping`, `replyEndWaits`, `pendingQuestion`, `startModel`, `entryStart`; `TranscriptUITests.testTranscriptRendersMarkdownToolsAndNotices` |
| Content types and interactions | `LiveTranscript.kt`, `markdown/*`, `rows/*`, `user/*` | User text/images/files/quotes, assistant Markdown, tools, compaction, notices, model switches, run errors/retries, undone rows; links and images are safe routes; reasoning text is not shown because current `dev` does not decode it | Decoder tests; `MarkdownTests`; UI transcript, disclosure, link journeys |
| Scrolling and restoration | `list/TranscriptList.kt`, `TranscriptListSnapshot.kt`, `SessionFeatureStateTranscript.kt` | Standard SwiftUI scroll view and `LazyVStack`: follow only at the end, Jump to Latest when browsing, earlier-page anchor preserved, per-session disclosure/scroll state restored on a covered subagent page; Reduce Motion removes the jump glide | `pageRestoration`; `testJumpToLatestAfterReadingOlderContent`, `testLoadEarlierRetainsTheReadingPosition`, `testDisclosureStaysOpenAcrossASubagentPage` |
| Settlement, invalidation and overflow | `SessionFeatureRefresh.kt` (`acceptWindow`, `mergeTranscript`), `SessionFeatureHistory.kt` (`mergeOlderPage`, generations), `EventBatcher.kt` | The transcript extends P7's single read; `messageInvalidated` re-reads through it; a durable boundary waits 200 ms; an older page is fenced by session + generation + cursor; reconnect re-reads; overflow still resynchronizes from REST | `readPlan`, `eventRace`, `invalidationReads`, `staleEarlierPage`, `reconnect`, `earlierRetry` |

### Baseline vs. branch-only

- **Baseline (adopted):** current `dev` message types, grouping, cursor semantics, durable boundaries, tool
  text bounds (20,000 bytes per output), 16 images / 20 MB each / 32 MB total, and the `media:` capability.
- **Not adopted:** Android-only session-media pages, failed-send Edit/Delete placement, the selection-mode
  drawer, and any behavior from unmerged Android branches. Quotes are adopted because current `dev` reads
  `metadata.comments`; they are display-only here.
- **Native adaptation:** a plain `ScrollView` + `LazyVStack` instead of iOS's UIKit follower and Android's
  reversed `LazyColumn` motion. This is a recorded decision, not a claim of recovered feel.
- **Uncertain reconstruction:** the October capture harness used `transcript-list` and `tool-image-mosaic`;
  both identifiers are reused where they still describe the surface. No visual claim is made against them.

### Performance evidence (simulator only)

| Run | Fixture | Method | Result |
| --- | --- | --- | --- |
| Long transcript scroll | `connected-transcript-long`: 1,000 rows (500 prompts, 500 replies), no earlier page | `TranscriptScrollTraceUITests.testLongTranscriptScroll`, 3 iterations, fast up/up/down, `CADisplayLink` probe | 143/142/143/142 frames; p50 16.7 ms, p95 16.7 ms, max 35.9/33.3/33.3/33.3 ms; scroll deceleration 2.228 s average (RSD 7.6%); peak physical memory 24.1 MB |
| Streaming while scrolling | `connected-transcript-stream`: one prompt, 600 live text deltas at 20 ms, 3 iterations | `testStreamingTranscriptScroll` | 43/146/146/146 frames; p50 16.7 ms throughout; first iteration p95 33.3 ms / max 36.2 ms including initial layout, later iterations p95/max 16.7 ms; deceleration 2.421 s; peak physical memory 25.97 MB |
| Growth following | `connected-transcript-growth`: one stable Markdown row, 2,000 deltas with headings/lists | `testFollowingSurvivesTailGrowthAndBrowsingHoldsItsAnchor` | tail stays on screen through growth; after the reader scrolls away the anchor moves <12 pt while streaming continues and Jump to Latest appears |
| Device/runtime | iPhone 18 Pro Max simulator, iOS 27.2 (24B8117), debug build | `xcodebuild -only-testing:OpenCodeUITests/TranscriptScrollTraceUITests` | Simulator evidence; not a device claim |
| Media-heavy transcript scroll (P10 corrections) | `connected-media-long`: 30 turns × (text + two 320×200/200×320 inline images + reply) | `MediaPerformanceUITests.testMediaHeavyTranscriptScroll`, 3 iterations, fast up/up/down, `CADisplayLink` probe | 4 traces: 129–132 frames; p50 16.7 ms; p95 34.6–35.8 ms; max 41.6–65.3 ms; peak physical memory 29.7 MB |
| Large-image viewer open/close (P10 corrections) | `connected-media-large`: one 3,000×2,000 inline PNG | `testLargeImageViewerOpen`, 3 iterations, `XCTClockMetric` + memory | Loop average 5.062 s (includes open, close and two existence waits in the UI test), RSD 0.16%; peak physical memory 25.9 MB |
| Typing with an attachment (P10 corrections) | `connected-media` + pasted synthetic image; 75 changes | `testTypingWhileAnAttachmentIsImporting`, reads the DEBUG typing probe | 6.5 ms average / 32.0 ms max over 75 changes; import had completed before typing, so this is the steady-state composer cost |

The long-transcript run shows single deferred frames (33–36 ms) during the measured swipes; p95 stays at one
display interval. Streaming's first iteration includes the initial row/layout work; later iterations stay at
16.7 ms. These are not frame-budget assertions, and the deceleration metric varies with swipe velocity (RSD
7.6% on this run).

### P8 screenshot provenance

`TranscriptScreenshotUITests` captured light and dark surfaces on the same simulator and fixture
(`connected`, plus `connected-transcript-long` for Jump to Latest) on 2026-11-22. All names, messages and
paths are synthetic. The October iOS screenshots remain historical evidence only.

### P10 screenshot provenance

`MediaScreenshotUITests` captured `p10-{transcript-media,image-viewer,tool-mosaic,file-viewer,browser,
composer-attachment,attachment-preview,annotation}[-dark].png` from the `connected-media` fixture on the
iPhone 18 Pro Max simulator (iOS 27.2) on 2026-11-23. Images, names, file paths and the pasted image are
synthetic. The browser screenshot is a loopback HTML fixture (`127.0.0.1`, synthetic text) served by the UI
test runner; the browser surface itself is enabled only by DEBUG launch arguments. No external page was
fetched.

### P8 scope boundaries and limitations

- Cross-block selection (`TranscriptReplySelectionView` on iOS) is not rebuilt. Native per-block text selection
  is enabled, and every finished reply has an explicit Copy action that uses the pasteboard dependency.
- Files open only a name/path/MIME sheet with Copy Path; image tiles and tool videos are placeholders or file
  rows until P10. Markdown remote images are link cards, never fetches.
- Math renders its source in a code band; Mermaid is not rendered. A maintained math/Mermaid renderer is a P10
  media decision.
- Composer editing, sending, queued-input presentation, the request dock folds and quote-to-composer are P9.
- `/api/experimental/session/{id}/wait` has no call site yet; the wait loop belongs to the P9 send path.

## Phase 9 — what landed

Base: `origin/ios = 2823c06e` (PR #7 squash-merged). Its tree is `1147dca8`, byte-identical to the
reviewed P8 head `5ea6ea65`; the P8 overflow-recovery corrections survived the merge. The task branch
`ios-composer` was created from that commit; no branch was reset or overwritten.

| Area | New or changed path | Gate |
| --- | --- | --- |
| Composer state, draft scope, send eligibility, quote chips, failed-send recovery | `OpenCodeKit/Sources/OpenCodeComposer/{ComposerModels,ComposerFeature}.swift` | `OpenCodeComposerTests` — 10 cases (restore, delayed race, failed save, size bound, duplicate tap, newer typing, unverified, failure recovery, quote metadata) |
| Debounced, per-scope draft persistence with explicit outcomes | `.../OpenCodeComposer/ComposerDraftStore.swift` | actor store, 500 ms reducer debounce, flush, atomic file storage, `tooLarge` without truncation |
| Focused UIKit text input: selection, marked text, hardware Return and Shift+Return, dynamic height | `ios/OpenCode/Composer/ComposerTextInput.swift` | UI journeys; marked text/hardware keyboard need device checks |
| Native composer, request dock, answer bar, queued sheet and quote selection | `ios/OpenCode/Composer/{ComposerViews}.swift` | 10 `ComposerUITests` journeys, 10 screenshots |
| First-send creation, ordinary sends, reconciliation, wait loop, inbox operations, request-bar routing, quote handoff, late-result fencing | `OpenCodeKit/Sources/OpenCodeSession/{SessionFeature,SessionModels,RequestDockState}.swift` | `ComposerSessionTests` — 14 cases |
| Prompt/create/wait/cancel routes and one wait retry owner | `OpenCodeServer/Client/{PromptOperations,OpenCodeClient}.swift`, `Retry/SessionWaitLoop.swift` | `ComposerClientTests` — 4 route/body cases; `SessionWaitLoopTests` — 5 bounded/cancellation cases |
| New-session entry from Home and project rows | `OpenCodeDrawer/HomeFeature.swift`, `ios/OpenCode/Drawer/HomeView.swift`, `OpenCodeApp/AppFeature.swift` | UI journey `testNewSessionComposeSendAndSettlement` |
| P9 fixture modes and deterministic screenshots | `ios/OpenCode/App/UITestFixture.swift`, `OpenCodeUITests/{ComposerUITests,ComposerScreenshotUITests}.swift` | synthetic only; no socket |
| Copy | `ios/OpenCode/Resources/Localizable.xcstrings` | 62 new English keys |

### P9 acceptance matrix

| Contract | Current `dev` source (`7358160e`) | Adopted behaviour | Evidence |
| --- | --- | --- | --- |
| Composer text, selection, composition | `ComposerTextInput.kt` (`ImagePasteTextView` bridge, selection restore, `finishCompositionIfNeeded`) | UIKit `UITextView` bridge; external draft sync is deferred while marked text exists; selection clamped; Return sends, Shift+Return inserts a newline; caret moves to end on a focus request | `ComposerTextInput`; UI typing/relaunch journeys; marked text/hardware keyboard reported unverified on device |
| Draft identity and persistence | `ComposerPersistence*.kt` (`serverID|sessionID`, `composer-state.json`, 500 ms debounce, New Session project, stale entries) | Key = server persistence ID + session, or server + project for a new session; 500 ms debounce; flush on Done and background; 128 KiB text / 64 KiB quotes / 200 quotes; a too-large draft is reported and kept, never truncated | `ComposerFeatureTests.draftRestorationAndIsolation`, `delayedRestorationLosesToTyping`, `failedSaveIsReported`, `tooLargeDraft`; UI relaunch and session-switch journeys |
| New-session entry and first send | `HomeFeatureDrawer.kt` (`NewSessionTapped`), `HomeFeature.kt` (`openingDraft`) | Home toolbar and each project row start a new composer; the first send creates `POST /api/session` under a client-made id, then posts the prompt under a client-made message id | `ComposerSessionTests.firstSendCreatesSession`, `createThenSendFailure`; UI new-session journey |
| Ordinary sends, duplicate taps, partial failure | `SessionFeatureSend.kt` (`sendComposer`, `submit`), `SessionFeatureDelivery.kt` | Composer blocks a second tap while a send is in flight; a created session is retained if the prompt fails; the failed text returns to the composer (or a Retry/Edit row if newer text exists) | `duplicateSendTapSendsOnce`, `createThenSendFailure`, `failureRestoresDraft`, `failureWithNewerTyping` |
| Message IDs, definite vs ambiguous outcomes | `LivePrompts.kt` posting under a client ID; `SessionFeatureDelivery.kt` read-backs | Definite rejection → failure. Ambiguous outcome → read the message by ID and the inbox before reporting. Retry mints a new message ID only after a successful read-back proves the old ID absent; an unreadable read keeps the failure unverified and does not duplicate | `ambiguousFoundIsAccepted`, `ambiguousUnreadableIsUnverified`, `retryUsesNewMessageID`, `ComposerClientTests.promptShape` |
| Wait loop | `LiveSessions.kt` `requestWaitForIdle` (`POST /api/experimental/session/{id}/wait`, 25 s poll, 20 s fast threshold, 12 fast failures, caller-owned `.once` escape) | Each poll and active probe is sent once; the loop re-arms a timed-out live run at once, checks activity after a fast failure, then sleeps the shared session-wait backoff; cancellation propagates; no generic retry wraps it | `SessionWaitLoopTests`; `waitForIdle` client route; `composerWaitFinished` triggers the existing settlement read |
| Queued inputs and steer | `SessionFeaturePendingInputs.kt`, `QueuedMessagesSheet.kt`, `LivePrompts.kt` | P7 inbox remains the only model; a queued item can Send Now (PATCH steer), move to queue (PATCH queue) or be cancelled (DELETE); an idle stranded item reuses the P7 queue-then-steer path; a late event only replaces the matching session’s inbox | `ComposerSessionTests` inbox cases; UI running/queued journey; P7 `strandedSteer` tests remain green |
| Request dock | `RequestDockView.kt`, `RequestAnswer.kt`, `RequestCollapse.kt` | The dock owns the answer bar while any request is pending. Permissions offer Allow Once/Always/Deny; a question or one simple field pages and submits from the bar; a larger form keeps the sheet. Chat Send is never routed into the answer bar and the chat draft is untouched | `requestDockQuestion`, `requestDockPermission`; UI dock journey; P7 request tests still pass |
| Quote handoff | `ComposerQuote.kt`, `OpenCodePromptPresentation.quoteBlock`, `metadata.comments` | A reply’s Quote action opens a native selectable view; the selected text becomes a composer quote without touching the draft. Send writes the audited quoted block into the model text and `{"type":"quote"}` into metadata, with an optional comment | `quotePromptAndDraftPreservation`, `quoteHandoff`; UI quote journey and screenshots |
| Subagent composer ownership | `SessionPageStack.kt`, `SessionFeature.kt` | The composer follows the active page: root, child, sibling and back each load their own draft/outbound record. A child send uses the child session ID. A result completing after navigation resolves the original target’s storage and cannot alter the visible page. | `subagentDraftOwnership`, `sendCompletesOnAnotherPage`; UI child navigation |
| Dismissal and replacement handoff | `SessionView`, `AppFeature.kt` session removal | Done waits for an explicit persisted flush with a session identity, request ID and the saved content. A failed save keeps the session open. Replacement, switch, disconnect and interactive dismissal transfer the draft outside the child lifetime; a failed transfer is retained, surfaced as `draftKept` and retried. | Fourteen `AppDismissalTests`; no timer path remains |
| Long multiline input | `ComposerTextInput.kt` (grow then scroll) | Grows naturally to 168 pt, then scrolls internally and keeps the caret/selection visible; shrinking restores the non-scrolling layout. | `testLongMultilineDraftScrollsInsideTheCap` at accessibility text size |
| Keyboard, accessibility, persistence | `ComposerViews.kt`, `ComposerTextInput.kt` | ≥48 pt send targets, 44 pt menu, labels and identifiers; composer follows the keyboard through a bottom safe-area inset; Dynamic Type and dark mode use system tokens; drafts survive navigation, background and relaunch | UI Dynamic Type/dark/keyboard journey; session-switch and relaunch journeys |

### Draft policy and bounds

- A session draft is keyed by `server persistence ID | session:<sessionID>`. A new-session draft is keyed by
  `server persistence ID | new:<project directory>` so it is stable across relaunch and one project cannot
  overwrite another. After the first create, the record moves to the created session key.
- Typing is debounced 500 ms in the reducer; Done and a background transition flush immediately. The actor
  writes one `composer-drafts.json` atomically under Application Support (UI tests use an isolated file).
- Limits are 128 KiB of UTF-8 text, 64 KiB of quote text and 200 quotes per draft. Exceeding a limit returns
  `.tooLarge`, keeps the full text in memory and shows a recoverable error; no prefix is saved or displayed.
- A draft record also owns failed sends and the one outbound operation in flight. An unresolved outbound record
  is restored as an unverified failed send with its original message ID and target; it is never replayed as
  ordinary editable text.
- Each record carries a monotonic `revision` and `updatedAt`. A departing transfer uses `saveIfNewer`
  (timestamp, then revision) and migration compares the same way, so an older copy cannot replace newer typing.
- A storage read failure is `.couldNotRestore`; a write failure is `.couldNotSave`; neither is shown as a
  successful save. A delayed load is discarded if the person typed or the key changed.
- Clearing the editor happens only after the outbound record is durably written. A later edit has a newer
  revision and is never cleared by the earlier send’s result.

### Message-ID and wait decisions

- The POST body is the existing `PromptBody` with the quote metadata extension. The server dedupes prompt
  admission by message ID, and the read-back uses `GET /api/session/{id}/message/{messageID}` plus the inbox.
- The recorded P9 gate (“a failed send retries with a new message id”) is implemented without blind
  duplication: a **definite** rejection can be retried; an **ambiguous** result is read back first. If the old
  ID is present, the result settles as success. If the read confirms absence, Retry mints a new ID. If the read
  fails, the composer reports **Couldn’t verify** and keeps the optimistic row; it does not send again.
- The wait route is exactly `POST /api/experimental/session/{id}/wait` (25 s poll, idempotent). Completion
  means the run settled. The wait effect is cancellable per operation; a failed wait is not a failed send, and
  the stream/settlement read remains authoritative.
- `/api/experimental/session/{id}/wait` is not a generic transport retry: `SessionWaitLoop` is the only owner.

### Reviewed P9 corrections

| Finding | Change | Regression |
| --- | --- | --- |
| A send could lose recoverable text | Send now persists `ComposerOutbound` (target, message ID, text, quotes, delivery) before dispatch. A blocked save does not dispatch; an offline/request-blocked delegate restores the payload; an unverified result becomes a persisted ambiguous failed send with the original ID. Failed sends are part of the draft record. | `sendPersistenceFailureKeepsText`, `blockedSendRestores`, `requestBlockedSendRestores`, `restartAfterSendBeforeResponse`, `restartConfirmedAcceptance`, `restartConfirmedAbsence`; ambiguous Edit is disabled |
| Subagent pages sent to the root | Composer target follows the active page. Opening/pushing/popting saves the outgoing draft and loads the destination draft; a completed send resolves against its original target’s persisted record if another page is visible. | `subagentDraftOwnership` (root → child → sibling → back with distinct text/quotes and child then root send IDs), `sendCompletesOnAnotherPage` |
| Project-to-session migration deleted before saving | Migration writes the destination first, skips a newer destination, removes the source only after success, and keeps the source if cleanup fails. The source gains `createdSessionID` before migration so a restart can recover it. | `destinationFirst`, `destinationFailure`, `cleanupFailure`, `restartDuringMigration`, `newerDestinationWins`; `migrationFailuresSurface` |
| Dismissal relied on a 200 ms timer | Done asks `SessionFeature` for an explicit draft flush with a request ID; `AppFeature` closes only on a matching saved completion. A failure keeps the session and shows an actionable notice. Replacement, server switch and disconnect transfer the draft through an App-owned effect before the child disappears. | `dismissalWaitsForSave`, `dismissalSaveFailure`, `lateDismissalIsFenced`, `disconnectTransfersDraft`, `switchServerTransfersDraft`, `replacementTransfersDraft`; `cancelledCreateDoesNotPrompt` |
| Long input had no scrolling surface | The field grows to 168 pt, then enables internal scrolling and keeps the caret/selection visible; shrinking below the cap restores the non-scrolling layout. | `testLongMultilineDraftScrollsInsideTheCap` at accessibility text size |

The outbound record is also fenced by operation ID and target. A late result from a replaced screen or another
page resolves storage for the operation’s own target and cannot call `sendAccepted`/`sendFailed` on the visible
page. A create that returns successfully after the session child was replaced checks cancellation before the
prompt mutation and does not post.

### Second review corrections

| Finding | Change | Regression |
| --- | --- | --- |
| A retry dispatched under a different ID than the stored record | A definite retry allocates and durably records its new ID in `ComposerFeature` before the delegate. An ambiguous retry keeps its recorded ID until reconciliation; a confirmed absence replaces the outbound record with a new ID and saves it before dispatch. A failed save restores the previous identity and sends nothing. Results, optimistic rows and restarted records use the dispatched ID; accept/fail/unverify no longer fall back to another outbound record. | `definiteRetryStoresNewIdentity`, `retrySuspendedRestartUsesActualIdentity`, `definiteRetryPersistenceFailureDoesNotPrompt`, `retryIDPersistenceFailureDoesNotPrompt`; stored and request IDs asserted |
| A failed departing-draft transfer was discarded | `AppFeature` tracks each transfer by id/key/draft, saves with `saveIfNewer`, and retains a failed transfer under its original server/key. A `draftKept` notice surfaces it; retries run on launch, foreground and navigation; completions are fenced by id/key/draft. A newer draft always wins. | `replacementFailureRetainsDraft`, `switchServerFailureRetainsDraft`, `disconnectFailureRetainsDraft`, `interactiveDismissalFailureRetainsDraft`, `olderTransferCannotOverwriteNewerTyping`; `saveIfNewerFencesByRevision`, `saveIfNewerUsesTimestampsAcrossSessions` |
| Done could dismiss after saving an older snapshot | The flush carries a request token and the full draft snapshot, cancels the debounce, and re-saves when text, quotes, failed sends or outbound changed while persistence was suspended. `AppFeature` closes only after the composer reports a save matching the current content. | `doneWaitsForNewerContent`; the existing `dismissalWaitsForSave`, `dismissalSaveFailure` and `lateDismissalIsFenced` remain |

Draft records now carry a monotonic `revision` and `updatedAt`. `saveIfNewer` and migration compare the
timestamp first and the revision as the tie-breaker, so a transfer from a session whose revision restarted
cannot replace newer content. Records written before `revision` existed decode as revision 0.

### Typing and streaming measurements (simulator)

| Run | Fixture | Method | Result |
| --- | --- | --- | --- |
| Typing over a long static transcript | `connected-composer-long`: 600 rows | `ComposerUITests.testTypingDoesNotReparseTheWholeTranscript`; 42 typed characters (34 reported text changes); `TYPING_MAIN_TURN_PROBE` = average/max milliseconds from text change to next main-queue turn | average 6.6 ms, max 24.3 ms over 34 changes; Markdown parse count and entry count unchanged |
| Typing while streaming | `connected-composer-stream`: 600 deltas at 20 ms | `testTypingDuringStreamingKeepsTheComposerResponsive`; 23 characters (17 reported text changes) | average 9.1 ms, max 14.8 ms; composer change survived; no crash |
| Driver time (whole `typeText` call) | same runs | `ContinuousClock` around XCUITest `typeText` | 1467 ms / 1111 ms for 42 / 23 characters; this is the test driver’s input time, not keystroke latency |
| Device/runtime | iPhone 18 Pro Max simulator, iOS 27.2 (24B8117), debug build | `-only-testing:OpenCodeUITests/ComposerUITests` | Simulator evidence; not a device claim |

### P9 screenshot provenance

`ComposerScreenshotUITests` captured light and dark surfaces on the same simulator and fixture set on
2026-11-22: `p9-{composer,composer-quote,quote,request-dock,queued}[-dark].png`. All names, messages, paths,
servers and URLs are synthetic. The composer screenshot intentionally shows the software keyboard; the request
dock and queued sheet show fixture-only questions and messages.

### P9 scope boundaries and limitations

- Model/agent/mode pickers, autocomplete (`@file`, `@agent`, `@skill`, `/command`) and mentions are not built.
  The composer sends the existing session’s model/agent and plain text; no second catalog or control model was
  invented. Their acceptance check is recorded under P11 below.
- Attachments, file/photo picking and their uploads remain P10. The composer deliberately has no + button that
  would appear functional but do nothing.
- Quote selection covers one transcript block at a time. Cross-block selection remains the P8/P14 limitation;
  there is no claim of whole-document selection.
- Marked-text composition (IME) and Shift+Return were exercised by the bridge’s behaviour and code path, but no
  automated IME/hardware-keyboard run was possible in this environment; they are device checks.
- No compatible live V2 server was used. Every positive mutation journey and all route tests use the fixture or
  a scripted transport. No live session was mutated.
- Physical iPhone, VoiceOver reading order, real keyboard, haptics and memory pressure remain unverified.

## Phase 10 — what landed

| Area | New path | Gate |
| --- | --- | --- |
| Attachment models, bounds, MIME and hash rules | `ios/OpenCodeKit/Sources/OpenCodeMedia/{MediaModels,MediaCopy}.swift` | `MediaImportTests`, `MediaAttachmentTests` |
| App-owned staging, bounded copies, security-scoped cleanup, atomic writes, abandoned/partial cleanup | `.../MediaFileStore.swift` | write/copy/oversize/cleanup tests; no picker URL is persisted |
| Photo, image, document and paste import with JPEG 1568 px re-encode | `.../MediaImport.swift` | valid, oversized, corrupt, text-sniffed, paste tests |
| Authenticated media blob loader, 48 MiB memory / 256 MiB disk / per-server 404 | `.../MediaReferences.swift` | coalescing, disk-hit-after-purge, 404-per-server, trim tests |
| Decoded image cache (64 MiB) and bounded thumbnail decode | `.../MediaImages.swift` | decode bounds; memory warning drops it |
| Image viewer, gallery, zoom/pan, swipe dismiss, video/audio, PDF and text pages | `.../MediaViewerFeature.swift`, `ios/OpenCode/Media/MediaViewerView.swift` | `MediaUITests` image/tool journeys, `MediaPerformanceUITests` |
| Annotation model, renderer and editor | `.../MediaAnnotation.swift`, `ios/OpenCode/Media/AnnotationEditor.swift` | annotation flattening test; composer Add journey |
| Server path resolution, code preview/highlighting and file viewer | `.../FileViewerFeature.swift`, `.../CodePreview.swift`, `ios/OpenCode/Media/FileViewerView.swift` | path-target tests, file-viewer reducer test, server-file UI journey |
| Browser policy, experiment gate, bounded WKWebView, fallback | `.../BrowserPolicy.swift`, `.../BrowserFeature.swift`, `ios/OpenCode/Media/BrowserSheet.swift` | policy/gating tests, browser UI gate journey |
| Transcript image tiles, tool mosaic, file cards and viewer routes | `ios/OpenCode/Transcript/TranscriptRows.swift`, `OpenCodeSession/SessionFeature.swift` | image gallery/file viewer reducer tests; UI journeys |
| Composer + menu, Photos/Files/Camera/Paste, chips, preview and annotation return | `ios/OpenCode/Composer/{ComposerViews,CameraCaptureSheet,ComposerTextInput}.swift`, `OpenCodeComposer/ComposerFeature.swift` | composer attachment tests, relaunch, paste, preview, annotation and send journeys |
| Background subagent stop, shell Copy/Share | `OpenCodeSession/SessionFeature.swift`, `ios/OpenCode/Session/SessionView.swift` | `SessionMediaTests.subagentStop`; shell toolbar |
| Cache limit, memory warning and launch cleanup | `MediaReferenceCache`, `AppFeature.memoryWarning`, `MediaScratch` | trim test; app launch cleans scratch and partial files |

### P10 review corrections

- Staged files are released only after a durable save. `pendingReleases` waits for `.saveFinished(.saved)` and checks current, parked, failed, outbound, persisted and leased ownership; a failed save or a lease keeps the source. Upload completion no longer deletes the source immediately.
- Upload operations carry the originating `ComposerDraftKey`, attachment ID and monotonic attempt. Hidden completions merge into the persisted/parked draft without replacing newer edits; an old attempt cannot overwrite a retry; a merge failure is surfaced and retried when the owner is visible. Cancellation is per key and attachment.
- `uploadFile` now takes an app-made upload ID and reuses `<tmp>/uploads/<uploadID>/<name>` on every retry. The previous fresh UUID per invocation contradicted the comment and could duplicate an ambiguous upload.
- Staging writes go through `ComposerAttachments/.staging` and are moved into the final directory only after completion. Startup cleanup deletes only that namespace; an imported `report.tmp` or `capture.partial` is never inferred disposable from its suffix. File leases keep preview reads and annotations from being cleaned up underneath them.
- `mediaData` now opens the transport stream and stops at a cumulative byte bound, rejecting an oversized declared length before the body and closing immediately on overflow. `OpenCodeClientError.responseTooLarge` is typed; loopback tests cover declared, chunked, understated-length and cancellation/close paths.
- Media cache keys and disk paths include a SHA-256 authentication-scope token derived from server identity and credentials (never raw credentials). Fetched and disk-loaded bytes are verified against the requested SHA-256; corrupt disk entries are removed and refetched, and mismatched fetches are rejected.

### P10 acceptance matrix (summary; full detail in `P10_MATRIX.md`)

| Contract | Status | Evidence or limit |
| --- | --- | --- |
| Photo import | done for images via `PhotosPicker` | picker videos are not imported; Files can attach a video and server videos play |
| Camera import | done through the system capture UI | deliberate native adaptation of the audited custom camera; physical camera unverified |
| Document import | done with the system file importer and an app-owned copy | iCloud/file-provider latency and eviction unverified on device |
| Paste | images, files and long text; >1,000 chars or >12 lines becomes Pasted Text | ordinary typing is never converted |
| Staging/validation/upload | 20 MB images, 100 MB files, actual MIME sniff, progress, stable upload path, retry, unsupported server | live `/api/info` + `/api/experimental/fs/write` not run against a real V2 server |
| Durable ownership | release only after a successful save; current, parked, failed, outbound, persisted and leased references all keep the source; interrupted uploads restore as failed with source | storage-backed tests; no crash-in-the-middle device run |
| Prompt encoding | inline JPEG/paste `data:` parts, path reference lines, `metadata.attachments` | `ComposerAttachmentTests.promptEncoding` |
| Transcript images/tool mosaics | native tiles and gallery; tool mosaic opens the same viewer | fixture UI journeys |
| Viewers | image/zoom, video/audio, PDF, code/text, file | UI journeys; playback interruptions unverified |
| Server files | `fs/list` and bounded `fs/read` through the client; preview; remote-only paths | P11 adds the on-demand folder browser; read flows tested |
| Annotation | draw, undo, flatten and add to the originating composer; cancel keeps the draft | UI Add journey and renderer test |
| Browser | Experimental, off by default; public pages only; non-persistent store; handoff and fallback | gate journey; no credentials, no script bridge, no file access |
| Math/Mermaid | explicit final source fallback | no renderer dependency added; not labelled as rendered |
| Cross-block selection | deferred with owner and check | per-block selection and reply Copy remain |
| Cache pressure and scope | 256 MiB media blobs, disk trim oldest finished blobs, 48 MiB memory, 64 MiB decoded; hash-verified, authentication-scoped disk/memory keys | trim, scope, credential-change, mismatch and corrupt-disk tests; device memory warning unverified |
| Download bounds | cumulative receive limit with early close; typed size failure | loopback declared/chunked/understated tests; no live large-file server test |
| Background subagent stop | interrupt active child and cancel its subtree's jobs | synthetic reducer test; live jobs unverified |

## Verified in this phase

| Command | Result |
| --- | --- |
| `swift test --package-path ios/OpenCodeKit` (P10 corrections) | **553 tests pass**: 203 server, 67 core, 75 app, 38 drawer, 70 session, 44 composer, 26 transcript, 30 media; live and loopback opt-outs unchanged |
| `ios/scripts/verify.sh --skip-ui` (P10 corrections) | toolchain 27.2 / Swift 6.4.2 / SDK 27.2; app build and `OpenCodeTests` pass; package tests pass |
| `xcodebuild ... test` (P10 correction final UI) | **70 of 70 UI tests pass** in one grouped run on the final code. An earlier full run had two P8 transcript timing failures; the nine-test `TranscriptUITests` suite then passed, and this final run also passed. The earlier flake is recorded, not claimed fixed. |
| `swift test --package-path ios/OpenCodeKit` (P10 corrections) | **553 tests pass** (separate from the UI invocation) |
| `xcodebuild … -only-testing:OpenCodeUITests/MediaUITests` | 8 journeys pass: transcript image gallery, tool mosaic, server file preview, browser gate, paste preview/remove, pasted-image send, annotation return, Dynamic Type/dark, relaunch recovery |
| `xcodebuild … -only-testing:OpenCodeUITests/MediaScreenshotUITests` | 16 light/dark screenshots captured: transcript media, image viewer, tool mosaic, file viewer, browser, composer attachment, attachment preview, annotation |
| `xcodebuild … -only-testing:OpenCodeUITests/MediaPerformanceUITests` | media-heavy scroll trace, large-image open/close metric and typing-while-attached trace; results below |
| `swift test --package-path ios/OpenCodeKit` (P8) | **421 tests pass**: 185 server, 67 core, 61 app, 38 drawer, 44 session, 26 transcript; live and loopback opt-outs unchanged |
| `ios/scripts/verify.sh` (P8) | toolchain 27.2 / Swift 6.4.2 / SDK 27.2; app build succeeds; **46 UI tests pass**; package suites pass (exit 0) |
| `swift test --package-path ios/OpenCodeKit` (P9) | **492 tests pass**: 194 server, 67 core, 75 app, 38 drawer, 66 session, 26 transcript, 26 composer; live and loopback opt-outs unchanged |
| `ios/scripts/verify.sh --skip-ui` (P9 final) | toolchain 27.2 / Swift 6.4.2 / SDK 27.2; app build succeeds; `OpenCodeTests` passes; 492 package tests pass (exit 0) |
| `xcodebuild … test` (P9 UI, grouped final invocations) | **58 UI tests pass** in three groups (12 composer/screenshot + 15 session/transcript + 31 launch/home/screenshots); no failures or flakes on this run |
| `xcodebuild … -only-testing:OpenCodeUITests/ComposerUITests` | 11/11 pass: new session, relaunch, failed send retry, session isolation, running/queued, dock, quote, Dynamic Type/dark/keyboard, long multiline draft scrolling, two typing traces |
| `xcodebuild … -only-testing:OpenCodeUITests/ComposerScreenshotUITests` | light/dark composer, quote, request dock and queued sheet captured |
| `xcodebuild ... -only-testing:OpenCodeUITests/TranscriptUITests` | 9 journeys: Markdown/tools, disclosure restoration across a subagent page, native text selection, copy, link confirmation, growth-safe following, Jump to Latest, Load Earlier anchor, Dynamic Type + dark + Reduce Motion launch flag |
| `xcodebuild ... -only-testing:OpenCodeUITests/TranscriptScrollTraceUITests` | 1,000-row scroll and 600-delta streaming traces; results in the performance table above |
| `xcodebuild ... -only-testing:OpenCodeUITests/HomeUITests` | 8 tests; the drawer journey now asserts a real transcript row instead of the P7 placeholder |
| Screenshots | `docs/ios-migration/screens/p8-{transcript,transcript-dark,transcript-tools,transcript-tools-dark,transcript-jump,transcript-jump-dark}.png` |

The 421 package tests are the sum of the six target runs the package runner printed; the gate log is in
`ios/.build-results/`.

## Not verified

- **Physical device**: no P8 run on hardware. VoiceOver reading order, cross-block selection feel, touch
  selection, real LAN streaming and memory pressure remain device checks. Simulator evidence covers layout,
  identifiers, Dynamic Type, dark appearance and frame timing only.
- **Reduce Motion**: the UI test passes the launch flag and asserts the Jump-to-Latest path renders; the
  simulator's system setting was not toggled separately. The only custom transcript animation is that jump
  glide, which reads `accessibilityReduceMotion`.
- **Cross-block selection**: not rebuilt; native per-block selection and reply Copy are what exist.
- **Live V2 server**: no compatible server with the audited `/api/session/{id}/message` routes was available.
  The documented `/api/*` route mismatch is unchanged; nothing was remapped.
- **Real transcript mutations**: no live stream or settled read ran against a production session. All tests
  use the fixture client and synthetic content.
- **Math and Mermaid**: source text only; no typesetting engine was added.
- **Visual comparison with the original app**: unavailable; October captures are evidence, not a target.
- **iPad**: out of scope (D-16).
- **P9 physical device**: no hardware run. Marked-text composition, hardware Shift+Return, VoiceOver
  order, real keyboard dismissal and memory pressure remain device checks.
- **P9 live server**: no compatible V2 server with the audited prompt/create/wait routes was available.
  Every positive send, retry, queue and dock journey used the deterministic fixture; live session mutation
  was not authorized and did not run.
- **P9 model/agent/mentions/commands**: implemented in P11 for models, agents, skills, commands and files; session mentions remain deferred.
- **P10 physical device**: no hardware run. Camera, photo-library prompts, file-provider download/eviction,
  video/audio interruptions, share sheet, mobile-network upload and real memory warnings remain unverified.
- **P10 live server**: no compatible V2 server with `paths.tmp`, `/api/experimental/fs/write` and
  `/api/experimental/media/{hash}` was available. Uploads, blobs and file reads used the fixture client or a
  scripted transport; no live mutation or remote file read ran.
- **P10 upload transport**: the route shape, progress callback and unsupported outcome are tested; the real
  `URLSession.upload(fromFile:)` delegate path has no loopback assertion because the local fixture server reads
  only what arrives with the headers. Treat physical uploads as unverified.
- **P10 browser UI test**: no external page is fetched. The browser journey serves a loopback HTML fixture from
  the UI test runner, enabled by DEBUG launch arguments; the production policy still refuses loopback.
- **P10 photo-picker video**: `PhotosPicker` is filtered to images; a video can be attached through Files and
  server video playback is covered, but picking a video in Photos is not implemented.
- **P10 file browser UI**: `fs/list` was implemented and tested in P10; P11 adds the new-session folder
  browser and file autocomplete. File cards still open their referenced file directly.
- **P10 math/Mermaid**: source fallback is final for this phase; no renderer was added.
- **P10 cross-block selection**: per-block selection and reply Copy remain; the cross-block handoff is not built.
- **Pre-existing Home deletion timing failure**: the intermittent Home deletion test remains a known
  unrelated issue from earlier phases. It was not reproduced or changed in P10 and is not claimed fixed.
- **P8 transcript UI timing flake (observed in the P10 correction full run)**: `TranscriptUITests`
  `testFollowingSurvivesTailGrowthAndBrowsingHoldsItsAnchor` and
  `testJumpToLatestAfterReadingOlderContent` failed once in the full suite and passed when the nine-test
  suite was rerun. No transcript behavior was changed in this correction, and the flake is not claimed fixed.

## Deferred P8 items — later phase and acceptance check

| Deferred item | Later phase | Acceptance check |
| --- | --- | --- |
| Composer editing, drafts, sends, queued-input sheet, steer menu and quote-to-composer | **P9 — done** | Draft survives termination; a failed send retries with a new message id; the P7 inbox remains the only input source; a quote arrives from the transcript selection |
| `/api/experimental/session/{id}/wait` loop | **P9 — done** | The send path waits for idle through the audited route without nesting retries |
| Image/media viewer, tool image mosaic, full-screen viewer and file opening | **P10 — done** | Cached media, no automatic remote fetch, safe routing; a tool image opens the viewer |
| Math typesetting and Mermaid diagrams | **P10 — source fallback final** | No maintained renderer was adopted; source is shown as code and never labelled rendered |
| Cross-block selection as one document | P14 | A reply selects across blocks with native handles; the current per-block selection is replaced only with measured need |
| Physical VoiceOver, selection and scroll checks | P14 | Each transcript row reads in order; selection handles and copy work on device |

## Deferred P9 items — later phase and acceptance check

| Deferred item | Later phase | Acceptance check |
| --- | --- | --- |
| Model, agent/mode and reasoning-variant pickers | **P11 — done** | `GET /api/model`, `/api/model/default` and `/api/agent` decode; the chosen model/agent is applied once before the next send; a refused pick leaves the composer draft intact |
| Autocomplete for files, agents, skills and slash commands; mentions | **P11 — done** | Filtering is next-frame; a chosen mention survives draft restore; the prompt carries the audited `agents`, `skills`, `files` and `mentions` shapes; file results never read local disk |
| Attachment picker, camera, photo/file uploads and inline pasted text | **P10 — done** | Size/type validation, progress, cancellation and failed-upload recovery; the + control exists and works |
| Cross-block selection for quoting a whole reply | P14 | One reply selects across blocks with native handles and the selection becomes one quote without losing the composer draft |
| IME marked text, hardware Shift+Return and VoiceOver on device | P14 | A pinyin/Japanese composition is not committed by an external draft sync; Shift+Return inserts a newline and plain Return sends; each composer control reads and activates in order |
| Folder browser for server files; picker videos | **P11 — done for folders; video remains P14** | The folder browser lists `fs/list` results without local reads; a Photos video becomes a staged upload with a poster and duration |

## Deferred P10 items — later phase and acceptance check

| Deferred item | Later phase | Acceptance check |
| --- | --- | --- |
| Session folder browser over `fs/list` | P11 | A folder row lists only server entries; no local path is opened; back/cancel keeps the draft |
| Photos-picker video import | P14 | A picked video stages a bounded file plus a poster/duration, uploads once and plays locally or from the server |
| Web page Ask / page-context prompt | P14 | Ask sends a bounded page block and selection in the audited prompt metadata, without credentials |
| Math typesetting and Mermaid diagrams | P14 | A maintained renderer is evaluated with offline, licence and untrusted-content gates; otherwise the source fallback stays final |
| Cross-block reply selection | P14 | One reply selects across blocks with native handles and becomes one quote without losing composition |
| Orphan sweep for staging folders no draft names | P14 | Launch cleanup removes staging folders unreferenced by drafts, failed sends and outbound records; a viewer-held file is not removed |
| Physical camera, photo permission, file providers, playback and sharing | P14 | Synthetic checks on hardware; denied/unavailable paths typed; share sheet receives the intended file/text |

## Next

1. P11: settings and experiments (including the in-app browser switch), shipped What's New catalogue, custom
   headers, camera QR pairing, model/agent pickers, autocomplete, mentions and the folder browser.
2. P12: system integrations (share extension/App Group, widgets, notifications).
3. P14: physical-device media checks, cross-block selection, math/Mermaid decision, orphan sweep and hardening.


## Phase 11 — what landed

| Area | New or changed path | Gate |
| --- | --- | --- |
| Settings reducer, typed preferences, navigation, server editing, diagnostics, onboarding, scan gate | `OpenCodeKit/Sources/OpenCodeSettings/SettingsModels.swift`, `SettingsFeature.swift` | `OpenCodeSettingsTests` — 15 cases: defaults, restore race, failed written preference, unavailable/corrupt appearance, experiment change, header policy, invalid form, save failure, operation fencing, diagnostics privacy, offline onboarding, exactly-once scan, camera denial, cache scope |
| Camera QR boundary | `OpenCodeSettings/QRCameraScanner.swift` | AVFoundation metadata output behind `PairingScannerClient`; simulator injects payloads through the same boundary |
| Appearance application | `ios/OpenCode/App/OpenCodeApp.swift` | `@AppStorage("appearance-color-scheme")` drives `preferredColorScheme`, with the UI-test appearance still winning |
| Settings UI, server form, diagnostics, onboarding/help, scanner presentation | `ios/OpenCode/Settings/SettingsView.swift` | `SettingsUITests` — 5 journeys: relaunch persistence, diagnostics collect/copy, onboarding offline, header edit/save, injected QR confirmation; 12 light/dark screenshots |
| Drawer entry and full-screen host | `ios/OpenCode/Drawer/HomeView.swift`, `App/RootView.swift`, `OpenCodeApp/AppFeature.swift` | Gear opens a full-screen Settings surface; edit/removal writes are operation-fenced, intent-backed and transfer the composer before reconnect/disconnect |
| Custom-header policy and cache scope | `OpenCodeServer/Address/OpenCodeServer.swift`, `OpenCodeMedia/MediaReferences.swift` | token/newline/forbidden-header validation; `authenticationScopeMaterial` includes sendable headers so a header change starts a new authenticated scope |
| Model, agent and reasoning catalogue | `OpenCodeServer/Models/ModelCatalog.swift`, `Client/CatalogOperations.swift`, `Client/OpenCodeClient.swift` | `/api/model`, optional `/api/model/default`, `/api/agent`, `/api/skill`, `/api/command`, `/api/fs/find`, and the model/agent switch posts; request shapes through the client seam |
| Composer model/agent selection, durable snapshot | `OpenCodeComposer/{ComposerFeature,ComposerModels}.swift` | picker state, variant ordering, chips/model/agent persisted in the draft, failed send and outbound record |
| Apply before send | `OpenCodeSession/SessionFeature.swift` | agent then model applied once before the prompt for ordinary and first sends; skipped for queued delivery; cancellation is checked after each dependency returns; a refused switch fails the send; `SessionSelectionTests` records order and cancellation |
| Autocomplete, mentions and trigger safety | `OpenCodeComposer/ComposerAutocomplete.swift`, `ios/OpenCode/Composer/ComposerTextInput.swift`, `ComposerViews.swift` | UTF-16 triggers, occurrence identities and maintained ranges, composition guard, bounded rows, 250 ms file debounce, generation/server/directory/query fencing, exact mention ranges and `file://` URIs; 11 pure tests, reducer edit test and UI suggestion journey |
| Remote folder browser | `OpenCodeSession/FolderBrowserFeature.swift`, `ios/OpenCode/Session/FolderBrowserView.swift` | on-demand `fs/list`, back/cancel/retry/loading/empty/error, remote-only paths, draft-preserving project switch; 5 reducer tests plus UI select/cancel journey |
| Shipped What's New catalogue | `OpenCodeDrawer/WhatsNewCatalogue.swift`, `HomeModels.swift`, `HomeView.swift` | 182 entries reconstructed from the audited Kotlin files and English resources; unique IDs/days; seen state; Try It routes are implemented or explicitly unavailable; 3 catalogue tests |
| Copy | `ios/OpenCode/Resources/Localizable.xcstrings` | 80 new settings, helper, folder and What's New keys; no translated text compared or stored |

### P11 verification

| Check | Result |
| --- | --- |
| `swift test --package-path ios/OpenCodeKit` | 618 tests pass (settings 15, composer 60, session 79, server 209, app 89, core 67, drawer 41, transcript 26, media 32) |
| `xcodebuild ... build` | app target builds for iPhone 18 Pro Max, iOS 27.2 |
| `SettingsUITests` | 5/5 pass (preference relaunch, diagnostics collect/copy, onboarding, header edit/save, injected QR confirmation) |
| `PreferenceBehaviorUITests` | 3/3 pass — Return before/after relaunch, Return answering a request without chat, Wrap Lines live toggle and before/after relaunch |
| `ComposerContextUITests` | 2/2 pass (model/agent/mention selection, folder select/cancel with draft) |
| `SettingsScreenshotUITests` | 12 light/dark captures |
| `xcodebuild … test` (P11 storage correction) | 81 UI tests ran; 80 passed in the grouped inventory and `TranscriptUITests.testFollowingSurvivesTailGrowthAndBrowsingHoldsItsAnchor` hit the known P8 anchor hittability flake. The complete nine-test `TranscriptUITests` suite then passed 9/9 on the final code. This records the flake; it is not claimed fixed. |
| Autocomplete trace (implementation probe) | `connected-composer-long`, 900 fixture transcript entries; focused UI-test elapsed from typing `@rev` through the first skill suggestion **about 2.0 s**, including XCTest input and expectation polling; simulator only. The probe was not retained in the final grouped inventory to avoid an XCUITest input flake; autocomplete itself is covered by `testModelAgentAndMentionSelection`. |
| Existing regressions | full package suite passes; P8/P9/P10 suites unchanged apart from additive fields with decoding defaults. The P10 media UI/perf harnesses now scroll rows clear of the taller P11 composer inset and wait for viewer dismissal; product behaviour is unchanged. `MediaUITests` passes 8/8 and `MediaPerformanceUITests` 3/3 with that adjustment; the large-image loop measured 5.12 s including UI-test waits. |
| Screenshots | `docs/ios-migration/screens/p11-{settings,diagnostics,onboarding,model-picker,autocomplete,folder-browser}-{light,dark}.png`, captured from `SettingsScreenshotUITests` on the iPhone 18 Pro Max simulator with the synthetic `Fixture` server and `/work/opencode` paths |

### P11 simulator-tested vs hardware-unverified

- **Simulator-tested:** preference defaults/migration/save failure/restore race; experiment write and
  browser close; server/header validation and save-failure retention; diagnostics allowlist;
  onboarding completion; injected QR parsing/confirmation/exactly-once forwarding; catalogue
  completeness and destinations; model/agent selection, payload order, refused switch and durable
  snapshot; autocomplete triggers, composition guard, occurrence ranges and mention encoding;
  folder navigation and draft preservation; server edit/removal transactions, collision/restart
  recovery and draft handoff.
- **Hardware-unverified (P12):** real camera capture and permission prompts, physical Keychain on a
  signed build, haptics, IME marked text and hardware Shift+Return, VoiceOver, photo/file provider
  eviction, playback interruptions/share, memory pressure and device performance. See
  [P12_DEVICE_CHECKLIST.md](P12_DEVICE_CHECKLIST.md).

### P11 limitations and deferrals

- Only the In-App Browser experiment is surfaced. Other audited experiments belong to P12/P13 or have
  no iOS implementation; no inert switches were added.
- Session mentions (`@session:<id>`) are not reproduced. Commands, skills, agents and files are.
- Return and Wrap Lines now drive the native composer input, request-answer bar and code viewer;
  no inert preference remains.
- Try It destinations for voice, notifications, developer tools, model-list shortcuts and prompts
  are labelled unavailable rather than navigating nowhere.
- No live V2 server with the model/agent/skill/command/find routes was available; fixture and
  request-shape coverage is recorded, not live compatibility.
- The autocomplete measurement includes XCTest input overhead and is not a device-performance claim.
