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
| `P-3` | Composer text input | D-64 (`UITextView` bridge) | — |
| `P-4` | Photo picking | D-78 (`PhotosPicker`, no in-app photo sheet) | — |
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

_Superseded in P8 by D-61: the pressure policy is batched coalescing plus on-demand Markdown parsing; a
raced-event overflow is explicit and rehydrates rather than silently dropping or truncating._
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
  `whatsNewDraft`). P6 rendered a labeled placeholder; P7's `SessionFeature` now consumes the same value
  (D-50, D-53).
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
- Mark All was **not** in P6. P7 delivers it as a receipt fan-out with per-session backups (D-55); P6
  exposed row-level Mark Read/Unread only.

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
  `pendingDeletions` survives disconnect, and `deletionTombstones` records the refresh counter at
  confirmation. A refresh that started before confirmation cannot clear the tombstone. An unsettled
  delete is reconciled only by a targeted session read (D-49), never by its absence from the first
  page. Delete results are server-scoped and operation-ID guarded, so a disconnect or late answer
  cannot strand or reverse a row.
- **Live means live.** Home may read only in front, online and after the shell has completed a
  connection. `ConnectionFeature` reports `available` after a handshake refresh and `unavailable` when
  the socket drops; `connectionResynchronized` replaces an earlier read with one authoritative read.
  The initial `.task` never starts a second read over a resync.
- **Attention resolution is local to the event.** A cold root or subagent is resolved with at most eight
  ancestry reads and one location-scoped request read. Projects are never scanned; a missing root row
  gets one coalesced Home refresh, and hint directories stay bounded at eight.

Regressions are in `OpenCodeDrawerTests/HomeFeatureTests.swift` and `OpenCodeAppTests/AppFeatureTests.swift`.

### D-49 Deletion verification is targeted, not inferred from a page
A Home refresh returns only the newest 50 root sessions. Absence from that page cannot prove an older
session was deleted, so deletion reconciliation never uses it.

- A delete has three outcomes: **definitive success** (the DELETE succeeded, returned a non-location
  404, or a targeted `GET /api/session/{id}` returned a non-location 404), **definitive failure**
  (a 4xx refusal or a request that was never sent), and **uncertain** (timeout, interrupted transport,
  429/5xx, unreachable, undecodable or a location-missing 404).
- A definitive failure restores the row and keeps the tombstone cleared. A definitive success purges
  local records and keeps a tombstone for the Home lifetime so a stale refresh cannot resurrect the row.
- An uncertain outcome keeps the backup, the row hidden, and every local pin/read record. On reconnect,
  each unsettled delete gets one targeted session read (bounded to eight concurrent checks). Absence
  confirms success; presence fails the delete only when the DELETE is no longer running. Presence while
  the DELETE is still in flight is intermediate and settles nothing.
- An inconclusive read (401, connectivity, server error, location-missing 404) preserves the backup and
  reports that verification could not be completed. It never destroys local history.
- Every delete carries an operation id. A late result is applied only if it still matches the pending
  operation, so a newer reconciliation cannot be reversed.

Regressions: `laterPageDeleteUnknownOutcome`, `laterPageDeleteConfirmedByTargetedRead`,
`inconclusiveDeletionVerification`, `runningDeletionSurvivesExistenceCheck`,
`lateDeleteResultIgnoredAfterVerification`, `oldRefreshCannotResurrectDelete`.

### D-50 Session refresh is one identified queue, never a cancel-in-flight read
`SessionFeature` carries the audited `RefreshReason` cases and one `SessionRefresh` (request ID, reason,
one follow-up, bounded raced events). A lifecycle duplicate coalesces into the read already in flight; a
content/run invalidation earns one follow-up. The effect is `.cancellable(id:)` **without**
`cancelInFlight`, and only a connection loss or leaving the screen abandons it. This preserves the
newest-request-wins semantics rather than replacing them with a generic debounce or a view model.

- A response is accepted only for the session and request ID that started it. Events that arrived during
  the read are replayed after the snapshot; execution and request events also schedule one follow-up.
- The message/page transcript scope is not ported yet: a settlement read waits the audited 200 ms window,
  then reads session/request/background state. P8 adds the transcript payload to the same read identity.
- The five-second home-level notice expiry is reused; no motion is added.

### D-51 Stop owns its ambiguity, and a resumed run is a success
`interruptTapped` supersedes the previous run generation and captures the steering IDs the server holds.
The interrupt loop owns `RetryPolicy.request`; after any failure that may have reached the server it reads
`/api/session/active` and the inbox before trying again. A finished run settles Stop; a steering message
missing from the inbox means the next run took it (`interruptResumed`); a still-running run retries. Once
acknowledged, the stop reads at 1, 2, 4 and 8 seconds. A failure keeps the run running and shows definite
copy (“Couldn’t stop session”), never a stuck spinner.

- Cancellation identity is per generation: `interrupt`, `interruptSettle`, `runEndCheck` and
  `strandedSteer` all carry the generation, so a new run or a replacement session cannot receive old work.
- Stranded steering queues before it steers when the server still holds the message as steer, then checks
  the run after 1.5 s. The P9 composer will call this action; P7 exposes the model and a minimal row.

### D-52 Request review is a native sheet with typed settlement
Permission and form models decode strictly, with `default` → `defaultValue`, external steps defaulting
false, progressive visibility and hidden answers dropped. Validation returns a typed problem and the
active-field index; the view owns the sentence.

- One submission per request: the request is marked responding before the effect, completed IDs cannot be
  actioned again, and a late response for a non-responding request is ignored.
- A form reply or dismissal sends once, reads the form state after an ambiguous failure or `409`, accepts
  a matching state, resends once only while the form is still pending, and turns a settled-other-way
  response into a typed conflict. A `404` is “no longer waiting”.
- A conflict removes the request and keeps the reason visible. A transport failure keeps the request and
  the answer so Retry can send it again. “Always Allow” is offered only when the server supplied save
  patterns; only a denial carries a reason.
- The composer dock (fold, question pages, answer bar) is P9. P7 uses the same reducer state so the dock
  can be presentation-only later.

