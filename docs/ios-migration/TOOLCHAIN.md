# Toolchain — verified versions and the macro-validation finding

Verified on the audit machine with the requested toolchain; no substitution was used.

| Tool | Version |
| --- | --- |
| Xcode | 27.2 (build 27B52) |
| Swift | 6.4.2 |
| iOS SDK | 27.2 |
| iOS simulator runtimes | 27.2, 27.0, 26.5 |
| macOS | 27.2.1, arm64 |
| Physical device for P12 | iPhone Air, **iOS 27.3 (24C5049f)** |

Dependency resolution for the app (via `ios/OpenCodeKit`):

| Package | Version |
| --- | --- |
| swift-composable-architecture | 1.26.2 (exact) |
| swift-dependencies | 1.17.2 |
| swift-sharing | 2.10.1 |
| swift-navigation | 2.11.2 |
| swift-perception | 2.0.12 |
| swift-syntax | 604.0.0 |

## Macro validation

### Symptom

A fresh checkout that resolves TCA fails before compiling any project code:

```
error: Macro "ComposableArchitectureMacros" from package "swift-composable-architecture"
       must be enabled before it can be used
error: Macro "CasePathsMacros" from package "swift-case-paths" must be enabled ...
error: Macro "DependenciesMacrosPlugin" from package "swift-dependencies" must be enabled ...
error: Macro "PerceptionMacros" from package "swift-perception" must be enabled ...
error: Macro "SwiftNavigationMacros" from package "swift-navigation" must be enabled ...
```

The failing build phase is `ComputeTargetDependencyGraph`, so the failure appears even when nothing imports
`ComposableArchitecture`. Verified with a minimal package (`platforms: [.iOS(.v27)]`, exact TCA `1.26.2`) built by
`xcodebuild -destination 'generic/platform=iOS Simulator'`, and again with this project.

### Scope

- Affects every SPM package that ships a compiler plugin (macro), not only TCA: TCA, swift-case-paths,
  swift-dependencies, swift-perception, swift-navigation.
- Independent of iOS/Swift version; it is Xcode's plugin-trust gate for package macros, introduced with the
  macro system and still enforced in Xcode 27.
- Does **not** affect packages without macros, or targets that never resolve these packages.

### Resolution

1. **Developer machine (preferred):** build once in Xcode and accept the per-plugin trust prompt. Trust is stored
   per user and per plugin fingerprint.
2. **Command line or CI, narrowly scoped:** pass `-skipMacroValidation` on the `xcodebuild` invocations for this
   project's scheme. `ios/scripts/test.sh` adds it to exactly two commands — its `build` and its `test` — and
   `ios/scripts/verify.sh` delegates to that script. `--package-only` runs no `xcodebuild` at all, and nothing
   else in the repository passes the flag.
3. **Rejected:** `defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES`, any
   `build.xcconfig` or project setting that disables validation, or a wrapper that silently adds the flag to every
   `xcodebuild` call. Those hide the trust decision from the operator and apply repository-wide.

Pinning exact versions keeps the fingerprint set stable: a version bump re-prompts for trust, which is the intended
signal that new plugin code is being executed.

## Compiler and project notes

Three findings from building the scaffold. Each is reproducible and already worked around; none of them changes
the architecture.

### `ReducerOf<Self>` fails to expand in the app module

With `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, a public `@Reducer` whose body is declared as
`some ReducerOf<Self>` fails with:

```
macro expansion @Reducer:1:1: error: circular reference
note: while resolving type 'ReducerOf<Self>'
note: in expansion of macro 'Reducer' on struct 'AppFeature'
```

Writing the same body as `some Reducer<State, Action>` compiles; the two are equivalent. The reducer now lives
in the `OpenCodeApp` package target, where either spelling is accepted, and the explicit form is kept.

### A `.run` effect must capture clients, not the reducer

In a nonisolated package target, `return .run { send in await probe.check() }` captures `self` and fails with
`capture of 'self' with non-Sendable type`. Bind the dependency client to a local (`let probe = probe`) before
the effect. In the app target the MainActor default hid this; the package target is strict about it.

### An app-hosted unit-test bundle could not link TCA

An `OpenCodeTests` bundle configured with `dependencies: [target: OpenCode]` and the
`ComposableArchitecture` product built `ComposableArchitecturedynamic-product` and failed:

```
ld: symbol(s) not found for architecture arm64
  "(extension in SwiftNavigation):SwiftUI.Text.init(SwiftNavigation.TextState) -> SwiftUI.Text",
  referenced from: … in ComposableArchitecture.o
