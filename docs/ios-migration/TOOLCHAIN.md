# Toolchain — verified versions and the macro-validation finding

Verified on the audit machine with the requested toolchain; no substitution was used.

| Tool | Version |
| --- | --- |
| Xcode | 27.2 (build 27B52) |
| Swift | 6.4.2 |
| iOS SDK | 27.2 |
| iOS simulator runtimes | 27.2, 27.0, 26.5 |
| macOS | 27.2.1, arm64 |

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

## Verified results

| Command | Result |
| --- | --- |
| `ios/scripts/env.sh` | Xcode 27.2, Swift 6.4.2, iOS simulator SDK 27.2 |
| `xcodebuild -list` | scheme `OpenCode` present (plus package schemes) |
| `xcodebuild … build` | succeeds for `OpenCode` on the derived simulator (iPhone 18 Pro Max, iOS 27.2) |
| `xcodebuild … test -only-testing:OpenCodeTests` | 3 tests pass |
| `xcodebuild … test -only-testing:OpenCodeUITests` | 3 launch smoke tests pass |
| `swift test --package-path OpenCodeKit` | 25 tests pass (18 core, 7 app) |