### D-53 Subagent pages are a logical stack in one session store
The root session owns the family, requests and background state. A subagent page is an identity plus a
session ID; opening one saves the current request selection, pushes the page and reads with `resume`.
Popping restores the saved selection and reads the uncovered session. Pushing the same page again pops to
it rather than duplicating it. The P6 `subagentStack` of independent session stores is not imported: it
would duplicate request and shell ownership that this phase now has.

- The family store keeps previously discovered children when a narrower family response arrives, so a
  temporary failure or a race cannot make a known subagent disappear.
- Family discovery keeps the audited bounds (six child pages in flight, 100-session cap, visited set,
  queue-order commit) and bounded running ancestry (24 metadata lookups).

### D-54 Background work is tailed, bounded and stoppable
The panel lists running shells and running jobs; shell rows open a captured output sheet. Output reads
64 KiB pages from at most the last 256 KiB, retains 1 MiB, and Load Earlier can grow the window to 4 MiB
at a line boundary. The sheet polls every second, backs off to 3 s on failure (then 3/6/12/24/30 s in the
audited model), marks a 404 unavailable and stops. Stop drains the remaining bytes before `DELETE`.
`shellOutputTapped` is the only way a poll starts; closing the sheet cancels it.

- Job cancel is optimistic (stopping set) and idempotent; a failure keeps the row and reports a typed
  problem.
- Shell copy/share and background subagent stop are P9/P10 because they depend on the composer/export
  surfaces; the panel does not pretend they exist.

### D-55 Mark All is a receipt fan-out over the Home read records
Mark All reads the shared Home state, not the session child. Only rows whose indicator is `unread` are
eligible; attention and running rows keep their state. Each receipt records the exact read backup, marks
the row read locally, and runs four at a time. A failed receipt restores the row rather than leaving an
optimistic read. Keys remain `serverPersistenceID|sessionID`, so a switch cannot acknowledge another
server. The menu is exposed both as the Catch Up row's menu and as a drawer toolbar menu; the Android
card flights are not ported.

### D-56 The colour provider is nonisolated
A P7 UI test found a latent crash from the first form sheet: `OpenCodeColors.color` was `@MainActor`, but
its dynamic `UIColor` provider runs when SwiftUI resolves a colour, sometimes off the main queue, and a
Swift 6 executor assertion trapped. The provider now resolves through a nonisolated entry point over the
`Sendable` palette. This is a correctness fix, not a visual change; typography remains SF/SF Mono (D-1).

### D-57 The stream, family, initial load and shell boundaries are explicit
The Phase 7 review found six boundaries that direct feature tests could not see. They are now
semantics, not test-only patches:

- **Stream forwarding is complete.** `ConnectionFeature.streamEvent` forwards every event except
  `projectUpdated` (handled into the project list), `connected` and the model/agent catalog notices.
  Session still decides ownership; Home and Session receive the same delegate event. The connection's
  attempt/stream token check is unchanged, and App has one stream owner.
- **Family identity is the root, not the active page.** A refresh reads the active session's metadata,
  but `sessionFamily` is always called with the family's original root. A narrower subtree cannot replace
  a known family. Child pages read, and an inactive child clears the run for that page while the root's
  requests and unsent answers stay in the parent.
- **A selection can load without a cache.** The initial snapshot is accepted when root and family are
  still empty and the response matches the selected session. Stale-request fencing is unchanged (ID and
  session), and a reconnect may start the initial read again.
- **Shell polling is a conjunction.** The sheet tracks visibility separately from the initial tail;
  either arriving last starts exactly one poll. Dismissal cancels it; reconnection restarts it only when
  the sheet is still visible and loaded.
- **Shell ranges are contiguous and bounded.** Trimming returns the discarded byte count, including
  newline and UTF-8 alignment, and the reducer advances `startCursor` by it. Load Earlier joins at the
  retained start and is capped at 4 MiB; it never trims the newly loaded front.
- **Stop drains before it deletes, and cancellation is cooperative.** Stop cancels polling, reads the
  remaining pages to a probe-confirmed completion boundary, and checks cancellation at the loop, before
  and after each dependency return, and immediately before `DELETE`. A dependency that completes
  successfully after its task was cancelled therefore cannot reach the destructive request. Scope: a
  cancellation observed before dispatch prevents the request; a `DELETE` already sent may have an
  uncertain outcome and is left to the normal request/response path. A failed or incomplete drain keeps
  the output and asks for an explicit Discard Unread Output decision. This prevents silently destroying
  output the person never saw.

### D-58 The transcript extends the session's one authoritative read
`SessionFeature` keeps one `SessionRefresh` and one request ID. Every authoritative read now also reads
`GET /api/session/{id}/message?order=desc&limit=30` in the same effect; the transcript does not start a
second refresh queue. `RefreshReason.settlement` still waits the audited 200 ms and the same raced-event
buffer (512) is replayed onto the snapshot.

- Older history has its own request identity: session ID + transcript generation + cursor. A newer
  authoritative window bumps the generation when it loses overlap or reaches the start, so a late older
  page cannot alter a later incarnation. A page change cancels the earlier request.
- `session.message.content.updated` and the other invalidating events now schedule `.invalidation`; they
  previously did nothing at the session boundary.
- A selected session with no cache gets an empty `TranscriptState` before its first read, so loading,
  empty and failed states are distinguishable.
- Nothing about P7's newest-wins behavior, follow-up rule or cancellation is replaced.

### D-59 Transcript motion is SwiftUI-native
The transcript is a normal SwiftUI `ScrollView` with a `LazyVStack` and stable entry IDs. It follows new
rows only while the reader is at the end, shows **Jump to Latest** when they are not, restores an earlier
page's anchor after a prepend, and restores a covered page's position and disclosures. The jump glide is
the only custom animation and uses `OpenCodeMotionRole.microIn`; Reduce Motion replaces it with the shared
reduced fade.

- Not ported: the historical UIKit follower, row growth, send flights, mark hand-off, promotion morphs and
  the Android reversed `LazyColumn` motion. Their numbers are evidence of an intended feel, not a spec.
- P9 can insert a composer without changing this surface: transcript state is value-typed and observed only
  where used, and the list does not depend on composer state.

