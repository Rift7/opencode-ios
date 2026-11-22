# iOS migration — decisions

Recorded decisions for the native rebuild. Each decision names what it replaces so the audit evidence stays
distinguishable from a current choice.

## Two ID namespaces

Two different documents numbered their decisions `D-1…`, so a bare "D-7" has been ambiguous. They are now kept
apart:

- **`P-n`** — the *plan* decisions in `audit/PLAN.md` ("Decisions needed before or during P3"). These describe
  open product/platform questions. That file prints them as `D-1…D-9`; they are cited here as `P-1…P-9` to avoid
  the collision with the implementation series.
- **`D-n`** — the *implementation* decisions in this file. These record what the code does now.

| Plan ID | Subject (audit) | Resolved by | Still open |
| --- | --- | --- | --- |
| `P-1` | Typography and colour system | D-1 (typography), D-2 (colour) | — |
| `P-2` | Transcript motion | — | **open** |
| `P-3` | Composer text input | — | **open** |
| `P-4` | Photo picking | — | **open** |
| `P-5` | Glass | — | **open** |
| `P-6` | Branch location | D-3 | — |
| `P-7` | Bundle id, team, App Group, Keychain service | D-8 (historical values are evidence), D-15 (service configurable), D-32 (service derives from bundle id) | owner-supplied bundle id/team before distribution |
| `P-8` | iPad | D-16 (out of scope) | — |
| `P-9` | Push notifications | — | **open** (default: Experimental, off) |

Later documents cite `P-n` for plan questions and `D-n` for implemented choices. If a new plan decision is
needed, continue the `P-` series; if an implementation choice changes, supersede it with a new `D-`.

## Owner-set direction, and the decisions that follow it

### D-1 Typography — system fonts only
Interface text uses the system SF font; code, logs, tool output and other monospaced content use system SF Mono.
No font files are bundled. Berkeley Mono, Inter and OpenMono are not migration defaults.

- Replaces: plan question `P-1`, and the Android baseline's Inter + OpenMono desktop typography.
- Evidence kept: the recovered iOS dossier records SF for UI and SF Mono for code; Berkeley Mono appears only in
  onboarding and no licence text is recoverable.
- Implementation: `OpenCodeTypeTokens` stores sizes/weights/design as plain data and exposes `Font` accessors
  built with `Font.system(...)`. Tests assert the token data, never a font file.

### D-2 Colour — separate from typography, native semantic tokens
Colour is decided independently of D-1. The established brand direction is preserved through native semantic
tokens that resolve per appearance, rather than by porting a palette wholesale.

- Implementation: `OpenCodeColorTokens` exposes semantic names (canvas, raised surface, code band, user bubble,
  text tiers, border, accent, link, signal, danger, warning, success) resolved from light/dark values through
  `Color(uiColor:)` dynamic providers.
- Provenance of the values: the hex set is the desktop token palette carried in the Android baseline
  (`BrandPalette`), not a recovered iOS theme. The owner set the direction, not these individual values; they
  remain reviewable and are covered by contrast tests rather than treated as parity.
- Gate: contrast tests in both appearances for body text on canvas/surface, and for the link/accent on canvas.

### D-3 Worktree and branch model
Native implementation happens in a separate worktree; the Android checkout stays untouched. `ios` is the
integration branch, created from the audited `origin/dev` commit. Each implementation issue gets a task branch
from `ios` (for example `ios-foundation`, `ios-networking`), pushed to the fork, with a draft PR into `ios`.

- No merge, no default-branch change, no release, no distribution.

### D-4 Dependencies — TCA pinned exactly
`swift-composable-architecture` is pinned to `1.26.2` (exact). Verified: tools version 6.4, Swift 6 language mode,
iOS 16+ platform, and a successful build against Xcode 27.2 for `iOS 27.2`.

- Replaces: the audit's proposal with the same version, now pinned rather than proposed.
- Rationale: the Kotlin store mirrors TCA; reducer ordering, cancellation identity and deterministic tests are
  preserved rather than replaced with view models.

## Engineering decisions

### D-5 Macro validation — documented, narrowly scoped
Xcode 27 refuses to build SPM macro targets until each plugin is trusted. Exact reproduction and scope are in
`docs/ios-migration/TOOLCHAIN.md`. This project does **not** disable macro validation globally, does not write
Xcode defaults, and does not add a global `xcodebuild` flag to any shared configuration.

- Local/CI verification may pass `-skipMacroValidation` on the `xcodebuild` invocations for this scheme.
  `ios/scripts/test.sh` adds it to its `build` and `test` commands only (two invocations, with a comment stating
  the scope); `ios/scripts/verify.sh` delegates to that script, and `--package-only` runs no `xcodebuild`.
- Preferred on a developer machine: accept Xcode's per-plugin trust prompt once.

