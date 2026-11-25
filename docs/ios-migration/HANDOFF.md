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
  `origin/ios` `7966dcfe`; merged as `92a7c677` (PR #6).
- `ios-transcript` — Phase 8: transcript rows, Markdown and scrolling. Reviewed head `5ea6ea65`; merged
  as `2823c06e` (PR #7), with an identical tree `1147dca8`.
- `ios-composer` — Phase 9: composer, drafts, sends, queue, request dock and quotes. Branched from
  `origin/ios` `2823c06e`; merged as `e42cb455` (PR #8), tree `62d44987` equals corrected `1fd90423`.
- `ios-media` — Phase 10: media, files, viewers, annotation, browser and rendering fallback. Branched from
  `origin/ios` `e42cb455`; merged as `0ec10ba4` (PR #9), tree `02dad71e` equals reviewed `9880eeb9`.
- `ios-settings` — Phase 11: settings, experiments, diagnostics, onboarding, QR pairing, catalogue,
  custom headers, models/agents, autocomplete and the folder browser. Branched from `origin/ios`
  `0ec10ba4`; pushed to the fork with a draft PR into `ios`.
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

P9 surfaces:

```sh
xcodebuild -project ios/OpenCode.xcodeproj -scheme OpenCode \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro Max' -skipMacroValidation \
  -only-testing:OpenCodeUITests/ComposerUITests test
xcodebuild -project ios/OpenCode.xcodeproj -scheme OpenCode \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro Max' -skipMacroValidation \
  -only-testing:OpenCodeUITests/ComposerScreenshotUITests test
```

The fixture modes `connected-composer`, `connected-composer-fail`, `connected-composer-running`,
`connected-composer-question`, `connected-composer-queue`, `connected-composer-long` and
`connected-composer-stream` are synthetic. `-uiTestResetDrafts` clears the isolated draft file before a
journey; a relaunch check launches again without it.

P10 surfaces:

```sh
xcodebuild -project ios/OpenCode.xcodeproj -scheme OpenCode \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro Max' -skipMacroValidation \
  -only-testing:OpenCodeUITests/MediaUITests test
xcodebuild -project ios/OpenCode.xcodeproj -scheme OpenCode \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro Max' -skipMacroValidation \
  -only-testing:OpenCodeUITests/MediaScreenshotUITests test
xcodebuild -project ios/OpenCode.xcodeproj -scheme OpenCode \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro Max' -skipMacroValidation \
  -only-testing:OpenCodeUITests/MediaPerformanceUITests test
```

`connected-media`, `connected-media-long` and `connected-media-large` are synthetic and open no socket. The
in-app browser gate uses `-uiTestInAppBrowser`; `OPENCODE_UI_TEST_CLIPBOARD_IMAGE=1` puts a synthetic image on
the pasteboard before launch. Both are DEBUG-only.

P11 surfaces:

```sh
xcodebuild -project ios/OpenCode.xcodeproj -scheme OpenCode \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro Max' -skipMacroValidation \
  -only-testing:OpenCodeUITests/SettingsUITests test
xcodebuild -project ios/OpenCode.xcodeproj -scheme OpenCode \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro Max' -skipMacroValidation \
  -only-testing:OpenCodeUITests/ComposerContextUITests test
xcodebuild -project ios/OpenCode.xcodeproj -scheme OpenCode \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro Max' -skipMacroValidation \
  -only-testing:OpenCodeUITests/SettingsScreenshotUITests test
```

`-uiTestResetSettings` clears the UI-test preference suite; `-uiTestPairingPayload <link>` injects one decoded
scan through `PairingScannerClient` so no camera is used. `connected-composer-long` is the 900-entry transcript
fixture used for the autocomplete trace. All P11 fixtures are synthetic and open no socket.

## Where tests run

| Suite | Location | Runner |
| --- | --- | --- |
| Core logic (tokens, storage outcomes, logging, endpoint, network guard, isolation, transport boundary, haptics, motion, bounded channel) | `ios/OpenCodeKit/Tests/OpenCodeCoreTests` | `swift test` on the host |
| Server (address, redirects, transport, retry, pairing, SSE, events, batching, stream, client) | `ios/OpenCodeKit/Tests/OpenCodeServerTests` | `swift test` on the host |
| Loopback HTTP fixture (real URLSession delegates, socket lifetimes) | `ios/OpenCodeKit/Tests/OpenCodeServerTests/LocalFixtureServerTests.swift` | `swift test`; loopback only, opt-out env var |
| Live read-only server | `ios/OpenCodeKit/Tests/OpenCodeServerTests/LiveServerTests.swift` | `swift test` with env vars; skipped by default; records contract mismatches rather than hiding them |
| App reducer, connection child, launch scenarios, store semantics | `ios/OpenCodeKit/Tests/OpenCodeAppTests` | `swift test` on the host |
| Composer reducer, drafts, send eligibility | `ios/OpenCodeKit/Tests/OpenCodeComposerTests` | `swift test` on the host |
| Composer in the session (sends, inbox, dock, quote) | `ios/OpenCodeKit/Tests/OpenCodeSessionTests/ComposerSessionTests.swift` | `swift test` on the host |
| Media imports, caches, browser policy, file viewer, annotation, composer attachments | `ios/OpenCodeKit/Tests/{OpenCodeMediaTests,OpenCodeComposerTests/ComposerAttachmentTests,OpenCodeServerTests/MediaClientTests,OpenCodeSessionTests/SessionMediaTests}` | `swift test` on the host |
| Settings, diagnostics, headers, scan gate, onboarding | `ios/OpenCodeKit/Tests/OpenCodeSettingsTests` | `swift test` on the host |
| Model/agent switches, autocomplete/mentions, folder browser | `ios/OpenCodeKit/Tests/{OpenCodeServerTests/CatalogClientTests,OpenCodeServerTests/ServerHeaderTransportTests,OpenCodeComposerTests/ComposerAutocompleteTests,OpenCodeSessionTests/SessionSelectionTests,OpenCodeSessionTests/FolderBrowserTests}` | `swift test` on the host |
| Prompt/create/wait routes and bounded wait loop | `ios/OpenCodeKit/Tests/OpenCodeServerTests/{ComposerClientTests,SessionWaitLoopTests}.swift` | `swift test` on the host |
| Platform checks (UserDefaults, endpoint encoding, launch mapping) | `ios/OpenCodeTests` | `xcodebuild test` on the simulator |
| Launch, connection, pairing and failure UI | `ios/OpenCodeUITests` | `xcodebuild test` on the simulator |
| Keychain round-trip | `ios/OpenCodeUITests/KeychainProbeTests` | `xcodebuild test`; the hostless unit bundle has no keychain entitlement, so the probe runs in the app process behind `-uiTestKeychainProbe` |
| Settings, injected QR, model/agent, mentions, folder selection, screenshots | `ios/OpenCodeUITests/{SettingsUITests,ComposerContextUITests,SettingsScreenshotUITests}` | `xcodebuild test`; fixtures only, no camera or socket |

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
  discarded, persistent `SessionRecovery` is set, and the refresh coordinator runs a bounded recovery. A
  durable boundary stored with it keeps the 200 ms settlement delay; failure keeps the requirement; only a
  successful authoritative transcript with no new overflow clears it. One immediate attempt plus one delayed
  retry, then a recoverable failure. Do not silently drop, truncate, or raise the buffer without changing that
  policy and its tests.
- Media, file opening and the browser are P10 (see the Media section below); math/Mermaid keep the source
  fallback. Composer quote actions are P9.

## Composer (P9)

- `ComposerFeature` owns text, quotes, send eligibility, failed-send recovery and draft persistence. It never
  reads the transcript and never starts a server read. `SessionFeature` scopes it and owns sends, creation,
  reconciliation, the P7 inbox and the request dock.
- `ComposerDraftStore` is one actor over an atomic JSON file; keys are `serverID|session:<id>` or
  `serverID|new:<project directory>`. Debounce is 500 ms in the reducer; Done and backgrounding flush. Limits
  are 128 KiB text / 64 KiB quotes / 200 quotes; over-limit is a typed failure and the text is kept in full.
- The native input is `ios/OpenCode/Composer/ComposerTextInput.swift` (`UITextView`). It defers external draft
  sync while marked text exists, clamps selection, grows to 168 pt, sends on Return and inserts a newline on
  Shift+Return. Do not replace it with a `TextField` that writes the whole value per keystroke.
- A send persists `ComposerOutbound` (target, message ID, text, quotes, delivery) before dispatch. A blocked
  save does not dispatch; an offline/request-blocked delegate restores the payload; an unresolved record after
  termination reopens as an unverified (ambiguous) failed send with its original ID and target, never as
  editable text.
- A send is admitted under a client message ID. A definite rejection can be retried under a new ID that is
  written to the outbound record before the delegate runs. An ambiguous result is reconciled with
  `GET /api/session/{id}/message/{id}` and the inbox before any retry; when the old ID is confirmed absent,
  `ComposerFeature` replaces the outbound record with the new ID and saves it before the prompt. A failed save
  sends nothing and restores the prior identity. An unreadable reconciliation is shown as unverified and never
  duplicated. Results, optimistic rows and restarted records use the dispatched ID; they never fall back to a
  different outbound record.
- `SessionWaitLoop` is the only retry owner for `POST /api/experimental/session/{id}/wait`: 25 s polls, a 20 s
  fast threshold, 12 fast failures, an active probe, and a caller-owned `.once` escape. A completed wait asks
  the existing settlement read; it never opens another stream or read queue.
- The composer follows the active page. Opening, pushing, popping or switching a page saves the outgoing
  draft/outbound record and loads the destination’s; a child send uses the child ID. A send result that arrives
  after navigation resolves the operation’s own target record and cannot touch the visible draft.
- The P7 inbox remains the only queued-input model. The composer sheet sends Send Now (PATCH steer), moves to
  queue (PATCH queue) or cancels (DELETE); an idle stranded item reuses queue-then-steer.
- While any request is pending, the request dock owns the input bar. Permissions and questions/simple fields
  answer there; larger forms keep the P7 sheet. The chat draft is not parked into request state and cannot be
  sent by the answer bar’s Return.
- Quotes are one block’s selected text plus an optional comment. The send body appends the audited quoted block
  to the model text and writes `{"type":"quote"}` to `metadata.comments`.
- Project-to-session draft migration writes the destination first, removes the source only after success, and
  skips a newer destination (timestamp, then revision). A source keeps `createdSessionID` so a restart can
  recover it. Draft records carry a monotonic `revision`; records written before it decode as revision 0.
- Done uses an explicit flush request/identity and a content snapshot. If text, quotes, failed sends or the
  outbound changed while persistence was suspended, the composer saves the newer content before reporting
  success; a failure keeps the session open with a notice. Replacement, server switch, disconnect and
  interactive dismissal transfer the draft through an App-owned effect before the child disappears. A failed
  transfer is retained under its server/key in `AppFeature.retainedDraftTransfers`, surfaced as `draftKept`,
  and retried on launch, foreground and navigation. `saveIfNewer` compares timestamp then revision, so an old
  transfer never replaces newer typing after returning to the session. There is no dismissal timer.
- Long input grows to 168 pt, then scrolls internally with the caret/selection visible.
- Model/agent/mode pickers, autocomplete, mentions and attachments are P10/P11 surfaces and now exist; the
  P9 send path applies the chosen model/agent before the prompt and snapshots them into the outbound record.

Composer surfaces: `ios/OpenCode/Composer/*`, `OpenCodeKit/Sources/OpenCodeComposer`, the send/inbox/dock
parts of `OpenCodeKit/Sources/OpenCodeSession`, and the Home New Session entry. Screenshots:
`docs/ios-migration/screens/p9-{composer,composer-quote,quote,request-dock,queued}[-dark].png`.

## Media (P10)

- Attachments are app-owned staged files under Application Support, referenced by `storedName` in the P9
  draft/failed/outbound records. Never persist a picker or security-scoped URL. The file store opens and closes
  the scope around its copy. Writes stage under `.staging` and move into the final directory only after
  completion; launch cleanup deletes only that namespace, never a filename ending in `.tmp`/`.partial`.
- A staged source is released only after the owning record is durably saved and no current, parked, failed,
  outbound, persisted or leased reference needs it. Upload completion, removal and accepted sends queue a
  release; a failed save or a viewer lease keeps the file. The 256 MiB media disk cache and 48/64 MiB memory
  tiers are Caches only and are authentication-scoped.
- Uploads carry the originating server/key, attachment ID and monotonic attempt. A hidden completion merges
  into the parked/persisted draft without replacing newer text; an old attempt cannot overwrite a retry; a
  persistence failure is retained and retried when the owner is visible. The remote upload path is
  `<tmp>/uploads/<attachmentID>/<name>` and is stable across retries; the protocol has no resume. An
  interrupted upload restores as `.failed(.uploadInterrupted)` with its source.
- The prompt carries inline images/pastes as `data:` file parts, uploaded files as path reference lines and
  `metadata.attachments`, and quotes as `metadata.comments`.
- Viewers are native. Remote video/audio/PDF is downloaded through the authenticated client into a Caches
  scratch file before playback; closing a gallery does not mutate transcript or composer. Images decode
  off-main into a bounded cache. A tool mosaic uses the same gallery as user images.
- Server file paths are remote identifiers: `AgentFilePath` produces `(location, relativePath)`, `fs/read` is
  bounded to 2 MiB for previews, and code highlighting is capped at 64 KiB/1,500 lines/4 KiB lines.
- The browser is Experimental, off by default, with a non-persistent store, no script bridge, no file access,
  no server credentials and public pages only. Downloads, private hosts and other schemes are handed to the
  system. A failed load shows Try Again. UI tests enable a DEBUG loopback page with
  `-uiTestInAppBrowser -uiTestBrowserLoopback`; production still refuses loopback. Ask/page context is
  deferred to P14.
- Math remains source in a code band and Mermaid an ordinary fenced block (D-87). Cross-block selection
  remains per-block + reply Copy (D-88).
- Background subagent stop interrupts an active child and cancels its subtree's jobs. Shell output has Copy
  and Share. The share extension/App Group remains P12.

Media surfaces: `ios/OpenCode/Media/*`, `ios/OpenCode/Composer/{ComposerViews,CameraCaptureSheet}.swift`,
`OpenCodeKit/Sources/OpenCodeMedia/*`, and the viewer/file/browser parts of `OpenCodeSession`. Screenshots:
`docs/ios-migration/screens/p10-*`.

## Settings and composer context (P11)

- `SettingsFeature` (`OpenCodeKit/Sources/OpenCodeSettings`) owns the Settings stack, typed preferences,
  server form, diagnostics facts/report, onboarding steps and the scan gate. Credentials and the saved
  server list remain the app shell's: Settings delegates save/forget and keeps the form open until the
  shell reports a result. A failed write is shown, never presented as saved.
- Preference keys are the audited ones: `appearance-color-scheme`, `return-key-sends`,
  `file-viewer-wraps-lines`, `experimental-in-app-browser`, `onboarding-completed`. A delayed restore
  fills only untouched fields, and every successful write reaches the App/Session consumers.
- Return is consumed by the `UITextView` bridge: plain Return sends only when enabled, Shift+Return
  always inserts a newline, marked text is untouched, and the request-answer bar routes its Return to
  the request submit action. Wrap Lines is consumed by the file viewer and can be toggled live there;
  both preferences have before/after-relaunch simulator journeys.
- Only the In-App Browser experiment is surfaced. Disabling it closes an open browser through
  `SessionFeature.browserExperimentChanged`. Do not add inert switches for features owned by P12/P13.
- Custom headers are token-character names with no line breaks; `Authorization`, `Proxy-Authorization`,
  `Host`, framing, connection and upgrade fields are refused. The saved form is validated before the
  shell writes. `authenticationScopeMaterial` includes sendable headers, so a header change starts a new
  authenticated media-cache scope. The existing redirect rule keeps headers on their origin.
- Diagnostics are built from `DiagnosticFacts` only: version/build, phase/failure kind/status and counts.
  There is no free-form error text. Collection is user initiated and Copy uses the pasteboard dependency.
- `PairingScannerClient` is the camera boundary. Production uses AVFoundation metadata output; tests and
  simulator journeys inject decoded payloads through the same client. The scanner never parses, confirms
  or redeems; the shell's existing pending confirmation and pairing redemption stay authoritative.
- The shipped What's New catalogue is generated from the audited Kotlin entry files and English
  resources (`WhatsNewCatalogue`, 182 entries). IDs and days are permanent. Try It routes to a new session
  or Settings where implemented; all other destinations render an explicit unavailable line.
- `ComposerFeature` owns `selectedModel`, `selectedAgent`, autocomplete state and mention chips. The
  catalogue is loaded per server+directory; file results carry a generation and are ignored when the
  server, directory or query changed. Marked IME text closes suggestions rather than committing.
- `SessionFeature.startComposerSend` applies the agent then model once, immediately before the prompt,
  for ordinary and first sends; queued delivery does not change the run's model. Cancellation is checked
  after each dependency returns and before every later mutation. A refused switch fails the send. Model,
  agent and chips are persisted in the draft, failed send and outbound record.
- Each mention occurrence owns a unique ID and UTF-16 range. The text bridge reports the minimal edit;
  ranges before it shift, edits touching the token invalidate it, and `ComposerMentionBuilder` never
  searches for display text at send time. Occurrence identity and ranges are persisted in drafts.
- `FolderBrowserFeature` reads `fs/list` on demand, keeps remote paths opaque and changes a new session's
  project without clearing the draft. It is a `@Presents` child of the session.
- `ServerWriteTransaction` writes a Keychain intent before the two saved-server records and rolls both
  back on failure/restart. Settings and App fence edits by operation UUID and previous identity; active
  reconnects/removals transfer the composer draft first.
- Surfaces: `ios/OpenCode/Settings/*`, `ios/OpenCode/Session/FolderBrowserView.swift`,
  `ios/OpenCode/Composer/{ComposerTextInput,ComposerViews}.swift`, `OpenCodeSettings`,
  `OpenCodeComposer/ComposerAutocomplete.swift`, `OpenCodeSession/FolderBrowserFeature.swift`.
  Screenshots: `docs/ios-migration/screens/p11-*`.

## Test conventions

- Swift Testing for reducers, dependency clients, transport decoding, persistence and formatting.
- Every test uses a temporary directory, an in-memory Keychain double, a fixed clock and a deterministic ID
  generator. Storage failures are exercised with `FailingStorage`/`ScriptedKeychainOperations`, never by
  provoking a real keychain error. Reaching a real host is a failure; live checks are opt-in behind environment variables that are not
  set by default.
- Tests assert English copy for user-visible strings.

## Where the work stands

`PHASES.md` maps this repository onto the audit plan's P2–P14 numbering. P1–P10 are merged into `ios`
(P10 as `0ec10ba4`). P11 is implemented on `ios-settings` (draft PR into `ios`). The transcript's state
boundaries are P7's refresh identity plus P8's per-session `TranscriptState`; the composer sits above both and
borrows the same settlement read; media viewers and the browser are `@Presents` children of the session;
Settings is a full-screen child of the app shell.

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
| Composer reducer, drafts, quotes, failed sends | `OpenCodeKit/Sources/OpenCodeComposer/ComposerFeature.swift` |
| Draft persistence and bounds | `OpenCodeKit/Sources/OpenCodeComposer/ComposerDraftStore.swift` |
| Composer native input, dock, answer bar, queued sheet, quote selection | `ios/OpenCode/Composer/{ComposerTextInput,ComposerViews}.swift` |
| Prompt/create/wait/cancel routes and the wait loop | `OpenCodeKit/Sources/OpenCodeServer/Client/PromptOperations.swift`, `Retry/SessionWaitLoop.swift` |
| Session screen, subagents, request sheet, background/output sheets | `ios/OpenCode/Session/SessionView.swift` |
| Media staging, import, blob cache, code preview, viewers, browser, annotation | `OpenCodeKit/Sources/OpenCodeMedia/*` |
| Media SwiftUI: viewer, file viewer, browser, annotation | `ios/OpenCode/Media/*` |
| Composer attachments, + menu, camera | `ios/OpenCode/Composer/{ComposerViews,CameraCaptureSheet}.swift` |
| Media upload/blob/fs routes and streaming upload transport | `OpenCodeServer/Client/MediaOperations.swift`, `OpenCodeCore/Transport/URLSessionTransport.swift` |
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

### P11 evidence

- `swift test --package-path ios/OpenCodeKit` (correction): 618 tests pass (15 settings, 60 composer,
  79 session, 209 server, 89 app, 67 core, 41 drawer, 26 transcript, 32 media).
- Final grouped UI inventory on the storage correction: 80/81, with the known P8 anchor hittability flake; the nine-test TranscriptUITests then passed 9/9. `PreferenceBehaviorUITests` covers
  Return before/after relaunch, Return in the request-answer bar, and Wrap Lines live plus relaunch.
- P11 package regressions include gated catalogue load/reload/navigation, occurrence ranges and Unicode,
  transaction failure at each step/collision/restart, intent ownership, operation fencing, active/non-active edits, removal draft
  ownership, late completions and cancellation after an agent switch.
- Screenshots: `docs/ios-migration/screens/p11-*` (synthetic fixture only).

### P10 evidence

- `swift test --package-path ios/OpenCodeKit`: 553 tests (203 server, 67 core, 75 app, 38 drawer, 70 session,
  44 composer, 26 transcript, 30 media).
- `ios/scripts/verify.sh --skip-ui`: app build and `OpenCodeTests` pass; package tests pass.
- Final grouped UI run: 70/70 pass. An earlier run had two P8 transcript timing failures; the nine-test
  `TranscriptUITests` suite then passed, and the final run passed too. The flake is recorded, not fixed.
- `swift test --package-path ios/OpenCodeKit` (separate): 553 tests pass.
- `MediaUITests`: eight journeys — image gallery, tool mosaic, server file preview, browser gate, paste
  preview/remove, pasted-image send, annotation return, Dynamic Type/dark and relaunch recovery.
- `MediaScreenshotUITests`: 16 light/dark captures in `docs/ios-migration/screens/p10-*`.
- `MediaPerformanceUITests` (corrections): media-heavy scroll 129–132 frames, p50 16.7 ms, p95 34.6–35.8 ms,
  peak 29.7 MB; large image open/close 5.06 s loop average; typing with an attachment 6.5 ms average /
  32.0 ms max.
- Deferred: picker videos (P14), Ask/page context (P14), math/Mermaid
  and cross-block selection (P14), physical camera/permissions/playback/sharing (P14).

### P9 evidence

- `swift test --package-path ios/OpenCodeKit`: 492 tests (194 server, 67 core, 75 app, 38 drawer, 66
  session, 26 transcript, 26 composer).
- Full XCUITest suite: 58 tests pass; `ComposerUITests` adds eleven journeys, including relaunch, failed-send
  retry, separate session drafts, running/queue management, dock vs chat, quote handoff, Dynamic Type/dark,
  long multiline scrolling and two typing traces.
- Screenshots: `docs/ios-migration/screens/p9-{composer,composer-quote,quote,request-dock,queued}[-dark].png`.
- Simulator typing trace: long static transcript 6.6 ms average / 24.3 ms max across 34 changes with no
  Markdown reparse; streaming 9.1 ms average / 14.8 ms max across 17 changes.
- Deferred: cross-block selection (P14), physical IME/hardware-keyboard/VoiceOver checks (P12); model/agent pickers, autocomplete and mentions are P11.
  physical IME/hardware-keyboard/VoiceOver checks (P14).

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
| Camera QR pairing | **P11 simulator done; P12 device** | Injected payloads reach confirmation once; physical scan and denied camera are in [P12_DEVICE_CHECKLIST.md](P12_DEVICE_CHECKLIST.md). |
| Custom headers | **P11 done for logic; P12 Keychain** | Token/newline/forbidden validation; headers stay on their origins; a failed save keeps the old server. |
| Copied error report | **P11 done** | Typed facts only; the privacy test rejects synthetic credentials, headers, addresses, pairing codes and content markers. |
| Haptics feel | P12 | Eleven haptics felt and distinguished on hardware; simulator unverified; see the device checklist. |
| Local-network prompt / real socket | P12 | Denied prompt → no fixture request and unreachable copy; allowed → fixture request; real background/foreground socket reconnect; see the device checklist. |
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