### D-60 Markdown is parsed natively, not rendered by a web view
`MarkdownParser` reads headings, paragraphs, lists/tasks, quotes, fenced code, tables, rules, image links
and display math into values. Inline formatting uses Foundation's `AttributedString` Markdown parser with a
literal-text fallback. SwiftUI draws the blocks with the system font and SF Mono; there is no `WKWebView`
and no bundled font.

- Math and Mermaid have no renderer in P8: math shows its source in a code band; Mermaid is an ordinary
  fenced code block. A maintained renderer is evaluated in P10.
- Remote images are link cards. Nothing fetches an image, executes HTML, or runs a command from server text.
- Quotes from `metadata.comments` are display-only cards; the composer action is P9.

### D-61 Pressure is coalescing, bounded replay and explicit recovery
The stream keeps the P4 bound: adjacent deltas for one part coalesce per 75 ms flush (or 256 mutations), the
downstream buffer is 128, and overflow ends the connection so REST rehydrates. P8's consumer is cheap by
design, and its raced-event replay is explicit about its bound.

- Only visible Markdown rows request parsing. A publication carries a revision: a newer text or a
  disappeared row fences every older parse, so a late result cannot replace what is displayed. Parsing runs
  off the main actor through `MarkdownBlockCache`, which keeps at most 256 entries and 4 MiB of source,
  evicts least-recently used entries, and clears on a memory warning.
- Events that race one authoritative read are retained up to 512 separate batches and replayed in order.
  Crossing that bound **discards the partial replay** and sets `racedEventsIncomplete`; the view never
  receives that buffer as a complete projection.
- The requirement moves into persistent `SessionRecovery` state. It survives a failed read and carries the
  durable boundary seen during overflow, so the actual recovery read uses
  `RefreshReason.recovery(messageID:)` and waits the audited 200 ms. A recovery is complete only when the
  authoritative transcript read succeeds and no new overflow occurred; then the requirement clears.
- Recovery is bounded: one immediate attempt after the overflowing read, then at most one delayed automatic
  retry (two recovery reads total). After that the app keeps the requirement and exposes the existing
  refresh failure; a manual retry, reconnect or later event uses the same coordinator and can still recover.
  A failed attempt never marks the projection synchronized.
- Item and stream buffers stay bounded by the P4 transport/frame limits and the 20,000-byte tool-text bound.
  The transcript keeps loaded pages until the person leaves the session; earlier pages are only loaded on
  request, so loading is bounded by user action rather than an undocumented truncation.
- Recorded limits: the server transcript window is 30 rows and an older page is 80; raced replay is 512
  batches; the UI lazily draws whatever is loaded.

### D-62 Server content cannot open or fetch anything by itself
A Markdown link or image card routes to `SessionFeature` as a typed URL. The confirmation sheet offers
**Open**, **Copy Link** or Cancel. Only an explicit Open calls `OpenURLClient`; only `http`, `https` and
`mailto` are allowed. Images never load in P8; file chips open a name/path/MIME sheet with Copy Path.

- `OpenURLClient` is a dependency: live uses `UIApplication.open`, tests are inert and assert the call.
- Selection is native per block (`textSelection`) plus explicit reply and code Copy through
  `PasteboardClient`. The historical cross-block single-document selection is not rebuilt; it can be
  revisited with measurement in a later phase.
- Tool output is rendered as text with selection, never as JSON commands or HTML.

### D-63 The transcript target sits below the session feature
`OpenCodeTranscript` (package target) owns grouping, projection and Markdown parsing and depends only on
Core and Server. `OpenCodeSession` depends on it; the app target owns the SwiftUI rows and the scroll
surface. This keeps P9's composer and P10's media above the transcript rather than adding upward edges.

- Files: `OpenCodeKit/Sources/OpenCodeTranscript/*`, `OpenCodeKit/Sources/OpenCodeSession/TranscriptState.swift`,
  `ios/OpenCode/Transcript/*`.
- P10 resolved image decoding, viewers, file opening and the browser (D-78–D-86); math/Mermaid keep the
  source fallback (D-87). P8's placeholders and link cards were the routing boundary.

### D-64 The composer's text input is a focused UITextView bridge
`P-3` is resolved with `ios/OpenCode/Composer/ComposerTextInput.swift`, a small `UIViewRepresentable` around
`UITextView`. It follows iOS model evidence (the historical app bridged `UITextView`) and the audited Kotlin
input's behaviour: selection survives external drafts, an IME's marked text is never overwritten by a draft
sync, Return sends, Shift+Return inserts a newline, and the field grows to 168 pt before scrolling.

- Rejected: a SwiftUI `TextField` that writes the whole value on every keystroke; it cannot preserve marked
  text against an external clear and loses selection.
- Concurrency: the bridge is main-actor by the app target's default; the binding sends a semantic action, not
  a whole-store update inside `textViewDidChange`.
- Device-only checks (marked text, hardware keyboard, VoiceOver) are recorded unverified rather than inferred
  from simulator typing.

### D-65 Drafts are explicit, scoped and bounded
`ComposerDraftStore` is one actor over an atomically written JSON record set. Keys are
`server persistence ID | session:<sessionID>` or `server persistence ID | new:<project directory>`; the latter
keeps a New Session draft stable across relaunch without letting one project overwrite another. The reducer
debounces writes 500 ms, flushes on Done/background, and discards a delayed load when a newer edit or key exists.

- Limits: 128 KiB text, 64 KiB quote text, 200 quotes. Exceeding them is `.tooLarge`: the reducer keeps the full
  text and shows a recoverable line; it never saves or displays a prefix.
- A read failure is `.couldNotRestore`, a write failure `.couldNotSave`; neither is a successful save. The store
  also refuses an unknown/corrupt version rather than overwriting it.
- The chat draft is not parked in request state. While a request docks, the answer bar has its own text and the
  chat composer’s value is untouched.
- A successful send clears only the snapshot it sent. A later edit has a higher revision and survives that
  send’s result.

### D-66 A failed prompt is reconciled before a new message id
The prompt is admitted under a client-made message ID. A definite rejection can be retried. An ambiguous
transport/gateway result is first reconciled with `GET /api/session/{id}/message/{messageID}` and the inbox.

