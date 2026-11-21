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
- No Apple account setting, signing identity or entitlement is changed by this decision.

### D-16 iPad is out of scope
iPhone only for this migration. `TARGETED_DEVICE_FAMILY = 1`; no iPad layout, multitasking or size-class work
is planned until the product requirements ask for it.