```

The Xcode unit-test target is now hostless and TCA-free; reducer tests run in the package, where the same code
links and passes. If a future phase needs app-hosted UI tests with TCA, resolve this at the project level
(explicit `SwiftNavigation`/`SwiftUINavigation` products, or a different test host) rather than by weakening
concurrency or test coverage.

### A hostless unit-test bundle cannot reach the Keychain

`SecItemAdd` in `OpenCodeTests` returns `-34018` (`errSecMissingEntitlement`): hostless bundles carry no keychain
entitlement, and an app-hosted bundle cannot link TCA in this project (previous note). The real round trip
therefore runs in the app process through a DEBUG-only `-uiTestKeychainProbe` launch argument, asserted by
`OpenCodeUITests/KeychainProbeTests`. Unit-level storage logic stays in the package with in-memory doubles.

## Verified results

| Command | Result |
| --- | --- |
| `ios/scripts/env.sh` | Xcode 27.2, Swift 6.4.2, iOS simulator SDK 27.2 |
| `xcodebuild -list` | scheme `OpenCode` present (plus package schemes) |
| `xcodebuild … build` | succeeds for `OpenCode` on the derived simulator (iPhone 18 Pro Max, iOS 27.2) |
| `xcodebuild … test -only-testing:OpenCodeTests` | 3 tests pass |
| `xcodebuild … test -only-testing:OpenCodeUITests` | 3 launch smoke tests pass |
| `xcodebuild … test -only-testing:OpenCodeUITests/KeychainProbeTests` | Keychain add/read/update/remove pass |
| `swift test --package-path OpenCodeKit` | 75 tests pass (61 core, 14 app) as of Phase 3 |
| `xcodebuild … test` (Phase 4) | app build succeeds; 2 Swift Testing platform tests; 4 UI tests |
| `swift test --package-path OpenCodeKit` (Phase 4) | 205 tests pass (125 server, 66 core, 14 app) |
| `swift test --package-path OpenCodeKit` (review corrections) | 222 tests pass (142 server, 66 core, 14 app); the live suite is skipped without env vars |
| `swift test --package-path OpenCodeKit` (overflow follow-up) | 232 tests pass (152 server, 66 core, 14 app) |
| `swift test --package-path OpenCodeKit` (P9) | 492 tests pass (194 server, 67 core, 75 app, 38 drawer, 66 session, 26 transcript, 26 composer) |
| `xcodebuild … test` (P9) | app build succeeds; 58 UI tests pass |
| Device build (iPhone Air, iOS 27.2) | succeeds with `-allowProvisioningUpdates DEVELOPMENT_TEAM=<team> -skipMacroValidation`; automatic signing registered the app |
| Device build and install (P12, iPhone Air iOS 27.3) | same existing signing/profile and unchanged bundle id; installed in place without uninstalling the container |
| `xcodebuild … test` (P12) | 20/20 core device tests, 46/49 grouped feature journeys (three intermittent, pass 2/2 individually), 2/2 real-LAN checks, 12/12 final affected tests after the scanner fix |
| Device performance (P12) | Home 83–84.6 fps/0 hitches; transcript p95 25–26 ms; streaming/media p95 16.7 ms; peak memory ≈18.2–18.5 MB |

| `swift test --package-path OpenCodeKit` (P11 saved-data recovery) | 626 tests pass (209 server, 67 core, 97 app, 41 drawer, 79 session, 26 transcript, 60 composer, 32 media, 15 settings) |
| `swift test --package-path OpenCodeKit` (P12 follow-up) | 630 tests pass; adds setup-scan, agent-prefetch and read-receipt tests on top of the P11 count |
| `xcodebuild … test` (P11 saved-data recovery) | 81/81 grouped UI tests pass on the final code; the earlier known P8 anchor flake remains recorded in `STATUS.md` |
| Phase 11 simulator measurements | iPhone 18 Pro Max, iOS 27.2 (runtime `24B8117`); no physical iPhone, camera, signing team or provisioning change was used |

## Physical-device OS mismatch (P12)

The connected validation phone runs iOS 27.3 (24C5049f). The Phase 12 request named an iOS 27.2
device; no 27.2 phone was connected. The 27.2 SDK still builds and installs onto 27.3, and the
checks whose applicability is clear across the minor version were run. No simulator was substituted,
no beta was installed and the phone was not upgraded or enrolled for this task. Results in
[DEVICE_VALIDATION.md](DEVICE_VALIDATION.md) are therefore **iOS 27.3 device results**, not 27.2.

The P12 follow-up fixes add three package tests (`ComposerCatalogTests.taskLoadsAgentsBeforePicker`,
`HomeFeatureTests.alreadyReadSessionSkipsReceipt`, and the setup-scan Settings test), taking the full
package run to 630 tests. The real-server follow-up used the owner-authorized DeepSeek V4.1 Flash for
one synthetic prompt; no prompts were sent to other models.