- Found → settle as success; do not post again.
- Confirmed absent → Retry may mint a new ID, satisfying the recorded P9 gate without blind duplication.
- Read-back unreadable → keep the optimistic row, report **Couldn’t verify** and do not send again until an
  authoritative read settles it.
- A session create uses its own client ID, so a retried create cannot make a second session. If create succeeds
  and the prompt fails, the created session is adopted and the text remains recoverable (composer or Retry/Edit).
- One operation ID fences late results; App creates a new session child on a destination change, cancelling the
  old effects.

### D-67 The request dock is a presentation of the P7 request model
There is no second request model. `RequestDockState` owns only the answer-bar text, question page, fold and the
sheet flag. `SessionRequests` keeps requests, defaults, visibility, validation, responding/completed IDs and
settlement.

- A permission, a question, or a one-field non-external form docks. Anything larger keeps the P7 sheet through
  the dock’s Review action.
- While any request is pending, keyboard Send runs the request workflow; it cannot send the answer as a chat
  message. The chat draft stays in `ComposerFeature` and is never posted as an answer.
- Allow Once/Always/Deny, hidden-answer pruning, defaults, global-form directory routing and read-back
  settlement remain the P7 implementations.

### D-68 The experimental wait has one retry owner
`POST /api/experimental/session/{id}/wait` is a 25 s long poll. `SessionWaitLoop` sends each poll and active
probe once: a timed-out live run re-arms immediately, a fast failure probes the run and then waits the shared
session-wait backoff, up to 12 fast failures; a caller-owned `.once` policy gets the failure back after the
probe. Cancellation propagates and no generic transport retry wraps it.

- Completion means the run settled. The send path then asks the existing `RefreshReason.settlement` read; it
  does not add a stream, a poller or a second transcript queue.
- A failed wait is not a failed send. The stream and subsequent authoritative reads remain the source of truth.

### D-69 Quotes are one block’s native selection plus the audited metadata
The reply-end Quote action opens a selectable `UITextView` sheet; its selected substring, or a user-adjusted
selection, becomes `ComposerQuote(text, comment)`. Sending appends the audited quoted block to the model text and
writes `{"type":"quote","text","comment"}` to `metadata.comments` with `metadata.displayText` for the typed text.

- The chat draft is never replaced or cleared by inserting/removing a quote.
- Cross-block selection as one document remains the P8/P14 limitation; P9 does not claim it.
- Selected text is never logged.

### D-70 A send owns a persisted outbound record until it settles
The composer writes `ComposerOutbound` (target, message ID, text, quotes, delivery) into the draft record before
clearing the editor or dispatching. A save failure keeps the editor and does not send. A blocked delegate
restores the payload (or keeps it as a definite failed send when newer text exists). A definite failure restores
it or records it for Retry/Edit; an unreadable reconciliation becomes a persisted ambiguous failed send with the
original message ID and target. On load, an unresolved outbound record is converted to the same ambiguous failed
send and is never restored as editable text. This closes the offline, request-race, unverified and termination
gaps. `FailedComposerSend` and `ComposerOutbound` are part of the versioned draft JSON.

### D-71 The composer follows the active session page
A subagent page is editable. `SessionFeature.openSubagent`/`popPage`/`popToRoot` send `.composer(.switchTarget)`;
the outgoing draft (including failed/outbound records) is saved, the destination record is loaded, and the new
target is the page’s session ID. A send captures its target in the outbound record. A result arriving while a
different page is visible resolves the operation’s own target record instead of calling the visible composer’s
accept/fail actions. A create that returns after the session child was replaced checks cancellation before the
prompt mutation.

### D-72 Project-to-session migration is destination-first
`ComposerDraftStore.migrate` writes the session key first (skipping it when a newer save already exists), then
removes the New Session key. Cleanup failure leaves both records and is reported as `.couldNotCleanUpDraft`;
destination failure leaves the source and is reported as `.couldNotSave`. The source gains `createdSessionID`
before migration; `recoverCreated` can find it after a restart and retry the destination-first migration. The
composer target moves to the created session only after its record is safe or recoverable.

### D-73 Dismissal is an identity-bound persistence handoff
Done creates a `PendingSessionDismissal(requestID, serverID, sessionID)` and asks the session to flush its
composer. `SessionFeature` forwards the composer’s explicit `ComposerDraftSave`; App closes the session only when
the request ID and session identity still match. A failed/too-large save keeps the session open and shows a
notice. Replacement, server switch, disconnect and interactive dismissal save the departing draft through an
App-owned effect before removing the child. No arbitrary sleep participates in dismissal.

### D-74 Long input grows then scrolls
`ComposerTextInput` grows to 168 pt; beyond that it enables internal scrolling and scrolls the caret/selection
into view. Shrinking below the cap disables scrolling and resets the offset. Marked text, selection, Dynamic Type
and the keyboard inset are unchanged. A physical IME/hardware-keyboard check remains unverified.

### D-75 A retry records its actual message ID before the prompt
`ComposerFeature` owns message-ID allocation for retries. A definite failure retries under a new ID that is
written into `ComposerOutbound` before the delegate runs. An ambiguous failure keeps its recorded ID and is
reconciled first; a confirmed absence produces `retryMessageIDConfirmedAbsent`, after which the composer replaces
the outbound record with a new ID and saves it before issuing the prompt. A failed save restores the previous
identity and sends nothing. Accept/fail/unverify actions match the dispatched ID and never fall back to another
outbound record. This keeps the stored record, optimistic row, restart recovery and client request ID identical.

### D-76 A failed departing-draft transfer stays app-owned
`AppFeature` tracks each departing draft as a `DraftTransfer(id, key, draft)`. The save effect reports an
explicit result; a failure retains the draft under its original server/key in `retainedDraftTransfers`, shows a
`draftKept` notice, and leaves the in-memory copy available. Retries run on launch, foreground and navigation,
and a completion is fenced by transfer ID, key and the exact draft. `ComposerDraftStore.saveIfNewer` compares
`updatedAt` first and `revision` as a tie-breaker, so a transfer from a session whose revision restarted cannot
replace newer content. A successful save clears a retained copy it supersedes; a newer retained copy wins.