### D-6 Default actor isolation
The app target uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` with complete strict concurrency, matching the
Kotlin store's main-thread queue and the recovered project's documented isolation.

Package targets stay nonisolated and mark the types that need the main actor (`@MainActor`), because Foundation
and URL-loading types are not main-actor bound and a blanket default forces `nonisolated` overrides on every
URLProtocol and XCTest seam. XCTest targets are nonisolated for the same reason: `XCTestCase` overrides a
nonisolated `setUp()`.

Work that must leave the main actor gets an explicit actor, not `nonisolated(unsafe)`.

### D-7 Audit evidence retention
Audit reports are copied into `docs/ios-migration/audit/` after sanitising machine-specific and personal details.
The originals stay outside the repository. Technical meaning, repository-relative paths, public URLs, commit SHAs
and protocol identifiers are preserved.

### D-8 Historical identifiers are evidence, not configuration
Bundle identifier, team identifier, keychain service name and App Group from the recovered dossier are recorded as
evidence only. The rebuilt app uses owner-supplied signing, identifiers and Keychain service.

### D-9 Branch dispositions are recommendations
The audit's `adopt` labels refer to the Android project and were not imported. Only behaviour with native
relevance is adopted; platform-specific dependency, packaging, crash-workaround and CI changes stay out of the
iPhone app.

### D-10 Project generation — XcodeGen from a checked-in spec
`ios/project.yml` is the source of truth; `xcodegen generate` produces `OpenCode.xcodeproj`, which is not
committed. Verified with XcodeGen 2.48.0.

- Why: a generated project is reproducible, reviews as text, and avoids a binary project file that drifts from
  the build settings it claims. The recovered project also used a project spec (`project.yml`), so the shape is
  familiar without copying anything from it.
- Consequence: a target, scheme or build setting is added in `project.yml`; hand edits to the generated project
  are lost on the next generation.

### D-11 Test placement — package logic, TCA-free Xcode unit target, XCUITest
- Logic, reducers, transport and persistence are tested by the Swift package (`swift test`, Swift Testing) on the
  host, so they run without a simulator.
- The Xcode unit-test target is hostless and links only `OpenCodeCore`, `OpenCodeServer` and
  `OpenCodeTestSupport`. It carries platform checks (UserDefaults storage, endpoint encoding, launch
  configuration).
- Reducer tests live in the package (`OpenCodeAppTests`) because an app-hosted bundle that linked
  `ComposableArchitecture` failed to link in this configuration; see `TOOLCHAIN.md`.
- UI automation is XCUITest and covers the launch smoke states through launch arguments.

### D-12 App logic in the package
`OpenCodeApp` is a package target holding the app reducer and launch configuration, with no SwiftUI dependency.
The app target keeps the entry point and views. This keeps reducer tests deterministic and simulator-free while
leaving view code free to use SwiftUI.

### D-13 Strings in the scaffold
The first scaffold defines its copy as literals inside the four launch views, because there is no screen yet to
own resources and no translation pipeline in this phase. The first feature phase moves user-visible text into
string catalogs before adding more screens. Protocol constants, identifiers and log messages stay literals.

### D-14 HTTP through one dependency seam
Every request goes through the `HTTPTransport` dependency (`OpenCodeCore/Transport`). Features never create a
`URLSession`; a source test fails if any file outside the transport and the test-only guard mentions
`URLSession(`, and no file may use `URLSession.shared`.

- The live value is currently inert (`TransportError.notConfigured`) because the client does not exist yet. The
  networking phase replaces it in this one file.
- The test value always throws `TransportError.blocked`, and a test resolves it without an override, so a test
  context that forgets a dependency cannot reach the network.
- This is a boundary, not a mock library: phase 4 adds fixture responses by overriding the dependency.
### D-15 Keychain service is application-defined and configurable
`KeychainStorage(service:)` takes the service name from its caller; nothing is hard-coded. Tests and the
in-app probe always use a unique service name, so runs cannot see each other's items and no real application
service is touched.

- A Keychain service is an application-defined string, not an Apple-issued credential, so it does not block
  implementation. `SharedKeys` ships one keychain-backed key (`paired-servers`) to prove the path.
- Production identifiers (bundle id, App Group, Keychain service) must be settled **before real user
  credentials are stored**. Until then the app is exercised with disposable services only.
- Every storage operation returns an explicit outcome — `value`, `missing`, or `failure(.unavailable/.denied/
  .encoding/.other)` — and writes/deletes report success only on success. A denied or unavailable keychain is
  never reported as a missing credential; only a genuinely absent or undecodable value may fall back to the
  key's default.
- No Apple account setting, signing identity or entitlement is changed by this decision.

### D-16 iPad is out of scope
iPhone only for this migration. `TARGETED_DEVICE_FAMILY = 1`; no iPad layout, multitasking or size-class work
is planned until the product requirements ask for it.

### D-17 Layout tokens — spacing and radius carried from current `dev`
`OpenCodeSpacing` and `OpenCodeRadius` hold plain point values; `OpenCodeRadius.clamp(_:height:)` keeps an
animated corner at or below half its height.

- Source of the values: `core/src/main/kotlin/ai/opencode/core/ui/OpenCodeShapes.kt` at `dev = 7358160e`
  (last changed `f79a895e`, 2026-11-14). Freshness gate: no later commit changed the grid or the radius scale,
  and the parity corpus records no competing iOS table, so the values are applicable rather than superseded.
- Not a port: the recovered iOS dossier has no radius or spacing table in this repository, so these are native
  point tokens. They are reviewable values, covered by tests, not a parity claim.
- Spacing stays a flat grid (`s1`…`s32` plus `screenHorizontal`, `stack`, `group`) and radii stay small
  (`4…16`), so no view invents a value and no capsule appears by accident.

### D-18 Motion — a vocabulary, not decoration
`OpenCodeMotionRole` keeps the fourteen role names from current `dev`
(`core/src/main/kotlin/ai/opencode/core/motion/MotionRole.kt`, last changed `583487e7`, 2026-11-18) and resolves
one curve per phase: a spring, an ease-out or an ease-in-out. Numbers come from `MotionConstants.kt`
(`cd3cbffa`, 2026-11-18). Reduce Motion collapses every role to one 0.20 s ease-in-out cross-fade
(`OpenCodeMotionRole.curve(phase:reduceMotion:)`), and `OpenCodeMotionReduce` neutralises offset, scale, blur
and rotation so only opacity changes — the audited rule that Reduce Motion drops travel but never cuts.

- Native adaptation, recorded: SwiftUI's `.spring(duration:bounce:)` treats `duration` as a perceptual
  duration, while the Kotlin/Compose side derives `ω = 2π / duration`. Role names, phase pairs and bounce
  values are carried over; exact curve shape is not claimed to match Android frame for frame.
- P3 adds no animation. This is data plus a policy; a screen that uses a role owes the PR an answer to "how
  often will someone see this", per `ios/AGENTS.md`.
- Gate: `MotionTests` (every role and phase resolves, exits shorter where the role has both, reduce motion
  collapses to one curve, pose reduction, stagger cap).

### D-19 Haptics — one vocabulary, inert by default in tests
`Haptic` keeps the eleven names from current `dev` (`core/.../haptics/HapticsClient.kt`, last changed
`f79a895e`, 2026-11-14) and maps each to platform-neutral `HapticFeedback`. `HapticsClient` is a
`DependencyKey` with `play` and `prepare` closures, matching the Kotlin client's pair.

- Live value: UIKit `UIImpactFeedbackGenerator`, `UISelectionFeedbackGenerator` and
  `UINotificationFeedbackGenerator`, guarded by `applicationState == .active` so a background effect is silent.
  The generators are main-actor bound, so the client hops to the main actor when a caller is elsewhere and runs
  synchronously when it is already there; there is no `@unchecked Sendable` or `nonisolated(unsafe)` here.
- Test value: `HapticsClient.inert` — empty closures. A test that forgets to override reaches nothing, and
  `DependencyIsolationTests` fails a dependency key that omits a test value.
- UIKit exists only under `#if canImport(UIKit)`, so the host `swift test` build resolves the inert client and
  the simulator build compiles the live one.
- Unverified: whether the feels are right on hardware. No Taptic Engine exists in the simulator, and no device
  run was performed. Reported as unverified in `STATUS.md`, never as passed.

### D-20 Store semantics are verified on representative compositions
The four migration gates (ordering, cancellation identity, child-first `ifLet`, presented-child cancellation
on dismissal) are tested with small reducers written for the test target, not by porting TCA's own suite and
not by translating the Kotlin store.

- Why: no product feature reducer exists yet in P3, so a test over a representative shape is the honest gate.
  Feature phases add their own exhaustive tests; these four stay as the contract.
- Semantics adopted with TCA 1.26.2, and measured rather than assumed:
  - a `presented` action reduces the child first, then the parent, so the parent observes post-child state;
  - child effects are scoped to a navigation identity, so dismissing the child or changing its identity
    cancels them;
  - for non-`Identifiable` child state the identity is the key path, so *replacing* one value with another
    does not cancel — identity change means `Identifiable` id or enum-case change. This matches the Kotlin
    store's default `childID = { it::class }`.
  - `.dismiss` on a non-ephemeral child leaves the state in place; the parent clears it, and clearing it is
    what cancels the child's work. The tests assert both the cleared state and the silence afterwards.
  - cancellation ids are path-qualified: `_CancelID` carries the navigation path, so the same local id in two
    child paths is two registrations. `PathIndexedCancellationTests` holds that with one parent, two children
    of the same reducer and the local id `"ticker"` in both — cancelling one child leaves the sibling running.
    Removing the child's `.cancel` makes the test fail with the stopped child's ticks, so the assertion is not
    vacuous.
- Rejected: reimplementing reducer composition or a custom `TestStore`, or replacing reducers with view models.


### D-21 Time is a dependency — `ClockClient`
Retry schedules, the event watchdog and the flush timer read `ClockClient` (monotonic `now` plus an
injectable `sleep`) instead of calling `Task.sleep` or `Date()`.

- Replaces: nothing; it fills the gap left when P3 shipped `DateClient` (wall clock only).
- Test values: `ClockClient.testValue` returns immediately without moving time; `.recording()` records every
  requested wait and advances virtual time; `.gate()` suspends until the test releases each wait. A retry
  schedule therefore runs in microseconds and is asserted by its recorded waits.
- Live value: `DispatchTime.uptimeNanoseconds` and `Task.sleep`, so a suspended wait is cancellable and does
  not drift with wall-clock changes.
- Source: the audited `Clock` dependency (`core/.../dependencies`), which every retry loop and watchdog
  resolved; the exact API is native because Kotlin coroutines and Swift tasks differ.

### D-22 The transport seam carries requests, responses and streams
`HTTPTransport` is now `send(HTTPRequest) -> HTTPResponse` plus `open(HTTPRequest) -> HTTPStream`, replacing
the completed-`Data`-only seam. `HTTPStream` delivers body chunks as they arrive; an SSE connection is never
buffered into a completed response and is never replaced by polling.

- **Credential scope is structural.** `HTTPRequest` carries headers and an `Authorization` value bound to its
  own URL; `HTTPRedirectRule` re-applies them on a same-origin hop and refuses a hop that changes scheme,
  host or effective port. A 3xx from a policy that rejects redirects is delivered as the response, because
  that is the audited behaviour for pairing redemption.
- **Bounded delivery.** `BoundedChannel` (Mutex-guarded, pull-based) is the only buffer between a URLSession
  delegate and a consumer. A full buffer is an overflow, never a dropped element: the connection ends so the
  owner reconnects and rehydrates from REST. The same rule covers SSE events (128) and body chunks (64 × ≤16
  KiB).
- **Cleartext policy** is enforced twice: ATS in `Info.plist` (local networking plus named overlay domains)
  and `TransportSecurity` before a byte is sent. Nothing disables certificate validation, and there is no
  pinned certificate to copy.
- **Local-network permission** (`NSLocalNetworkUsageDescription`) is required from iOS 14 for a LAN server;
  it is declared, and the prompt itself is a device-only behaviour that no simulator test can pass.
- `@unchecked Sendable` appears at four places in the transport, each a `Mutex`-guarded class whose mutation
  must stay synchronous: `BoundedChannel`, the URLSession redirect guard, the stream receiver and the
  stream-activity holder. Each carries a one-line reason at the declaration; no `nonisolated(unsafe)` is
  used. The test-only loopback server follows the same discipline (D-28).
- Rejected: a `URLProtocol`-based fixture for redirect integration tests. A custom protocol synthesizes the
  redirect inside the protocol stack, so the session delegate is never consulted; the redirect decision is
  therefore tested as a pure rule, and the session wiring stays thin. `PROTOCOL_COVERAGE.md` says so.

### D-23 Event batching adopts ordering and bounds; transcript pressure shedding waits for P8
`EventBatcher` adopts the audited flush (`75 ms` or 256 pending mutations), delta coalescing, per-session
order, the non-content flush barrier and the bounded downstream (`128`, overflow ends the connection).

- Not adopted yet: the off-screen delta shedding and the Markdown pre-projection hooks. Both exist to protect
  a transcript reducer and a Markdown cache; neither exists before P8. Implementing them now would mean
  guessing what “focused” and “pressure” mean without a consumer.
- The SSE parser accepts the general frame syntax (CRLF/CR, multi-line data, `event:`/`id:`, comments) rather
  than the server's current one-line shape, so a framing change upstream cannot corrupt the stream. It keeps
  the audited 16 MiB frame bound.
- `EventStreamRunner` owns the reconnect loop (audited `stream` policy: 1 s base, fast for 15 s, then up to
  5 min) and stops after one 401. The watchdog (4.5 s connect, 45 s idle) is enabled in the app; a caller
  that owns its own lifetime can disable it.

### D-24 Pairing is parsed without side effects and redeemed explicitly
`PairingLink` is a value: it has no transport, no client and no callback, so a paste, a share preview or a
link unfurl cannot spend a one-time code. Redemption is `OpenCodeClient.redeemPairing`, which tries every
reachable candidate once (`.unsafe`, 15 s, redirects refused, no `Authorization`) and stops at the first
success.

- Only one candidate reaches the server successfully because the code is single-use; concurrency is bounded
  by the candidate list.
- Failure copy is typed (`pairingExpired`, `pairingUnsupported`) rather than a status the UI has to
  reinterpret; `ServerCopy` supplies the sentence, and tests assert it.
- Credentials are stored per server entry and applied by origin. Pairing's returned token is never sent to
  any other candidate or redirect target.
- Saved-server replacement keeps local settings (`keepingLocalSettings`) and address order is preferred from
  the code's own list, as the audited model does.

### D-25 P4 has no connection or session UI
`OpenCodeClient` is reachable as a dependency, but the app's launch states still use the inert probe from
P2/P3. Wiring the client to the app is P5's change, so this phase cannot accidentally present a half-built
connection flow.

- Superseded by D-34 in P5: the probe is gone and `ConnectionFeature` owns the client boundary.

### D-26 Session ownership — one request session, one per stream
`URLSessionTransport` owns two kinds of session, deliberately:

- **Requests** share one lazily created `URLSession` for the transport's lifetime. It has no delegate,
  is ephemeral (no cookies, no cache) and is never invalidated by a request; it lives until the
  transport does. Creating a session per request was a defect in the first P4 revision: it made the
  documented "one ephemeral session" untrue, paid TLS/connection-pool setup on every call and left
  sockets to be reclaimed by `URLSession`'s own idle timeout.
- **Streams** get one `URLSession` per connection, because the data delegate and its startup state
  belong to that connection. The receiver takes ownership in `adopt(session:)` and invalidates it on
  completion, cancellation, overflow or explicit close, so a dropped stream cannot keep a task or a
  socket alive.

Tests count session constructions through the injected configuration closure: two requests build one
session, two streams build two. The lifecycle itself is exercised against the loopback fixture server
or the test `URLProtocol`, not asserted from private state.

Rejected: one session for streams too. A shared session with one delegate would have to route
`didReceive` callbacks by task identity and keep per-connection startup state in a side table; the
per-connection session is smaller and its invalidation is unambiguous.

### D-27 Stream lifecycle — one state machine, explicit close, bounded reset
Every way an SSE connection can end now runs through one lifecycle:

- **Startup** (`StreamReceiver`) is a Mutex-guarded state machine. Cancellation before the receiver
  exists, between adopting the session and registering the continuation, while awaiting headers, or
  after the continuation is registered resumes the caller exactly once with `CancellationError` and
  invalidates the session. A pre-cancelled `open` throws; it never waits on a continuation nobody will
  resume.
- **The connect deadline covers the whole open**, including response headers: `openWithDeadline` races
  `transport.open` against the clock, closes a stream that arrives after the deadline, and fails with
  `.transport(.timedOut)`. `nil` disables it for a caller that owns its own timeout. The watchdog now
  only covers post-open silence (45 s, reset by heartbeats).
- **Every exit closes the previous connection.** A 401 or other non-2xx closes the response before
  throwing; a consumer that stops cancels the channel, which closes the response and the session; the
  watchdog closes both; `EventConnection.close` is idempotent and cancels the read task, the watchdog
  and the request; `EventStreamRunner` closes its connection with `defer` before any reconnect.
- **Overflow is an explicit signal with bounded recovery.** `EventStreamOverflow` names its cause;
  `EventStreamRunner.onResynchronize` is called once per overflow, before the reconnect, as the
  documented point where a feature rehydrates from REST (the authority). Overflow uses its own
  retry preset (1 s base, 15 s cap, no network wait) and is bounded: after five consecutive overflows
  the runner ends the stream with the overflow instead of spinning. The count clears only after
  healthy consumption (D-29), not on `server.connected`.
- **Rejected**: treating overflow as a silent drop or as a permanent failure. A dropped delta makes
  the projection wrong without telling anyone; a permanent failure would strand a consumer that can
  recover by re-reading REST.

### D-28 Loopback fixture server — real delegates, still isolated
`LocalHTTPServer` (test support) is a loopback-only HTTP/1.1 server used to exercise the real
`URLSession` redirect delegate and socket lifetimes: same-origin redirect, refused cross-origin
redirect, pairing redirect refusal, withheld headers, rejected responses and consumer shutdown.

- A custom `URLProtocol` cannot do this: it synthesizes a redirect inside the protocol stack, so the
  session delegate never runs. That is why D-22's rule test stays, and these tests cover the wiring.
- Nothing leaves the machine: the listener binds `127.0.0.1` on an ephemeral port, routes are
  in-memory, and the suite can be skipped with `OPENCODE_SKIP_LOOPBACK_FIXTURES=1`.
- The live-server check is separate again: it reads `OPENCODE_LIVE_SERVER` and
  `OPENCODE_LIVE_PASSWORD` from the environment, is skipped when they are unset, and only performs
  reads.

### D-29 Overflow protection clears only after healthy consumption
`server.connected` resets the ordinary reconnect backoff (the audited handshake) but **not** the
consecutive-overflow count or the overflow backoff. Those clear only when a connection has stayed open
`healthyResetWindow` (default 30 s) and has delivered at least `healthyResetEvents` (default 1) events
beyond the handshake.

- Why: a server (or a broken proxy) can emit `connected` and then immediately flood the consumer.
  Resetting on the handshake would let that cycle repeat forever, defeating the bound.
- The check runs per delivered event, so a connection that connects, sends one burst and overflows
  before the window never resets. A long-lived stream that keeps delivering resets promptly.
- Tests: repeated connect-then-overflow cycles reach the limit; a connection that delivers content
  past the window keeps the limit clear across three overflow cycles; the transport-buffer overflow
  takes the same path.

### D-30 Transport chunk-buffer overflow is a typed, recoverable outcome
Exhausting `URLSessionTransport`'s bounded chunk buffer fails the stream with
`TransportError.streamOverflow`, not a private sentinel. `EventStream.clientError` maps it to
`OpenCodeClientError(.streamOverflow)`, which the runner treats exactly like an event-hand-off
overflow: close the connection, resynchronize from REST, then reconnect on the overflow schedule.

- Why: the buffer exists to bound memory; a full buffer means the consumer fell behind, which a
  reconnect plus REST rehydration repairs. Converting it to `.unreachable` (the old behaviour) made
  a recoverable gap permanent and skipped the resync signal.
- The chunk capacity is injectable so a test can force the overflow; the default stays 64 chunks
  (≈1 MiB).

### D-31 A web page is an incompatible API, not a decode or auth failure
A 2xx response whose `Content-Type` is `text/html` or `application/xhtml+xml` is
`OpenCodeClientError(.incompatibleAPI(feature:))`, with its own copy. It is distinct from:

- `.status(401)` — the credentials were rejected;
- `.transport(…)` / `.unreachable` — the server could not be reached;
- `.undecodable(feature:)` — JSON that does not match the V2 contract.

Phase 5's connection screen can therefore tell “wrong address / not an OpenCode V2 server” from
“wrong password” and “offline”. The classification is decided only after the status guard, so a 401
with an HTML body remains an authentication failure.

The live investigation (STATUS) found exactly this case: an installable `opencode serve` build
answers unknown `/api/*` paths with its web shell, so `/api/info` and `/api/project` look like 200s
until the content type is checked.

### D-32 Keychain identity follows the configured bundle identifier
`SharedStore.liveValue` builds `KeychainStorage` with `"<Bundle.main.bundleIdentifier>.credentials"`;
there is no hard-coded migration service and no historical identifier. The current project bundle id
(`ai.opencode.migration`) is still owner-configurable, so changing it changes the credential store
name. Tests and the in-app probe use unique disposable services.

- Why: the owner has not supplied a production bundle id. Deriving the service means the identity is
  final wherever signing settles it, rather than a value copied from evidence or invented here.
- Consequence: changing the bundle id after real credentials exist orphans the old Keychain items;
  settle the identifier before distributing a build that stores user credentials.
- Gate: `SharedStoreTests` covers keychain/defaults routing; the app-process Keychain probe covers a
  real round trip with a unique service.

### D-33 One network-path monitor, behind a dependency
`NetworkPathClient` exposes `current`, `updates()` and `waitUntilAvailable()`. The live value is one
process-wide `NWPathMonitor`; tests inject a path stream. `RetryEnvironment` reads the same client,
so a retry loop waits for the path instead of spending attempts while offline.

- `NetworkPathMonitor` is `@unchecked Sendable` for one reason: `NWPathMonitor` owns its serial queue
  and only `Mutex`-guarded state plus stream continuations cross threads. This is the same narrow use
  as D-22's transport helpers, not a blanket concurrency escape.
- The shell cancels the stream and health/refresh work when the path goes offline and re-races the
  address when it returns. A satisfied path is never treated as proof that a particular server is
  reachable.

### D-34 Connection ownership is identified state with generation guards
`AppFeature.connection` is an optional `ConnectionFeature.State` that is `Identifiable` by a
parent-assigned id. Replacing or clearing it cancels the health race, refresh and stream through
TCA's `ifLet` identity. Inside the child, each attempt increments a generation seeded from that id;
every effect action carries its generation and a stale one is ignored.

- One stream effect at a time (`.cancellable(cancelInFlight:)`); the `EventStreamRunner` owns the
  reconnect schedule, so the app never nests a retry loop around it.
- Health is `.once` per address; the address race is the only concurrency over candidates.
- Leaving the foreground cancels the stream and health/refresh; becoming active re-races and
  re-reads REST. `disconnectTapped` clears the child and keeps saved credentials.
- Keychain restores and writes run in effects, not in the reducer body; the app keeps its UI state on
  the main actor and moves storage I/O off it.

### D-35 Unreachable is not a local-network denial
iOS has no preflight equivalent to Android 17's local-network permission. A transport failure is
shown as “Couldn’t reach the OpenCode server.” with a suggestion to check Settings › Privacy &
Security › Local Network when the address may be on the LAN. The shell does not claim the permission
was denied, and `.offline` is used only when the path monitor says the path is unsatisfied.

- `.credentialsRejected` remains a 401-only outcome; `.incompatibleAPI` is a 2xx web page;
  `.malformed` is a contract decode mismatch; `.unreachable`/`.offline` are connectivity.

### D-36 The P5 connected destination is deliberately minimal
After health and a projects refresh, the shell shows the server name, version and project list, plus
“Sessions arrive in a later phase.” The Home drawer, Catch Up, session list and transcript belong to
P6–P8. This keeps P5 reviewable and prevents a half-built session screen.

### D-37 Pairing confirmation and explicit paste
`PairingLink` remains a value with no transport: parsing a paste, link preview or deep link cannot
spend a one-time code. An opened URL is held as `PairingConfirmation` until Pair; a pasted link or a
pairing link typed into the manual address field is an explicit action and redeems immediately.
Existing saved credentials are replaced only after health succeeds, through `SavedServers.remembering`.

- Re-pairing keeps a saved server's local name and headers (`keepingLocalSettings`).
- A stale redemption result is ignored when its attempt id no longer matches.

### D-38 App-shell copy lives in a String Catalog; reducers hold typed facts
`ios/OpenCode/Resources/Localizable.xcstrings` owns the English UI copy. `RootView` resolves keys via
`AppCopy`; reducers carry `ConnectionFailure`, `PairingProblem` and `ServerFormProblem` values and
never compare or store sentences. Tests assert the English copy through XCUITest, and typed outcomes
through Swift Testing.

- Protocol constants, accessibility identifiers, log events and fixture data stay literals.
- Custom request headers and the copied error report are deferred with the manual form follow-up;
  the model and wire support already exist from P4.

### D-39 Unreadable saved data is write-protected until explicitly replaced
`SavedDataState` records whether the saved-server list was actually read. Only `.read` permits
automatic persistence. A storage failure or an undecodable key leaves the state `.unreadable`; a
manual connection is shown and kept in memory, but no write occurs until either:

1. a retry reads the data successfully, in which case the preserved entries are reconciled with the
   pending server and written; or
2. the person confirms **Replace Saved Servers**, which deletes the unreadable keys and then writes
   the reconciled list.

- Partial corruption (a corrupt `saved-server` beside a readable list, or the reverse) is still
  unreadable: the usable entries are preserved, but automatic writes are blocked.
- A delete or write failure leaves the warning in place and reports the storage outcome; the app never
  claims the replacement succeeded.
- Gate: `AppFeatureTests` cover a manual connection over an unreadable list, a temporary read failure
  followed by a successful retry with two preserved servers, a failed replacement, and partial
  corruption; UI tests enter a server manually from both storage-error screens.

### D-40 Attempt and stream identity cover every asynchronous stream callback
`ConnectionFeature.Token` carries an attempt number and a stream number. Health and refresh results
carry the attempt; stream phases, events and overflow resynchronization results carry both. Every
reducer guard requires the current token.

- Retry and replace start a new attempt; backgrounding and path loss cancel and invalidate; failure
  invalidates before reporting. A delayed callback from cancelled work therefore cannot change the
  server, phase, projects or failure.
- The tokens are deliberately outside `State` equality; tests assert visible state and send stale
  callbacks explicitly.
- Gate: `ConnectionFeatureTests.delayedCallbacksAreIgnored` sends old health, refresh, stream phase,
  project event and resynchronization results after backgrounding.

### D-41 One connection-eligibility gate
`ConnectionFeature.State.canAttempt` is `isInForeground && !isOffline`. Every start path (task, retry,
foreground, path return) goes through `startIfEligible`; when ineligible the child cancels and
invalidates work and shows the reconnecting/offline state. A path return while backgrounded does not
start anything; becoming active does. An offline restore waits and then connects when the path
returns, with no manual retry.

- The child stores the path state passed by the shell; the parent forwards every path and scene change.
- Gate: `ConnectionFeatureTests` cover offline restore, background path return, foreground recovery and
  the lifecycle restart.

### D-42 Child stores are scoped for observation, and fixtures are test-only
`RootView` passes `store.scope(state: \.connection, action: \.connection)` to `ConnectionView`, so a
child phase or project change updates the screen. Passing a child state value loses observation of its
nested fields; a lifecycle UI test covers the connected → background → active transition.

- `UITestFixture` is compiled only under `DEBUG` and is selected only by `-uiTesting` plus
  `OPENCODE_UI_TEST_FIXTURE=connected`. It opens no socket.
- `SavedServerProbe` is `DEBUG`-only, uses a disposable Keychain service, writes fake servers, reads
  them through `AppRestoreResult`, and deletes them. It does not touch production credentials.
- These hooks exist for device checks; neither is reachable in a release build or without its explicit
  launch argument.

### D-43 Home owns the drawer; the shell still owns the one event stream
`HomeFeature` (package `OpenCodeDrawer`) is the connected destination and the only consumer of
session-scoped events. `ConnectionFeature` remains the single stream owner and forwards the events Home
needs through `Delegate.sessionEvent(server, event)`; Home never opens a second stream. `Delegate.resynchronized`
tells Home that a reconnect/overflow re-read REST before the next socket.

- Home state is `HomeFeature.State`; `AppFeature` composes it with `.ifLet`, so replacing or clearing it
  cancels its refresh, attention, paging, search, receipt and deletion effects. Every callback carries a
  generation and a request/cursor identity, and a stale one is ignored.
- Refresh is 250 ms debounced and `cancelInFlight`, matching the audited `refreshSnapshot`; an event burst
  coalesces to one read. A refresh replaces the first page and keeps locally paged older sessions, so a
  reconnect does not collapse the list under the reader.
- Session selection is a value: `SessionSelection(serverID, sessionID, intent)`. It crosses the App → Home →
  Session boundary instead of a bare ID, and the intent is explicit (`browse`, `catchUpCard`,
  `whatsNewDraft`). P6 renders a labeled placeholder; P7 owns the destination.
- Rejected: adding a Home-local stream, a view model, or a second navigation model.

### D-44 Home persistence is versioned, bounded and server-scoped
`HomeSnapshot` v1 holds projects, the first root page, active IDs and the next cursor for one server. It is
written atomically to `home-snapshots.json` in Caches by an actor, with at most 8 servers and 50 sessions
per server. A decode or version failure is reported and never applied.

- Pins, read dates, manual-unread marks, mutes, hidden sessions and last-viewed sessions are local records
  keyed by `serverPersistenceID|sessionID`; they are not server data and survive a server switch.
- The P5 `cachedServerSummaries` project cache is migration input only. A successful Home snapshot write
  removes that server's entry; no new summary is written. A failed/read-only store is reported, not
  silently replaced.
- The snapshot is a cache, so REST always wins. A corrupt cache does not block connecting; the next
  successful refresh replaces it. Saved-server credential protection (D-39) is unchanged.

### D-45 Catch Up is native cards, not a port of the Compose stack
The audited behaviour is carried: attention first, then newest unread; running, muted, archived and subagent
sessions are excluded; Mark Read is optimistically local plus a `/view` receipt; Keep Unread is local only;
Undo restores the exact previous read state and cancels an in-flight receipt; a failed receipt restores the
card's read state and reports on the stack. The last handled card closes Catch Up onto the drawer's
**All Caught Up** row, and new activity clears that row.

- Android's swipe/flight/settle motion (`CatchUpStackController.kt`) is not ported. The iOS card answers with
  the system press highlight, two explicit actions, and one horizontal drag threshold; there is no card
  animation, so Reduce Motion needs no special case.
- The empty state is a drawer row because that is where the audited app returns after the last card; the
  Catch Up page also keeps a plain All Caught Up view for a stack that opens empty.
- Mark All is **not** in P6. It needs a receipt fan-out with per-session backups and belongs with P7's
  request review/read receipts; P6 exposes row-level Mark Read/Unread only.

### D-46 What's New ships the mechanism, not the historical catalogue
P6 implements the drawer row, unseen dot, page routing and `whats-new-seen` persistence. The catalogue in
`WhatsNewCatalog` is a small set of entries describing this build's own P6 surfaces (drawer, Catch Up,
project labels); it is not a reconstruction of the audited 150-entry release catalogue and makes no copy
claim.

