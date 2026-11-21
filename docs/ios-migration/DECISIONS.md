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
| `P-7` | Bundle id, team, App Group, Keychain service | D-8 (historical values are evidence), D-15 (service configurable) | production naming before real credentials |
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
- `@unchecked Sendable` appears at four places only, each a `Mutex`-guarded class whose mutation must stay
  synchronous: `BoundedChannel`, the URLSession redirect guard, the stream receiver and the stream-activity
  holder. Each carries a one-line reason at the declaration; no `nonisolated(unsafe)` is used.
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