### D-77 Dismissal waits for the content, not just a request
`flushForDismiss` captures the complete draft snapshot (text, quotes, failed sends, outbound) and a flush token.
When the save completes, the composer compares the current snapshot with the saved one; if newer content exists,
it saves that content and only then reports a saved completion. A failure or over-limit result keeps the session
open. `AppFeature` still fences the completion by request ID and session identity. The debounced save is
cancelled while a flush is active, and a later flush token invalidates an earlier completion.

### D-78 P-4 is resolved with the system photo picker, and the camera is a system capture bridge
`PhotosPicker` is the only photo surface; there is no in-app photo sheet, morph or send flight. The camera
button opens `UIImagePickerController` in `.camera` mode, which owns permission, unavailable-device states and
the capture UI. This is a deliberate native adaptation of the audited in-app camera (lenses, pinch zoom,
AE/AF lock and its own shutter are not reproduced). The composer limits a pick to eight images and four
pastes; a picked video is not requested, while a video attached through Files uploads and plays.

- Replaces: the open plan question `P-4`.
- Evidence: `ComposerViews.swift`, `CameraCaptureSheet.swift`, `ComposerFeature.importSources`.
- Not claimed: pixel or gesture parity with the recovered camera sheet.

### D-79 Attachments are app-owned staged files, never picker URLs
An import copies bytes into `Application Support/ComposerAttachments/<hashed server>/<attachmentID>/<name>`.
Drafts store only `storedName` plus metadata and transfer state; a security-scoped or picker URL is used for
the copy and then released. Writes are atomic and protected; a failed write removes only its new folder.
Source bounds are 20 MB for an image (re-encoded to 1568 px JPEG 0.8 with EXIF removed) and 100 MB for a
file, with MIME determined from the actual name, declared type and first 4 KiB.

- Why Application Support: a draft's attachment is not cache and must survive a cache purge.
- Writes use an app-controlled `ComposerAttachments/.staging` directory and move into the final
  attachment folder only after completion. Launch cleanup deletes only that namespace; an imported
  `report.tmp` or `capture.partial` is a final file and is never inferred disposable from its name.
- Gate: `MediaImportTests`, `MediaAttachmentTests.{abandonedCleanup,importedSuffixesSurviveScratchCleanup,cleanupKeepsRecordsAndLeases}`,
  ownership tests in `ComposerAttachmentTests`.

### D-80 Uploads discover the writable temp path once and retry the same path
`POST /api/experimental/fs/write` is reached only after `/api/info` reports `paths.tmp`. The request streams
the staged file through `URLSession.upload(fromFile:)` with the request's own credentials, reports throttled
progress (about 1% or 64 KiB steps), and reuses one absolute `<tmp>/uploads/<uuid>/<name>` path across retries,
so a retry overwrites rather than duplicates. A 404 without `Location` is `.unsupported`.

The protocol exposes no resumable upload session: a tab termination or cancelled request is not resumed. The
source copy is retained and the restored attachment becomes `.failed(.uploadInterrupted)` with Retry. A file
already uploaded keeps its server path and its local copy is released.

- Path identity is the attachment ID: `<tmp>/uploads/<uploadID>/<name>`. Every retry and every
  restart retry uses that same ID; a retry overwrites rather than creating a second server file.
- Ambiguity: the request may have reached the server before a failure. Retrying the same path is idempotent;
  no prompt is issued until every attachment is ready. No resumable session exists.
- An upload operation carries its originating server/key, attachment and monotonic attempt. A hidden
  completion merges into the parked/persisted draft with newer-content preservation; an older attempt
  arriving after a retry is ignored. A hidden merge failure is surfaced and retried when the owner is
  visible; the source is retained meanwhile.
- Gate: `MediaClientTests.uploadRequest`, `uploadUnsupported`; `ComposerAttachmentTests.{uploadFailureAndRetry,
  removeDuringUpload,interruptedUploadRestoresAsFailure,uploadCompletesWhileAnotherDraftIsVisible,
  oldCompletionAfterRetryIsIgnored,hiddenUploadPersistenceFailureRetries}`.
- Unverified: the real upload delegate path against a loopback server, because the test server reads only
  what arrives with the headers.

### D-81 Media blobs use bounded memory and disk tiers with per-server 404s
`MediaReferenceCache` keeps at most 48 MiB/64 entries in memory and 256 MiB of `<hash>.blob` files on disk,
trimming oldest finished blobs after a write and never charging or deleting an in-flight `.partial`. A 404 is
remembered per server persistence ID in memory only. Concurrent loads of one blob coalesce. A memory warning
drops the memory tier and decoded images, then trims disk; staged attachment files are outside both caches.

- Source: current `dev` `MediaReferenceClient.kt` and the adopted `media-cache-limit` branch behaviour
  (256 MiB disk cap, finished-blob trim, off-main work).
- Authentication scope: memory keys and disk paths include a SHA-256 token over the server persistence
  identity and credentials; no raw credential is stored in a filename or log. Changing credentials changes
  the scope, so old bytes are not read under the new scope; old files remain until disk trim.
- Hash validation: fetched bytes and disk-loaded bytes must match the requested lowercase SHA-256. A corrupt
  disk entry is removed and refetched; a mismatched fetch is rejected and never cached. Cache-only and
  decoded-image keys carry the same scope.
- Gate: `MediaReferenceCacheTests` (coalescing, scope isolation, credential change, mismatch, corrupt disk,
  trim), `CodePreview`/decode bounds.

### D-82 Viewers are native and remote playback is downloaded first
Images are decoded off the main actor into a bounded cache and drawn in a UIScrollView zoom/pan surface; a
gallery is one SwiftUI page view. Videos/audio and PDFs are downloaded through the authenticated client into a
Caches scratch file before AVPlayer/PDFView sees them, so no server credential is handed to a media framework
and no external URL is fetched. Scratch files are removed on the next launch.

- Opening a viewer never mutates the transcript or the composer; it is a `@Presents` child of the session.
- An inline page source compares by length, not content, so an image's megabytes are not hashed on every
  session action; identity is the transcript image ID.