- The historical catalogue, Try It prompts, Settings destinations and the release-note pipeline belong to
  P11 with the rest of Settings. `WhatsNewEntry` carries localization keys, so P11 can add entries without
  changing Home.
- Seen state is written only when the page closes or is viewed, never by the row appearing.

### D-47 Accessibility verification and the scroll trace are test instruments
Dynamic Type is exercised at `UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge`; row labels are
combined into one VoiceOver sentence (title, project, status, pin) and asserted in XCUITest; the drawer
search field is dismissed by its sheet's Done action, also asserted.

- The scroll trace uses a DEBUG-only `CADisplayLink` probe (`ScrollFrameProbe`) that records only while a
  scroll is in flight and publishes p50/p95/max as an accessibility label. The UI test reads that label and
  XCTest's `scrollDecelerationMetric`; the numbers are reported as simulator measurements, never as a
  smoothness guarantee.
- No custom animation is added in P6. Sheets, navigation, menus and the system press highlight provide the
  motion; Reduce Motion therefore inherits the platform behaviour and was not separately exercised.

### D-48 Reviewed paths keep explicit causality, not just visible outcomes
The P6 review corrections are recorded as semantics rather than patches:

- **Paging retry is the same action as loading.** The footer's Try Again calls `loadMoreTapped`; a
  failed first search, search append and ordinary page each keep the query/cursor that failed. A retry
  starts with `failed = false` and, for search, a new token so a late answer from the failed attempt
  cannot land.
