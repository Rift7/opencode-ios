# iOS migration — decisions

Recorded decisions for the native rebuild. Each decision names what it replaces so the audit evidence stays
distinguishable from a current choice.

## Approved by the owner

### D-1 Typography — system fonts only
Interface text uses the system SF font; code, logs, tool output and other monospaced content use system SF Mono.
No font files are bundled. Berkeley Mono, Inter and OpenMono are not migration defaults.

- Replaces: the audit's open question D-1, and the Android baseline's Inter + OpenMono desktop typography.
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

- Local/CI verification may pass `-skipMacroValidation` on the single `xcodebuild` invocation for this scheme,
  which is what `ios/scripts/verify.sh` does and what its help text states.
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