- Gate: `MediaUITests`, `SessionMediaTests`.
- Not claimed: the audited viewer's flight, PIP, per-page audio chrome or hand-off into the composer.

### D-83 Server file paths stay remote and previews are bounded
A file card resolves to `(location, relativePath)` and calls `GET /api/fs/read/{relative}`; a path is never
passed to `FileManager`. Absolute paths outside the session folder use their parent as the location, and `~`
is not resolved. Text previews read at most 2 MiB, highlight at most 64 KiB/1,500 lines with 4 KiB lines, and
fall back to plain numbered lines beyond that. PDFs and media take the authenticated download path.

- `GET /api/fs/list` is implemented and tested but has no session folder-browser screen in P10; file
  autocomplete owns that surface in P11.
- Gate: `AgentFilePath` tests, `FileViewerTests`, server-file UI journey.

### D-84 Annotation produces a new attachment and never edits the original
Drawing uses normalized strokes, six inks and an undo stack. Save flattens at the image-import bounds (JPEG
0.8, long edge ≤1568) off the main actor and adds the result to the same composer through the normal image
importer. Cancel or discard leaves the original attachment and draft unchanged. The editor is full-screen and
uses the system sheet dismissal for cancel; there is no bitmap flight.

- Gate: `MediaRenderingTests.annotationRenderer`; `MediaUITests.testAnnotationReturnsADrawingToTheComposer`.

### D-85 The in-app browser is Experimental, public-only and bounded
WKWebView is used only as a page surface, never as the app shell. It is off by default (`in-app-browser`,
Settings owns the switch in P11); a DEBUG launch argument enables it for UI tests, and a second DEBUG argument
allows a loopback fixture page served by the test runner. Each visit uses a
non-persistent data store, no script-message bridge, default file access off, and no server object or auth
headers. Navigation is allowed only for public `http(s)` pages; private/loopback/tailnet/IP/credentialed or
signed links are handed to the system, pairing links are never loaded, and downloads or unshowable responses
open externally. A failed load shows a message and Try Again.

- Deferred: Ask/page-context prompts and browser page sharing; both need the page-context prompt contract.
- Gate: `BrowserPolicyTests`, `SessionMediaTests.browserGate`, `MediaUITests.testBrowserGateOpensOnlyWithTheExperiment`.

### D-86 Transcript media identity is the existing row/part identity
A user image row and a tool mosaic use the transcript's stable item and part IDs; a gallery page is keyed by
its image ID. New transcript rows arriving during viewing do not replace the viewer. A tool mosaic opens the
same gallery as a user image group.

- Gate: `SessionMediaTests.imageGalleryPresentation`; UI gallery/mosaic journeys.

### D-87 Math and Mermaid keep the source fallback
No maintained math or Mermaid renderer was adopted. Math remains the source in a code band; Mermaid remains
an ordinary fenced code block. This is the phase's explicit final fallback: a renderer would add either a
native math library or a WebKit/JS renderer with offline, licence and untrusted-content obligations that are
not justified by the reproduced behaviour. The blocks are not labelled as rendered output.

- Owner if revisited: P14, with an offline/licence/untrusted-content evaluation and a pinned dependency.

### D-88 Cross-block selection remains deferred
Selecting one reply as a single document is not rebuilt. Native per-block selection and the reply Copy action
remain, and quote handoff stays one block. A later bridge must preserve native handles, accessibility and
performance; building a custom text engine is not justified now.

- Owner: P14. Acceptance: one reply selects across blocks with native handles and becomes one quote without
  losing the composer draft.

### D-89 Background subagent stop and shell copy/share are P10 surfaces
Stop on a subagent interrupts the child when the family marks it active and cancels every running job owned by
that child or a descendant; the stopping set is optimistic and a failure keeps rows and surfaces a problem.
Shell output gains Copy and Share in its sheet, using the existing pasteboard dependency and native share
presentation; the share extension/App Group is still P12.

### D-90 Memory pressure and launch cleanup are explicit
A memory warning clears decoded images and the media memory tier, then trims the disk tier. App launch clears
the viewer scratch directory and staging `.partial`/`.tmp` files. A draft's staged folders are not swept by a
cache trim; sweeping folders no draft/failed/outbound record names is deferred to P14.

### D-91 Staged sources are released only after a durable save
`ComposerFeature.pendingReleases` is a set of staged names whose owner no longer needs the local file in
memory. A release is attempted only after `.saveFinished(.saved)` and only when the name is absent from the
current draft, every parked draft, failed sends, outbound records, upload operations and the persisted
draft store (which includes other sessions and failed/outbound records), and when no `MediaFileStore` lease
holds it. A failed save, an unreadable draft store, a persisted reference or a lease keeps the file.

- Upload success, accepted-send cleanup and removal only queue a release; none deletes immediately.
- A hidden upload is merged with `ComposerDraftStore.applyAttachmentTransfer`, which preserves newer text
  and quotes; a merge failure is kept in `deferredUploads` and retried when the owning key is visible.
- Leases cover preview reads and annotation sources, so a viewer cannot lose bytes during cleanup.
- Gate: storage-backed tests for failed save, restart, failed removal, outbound ownership and viewer lease.

### D-92 Bounded downloads consume the stream, not a completed body
Media blobs and server file reads use `HTTPTransport.open` and a cumulative received-byte bound. A declared
`Content-Length` over the bound is rejected before reading the body; otherwise every chunk is counted and the
stream is closed immediately on overflow with `OpenCodeClientError.responseTooLarge(feature:)`. A missing or
understated length cannot bypass the cumulative limit. Error bodies for status mapping are read only to a
64 KiB prefix. Redirect and credential rules are the request's existing rules.

- The media blob limit is injectable through `OpenCodeClient.live(mediaBlobLimit:)`; file reads pass their own
  caller limit.
- Gate: loopback tests for declared, chunked and understated bodies, connection close on overflow, and a
  within-bound body.

### D-93 Cache scope is authentication-bound, not hash-only
Authenticated media is partitioned by `MediaCacheScope.token(for:)`: a SHA-256 over `persistenceID`,
username and password, truncated for filenames. Memory keys, disk paths, negative 404 entries, coalescing
keys and decoded-image keys use it. A credential change invalidates reads under the old scope without
rewriting or exposing the credential. Content is still verified by SHA-256 before admission, so a server
cannot substitute different bytes for a requested hash.