- **A read receipt acknowledges exactly its idle watermark.** Local optimistic read state is allowed,
  but a successful `POST /view` for A must not mark activity B read. `unreadFloors` records the watermark
  a deliberate unread or an Undo protects; a view event at or below it is stale, a newer one is real.
- **Deletion has three states: in flight, confirmed and failed.** `recentDeletedIDs` hides the row,
  `inFlightDeletions` survives disconnect, and `deletionTombstones` records the refresh counter at
  confirmation. A refresh that started before confirmation cannot clear the tombstone; the first
  refresh after a reconnect reconciles an unsettled delete by presence/absence. Delete results are
  server-scoped, not generation-scoped, so a disconnect cannot strand a row.
- **Live means live.** Home may read only in front, online and after the shell has completed a
  connection. `ConnectionFeature` reports `available` after a handshake refresh and `unavailable` when
  the socket drops; `connectionResynchronized` replaces an earlier read with one authoritative read.
  The initial `.task` never starts a second read over a resync.
- **Attention resolution is local to the event.** A cold root or subagent is resolved with at most eight
  ancestry reads and one location-scoped request read. Projects are never scanned; a missing root row
  gets one coalesced Home refresh, and hint directories stay bounded at eight.

Regressions are in `OpenCodeDrawerTests/HomeFeatureTests.swift` and `OpenCodeAppTests/AppFeatureTests.swift`.