- Gate: same-hash two-server isolation, second-scope mismatch, credential change, corrupt disk, fetch
  mismatch, coalescing and normal disk hits.

### D-94 Settings surfaces only experiments this build implements
`SettingsFeature` lists the In-App Browser switch, the supported appearance choice and the audited
Return/Wrap keys. Android's remaining experiments gate P12/P13 features or have no iOS
implementation; they are not displayed as inert controls. All Experiments was not adopted because a
single supported experiment makes the bulk control misleading. The registry's key names remain
available for future phases.

- Evidence: `ExperimentalFeature.kt`, `ExperimentalSettingsView.kt`, `SharedKeys.kt`.
- Gate: `SettingsFeatureTests.browserExperimentChanged`, `SettingsUITests.testPreferenceSurvivesRelaunch`.

### D-95 A saved header is validated, origin-bound and part of the cache scope
Custom header names must be RFC 9110 tokens; values may not contain line breaks; blank rows are
refused; `Authorization`, `Proxy-Authorization`, `Host`, framing, connection and upgrade fields are
transport-owned and refused. Saving happens only after validation and a successful Keychain write,
so a failed save leaves the prior server editable and usable. Existing same-origin redirect rules
keep headers from travelling to another origin. `authenticationScopeMaterial` hashes the sorted
sendable headers with the server identity and credentials, so a header change starts a new
authenticated media-cache scope instead of reusing bytes authorized by the old header set.

- Replaces the P10 scope that hashed only server identity, username and password.
- Gate: `headerPolicy`, `saveFailureKeepsPriorServer`, `headerChangeInvalidatesAuthenticationScope`,
  P10 `MediaReferenceCacheTests`.

### D-96 Copied diagnostics are an allow-list of typed facts
`DiagnosticFacts` contains app version/build, phase, failure kind, HTTP status and bounded counts.
`DiagnosticReport` emits a fixed field order. It has no string field for an error, URL, address,
header, pairing code, message or path, so a call site cannot accidentally dump one. Collection is
user initiated and Copy uses the existing pasteboard dependency.

- Gate: `diagnosticsPrivacy` rejects synthetic credentials, header names/values, addresses, pairing
  text and content markers; `SettingsUITests.testDiagnosticsCollectAndCopy`.

### D-97 QR scanning is a payload boundary, never a redemption path
`PairingScannerClient` emits decoded QR payloads (or typed camera states). Production uses
AVFoundation metadata output; simulator tests inject payloads through the same client. The scanner
does not parse, confirm or redeem. `SettingsFeature` forwards the first payload for a scan and
ignores duplicates until a new scan; the app shell still shows the existing confirmation before
spending the one-time code. When a code arrives, Settings leaves the screen and the shell opens
confirmation after the cover dismisses.

- Physical camera, permission prompts and duplicate real-world frames remain P12 checks.
- Gate: `scanIsForwardedExactlyOnce`, `cameraDenied`,
  `SettingsUITests.testInjectedQRShowsConfirmationExactlyOnce`.

### D-98 The shipped What's New catalogue is reconstructed, not invented
`WhatsNewCatalogue` contains the 182 audited Kotlin entries with their permanent IDs, days, titles,
summaries, details, examples, symbols and tints. IDs and days are copied, not regenerated. Seen state
continues in `whats-new-seen`. Try It routes to a new session or the relevant Settings surface where
this build implements one; every other destination is rendered as explicitly unavailable instead of
a dead button.

- Gate: `WhatsNewCatalogueTests`, `WhatsNewView` UI journeys, P6 seen-state tests.

### D-99 Model and agent choices are applied once and snapshotted
The composer owns the pending model, reasoning variant and agent. A send applies the agent first,
then the model, immediately before the prompt for ordinary and first sends, with one application per
dispatch. A queued message does not change the run's model. A refused switch fails the send and
keeps the draft. Model, agent and chips are written into the composer draft, the failed-send record
and the outbound record before dispatch, so restart/retry cannot silently send with another choice.

- The catalogue's default route is optional for older servers.
- Gate: `SessionSelectionTests.sendAppliesSelectionBeforePrompt`, `refusedSwitchDoesNotPost`,
  existing outbound/retry tests, `ComposerAutocompleteTests.promptShape`.

### D-100 Autocomplete fences queries and sends semantic mentions only for intact tokens
Triggers are detected in UTF-16 at the caret; a caret inside a committed chip does not reopen the
list, and marked IME text closes it rather than committing. Skill, agent, command and file rows are
bounded to eight; file searches debounce 250 ms and carry a generation plus server, directory and
query identity, so a stale result cannot replace rows or text. A chip is stored as semantic kind,
value, token and title. At send time its token is located by exact UTF-16 range and boundary; an
edited token contributes no mention. The prompt carries the audited `agents`, `skills` and file
`files` shapes with `file://` URIs. Session mentions are deliberately not reproduced.

- Gate: `ComposerAutocompleteTests`, `ComposerMentions` prompt tests,
  `ComposerContextUITests.testModelAgentAndMentionSelection`.

### D-101 The folder browser reads only remote paths and preserves the draft
`FolderBrowserFeature` starts at the server's default directory and reads a route only when opened,
one `GET /api/fs/list` through the authenticated client. Paths are opaque server strings; no
`FileManager` path is derived. Loading, failure/retry, empty and back states are explicit. Selecting
a folder changes a new session's project target in place, without clearing text, quotes,
attachments, chips or failed sends; cancel changes nothing. File autocomplete and folder selection
are separate from P10's staged attachment imports.

- Gate: `FolderBrowserTests` (on-demand reads, cached back, typed failure, ancestors, draft-preserving
  selection), `ComposerContextUITests.testFolderBrowseSelectionAndCancelKeepTheDraft`.

### D-102 Return and Wrap Lines are consumed by their native surfaces
`ComposerTextInput` takes the stored `return-key-sends` value and applies one rule: plain Return
sends when enabled and inserts a newline when disabled, Shift+Return always inserts a newline, and
a marked IME composition is never interrupted. The request-answer bar uses the same boundary but
its send closure is the request submit action, so a keyboard send can never become a chat message.
`FileViewerFeature` owns `wraps-lines`: the Settings switch and the viewer's own toolbar write the
same key, and the open viewer switches immediately between wrapped vertical layout and horizontal
scrolling. App and Session states receive the loaded values and every successful Settings change.

- Replaces the P11 partial rows that persisted the toggles without consumers.
- Gate: `ComposerReturnKey` tests, `FileViewerTests.wrapTogglePersists`/`wrapFailureKeepsMode`,
  `PreferenceBehaviorUITests` (composer relaunch, request bar, live viewer toggle and relaunch).

### D-103 Server records commit through one serialized recoverable boundary
`savedServer`, `savedServers` and the Keychain `ServerWriteIntent` are owned by one process-wide
`ServerWriteTransaction` boundary. Settings edits/removals, pairing/connection persistence, forget-all
and explicit saved-data replacement all enter it; a launch read uses its `read` path. A mutex makes
the intent/list/selected sequence serial, so an unfinished intent is never overwritten. The intent
records both before and after states. A failed write rolls both records back; if rollback itself
fails, the intent and its original recovery information remain and a later read retries before
trusting either record. Rollback merges a newer selected server/list entry that was never part of
the failed operation, and the selected server is always present in the returned list. Successful
outcomes re-read and return the actual committed pair.

- Intent values carry credentials, so they live in the Keychain, never in logs or UserDefaults.
- Preserves partial-corruption facts through `ServerWriteTransaction.read` so the existing
  explicit saved-data recovery UI remains available.
- Explicit recovery operations (`replaceRecoveringCorrupt`, `forgetRecoveringCorrupt`) are the only
  paths allowed to overwrite records that do not decode. They snapshot the exact raw bytes in the
  intent so a partial failure restores the corrupt records rather than silently treating them as
  empty. Ordinary saves/removals still refuse corrupt records and a corrupt/unfinished intent.
- Gate: `ServerWriteTransactionTests` (failure at every step, newer-selection collision, actual
  success outcome, failed rollback/restart, unresolved-intent overwrite prevention, corrupt-intent
  blocking), `SavedDataRecoveryTests` (corrupt list/selected/both, manual connection then replace,
  Forget All, failed replacement/removal retries) and `ServerEditIntegrationTests` (second-write
  failure, active/non-active edits, removal, late completion, duplicate submission and connection
  persistence through the boundary).

### D-104 Server edit/removal operations are identity-fenced and draft-safe
Settings attaches an edit-operation UUID to each submission and refuses a second submission while
one is pending; a result is accepted only for the current form and operation. App stores its own
`ServerWriteOperation`, ignores duplicate work, and checks the originating server's previous
identity at completion, not the updated persistence ID. An active edit or removal transfers the
composer through the existing durable draft-transfer path before reconnect/disconnect; a late
completion after a server switch updates records but never reconnects the old server.

- Gate: `ServerEditIntegrationTests` for active address/credential changes, non-active edits,
  active removal, late completion and duplicate submissions; Settings fencing test.

### D-105 Mention occurrences own identity and ranges
`ComposerMentionChip.id` is a generated occurrence identity; `suggestionID` names the catalogue row.
Each occurrence stores its UTF-16 range. The native text bridge reports the minimal edit between
committed text states; ranges before the edit shift, edits touching the token invalidate it, and no
code searches for a display token at send time. Draft encoding persists occurrence IDs and ranges;
restore uses those exact spans. Repeated selections of one suggestion and duplicate filenames are
distinct occurrences.

- Gate: envelope/trigger tests for duplicate filenames, repeated picks, identical ordinary text,
  deletion/retyping, edits before/inside, Unicode, invalid spans and persistence.

### D-106 Composer catalogue requests have independent ownership
Model/agent/autocomplete loads use separate cancellation identities (`modelCatalog`,
`agentCatalog`, `autocompleteCatalog`) and the autocomplete request no longer duplicates the agent
catalogue call. A repeated load cancels its previous request set; results are fenced by server and
directory. The gated reducer tests hold every real client operation open and prove both model and
autocomplete results arrive, repeated loads replace earlier ones and navigation discards late work.

### D-107 The scanner cover stays up for a typed camera problem
`SettingsFeature.State.isScanPresented` is true while scanning **or** while `scanProblem` is non-nil.
`SettingsView` binds the full-screen cover to that value, so a denied/restricted/unavailable camera
keeps the typed explanation and Done/Cancel visible instead of dismissing the cover with the failed
scan. `scanCancelled` clears both the scan and the problem, so the Cancel button and an interactive
dismissal close it. A subsequent scan starts from a clean problem state.

- Replaces the P11 binding to `isScanning` alone, which hid every camera problem on a physical phone.
- Gate: `SettingsFeatureTests.cameraDenied` (cover stays presented; problem dismissal closes it) and
  `cameraProblemCancelDismisses`; device retest with Camera disabled.
- Verified on the iPhone Air under P12; see `DEVICE_VALIDATION.md`.

### D-108 Device evidence stays in its own category
The P12 run records host package tests, automated device tests, device probes, manual observations,
real LAN fixture behaviour and simulator-only evidence separately. A probe running in the app process
does not prove the camera, Keychain entitlement or socket boundary; those checks use the physical
camera, the signed app's Keychain and real LAN sockets. Simulator screenshots and traces are not
promoted to device passes. The connected iPhone runs iOS 27.3 although the checklist named 27.2; the
mismatch is recorded rather than hidden, and no OS substitution, beta install or phone upgrade was
performed. Synthetic resources only; raw logs, QR images and personal screenshots stay outside the
repository.

- The LAN fixture must answer the client's real envelopes (`{data: …}` for catalogues and session
  creation, not bare arrays). A fixture that returns the wrong payload is recorded as tooling, not as
  a product failure.
- See `DEVICE_VALIDATION.md` and `P12_DEVICE_CHECKLIST.md` for the per-row results and the remaining
  blocked checks (photo/file providers, playback interruption, hardware Shift+Return, real memory
  pressure, denied-Keychain injection, compatible live server, push).
