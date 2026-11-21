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
2. **Command line or CI, narrowly scoped:** pass `-skipMacroValidation` on the single `xcodebuild` invocation that
   builds this project's scheme. `ios/scripts/verify.sh` does exactly that, and only that.
3. **Rejected:** `defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES`, any
   `build.xcconfig` or project setting that disables validation, or a wrapper that silently adds the flag to every
   `xcodebuild` call. Those hide the trust decision from the operator and apply repository-wide.

Pinning exact versions keeps the fingerprint set stable: a version bump re-prompts for trust, which is the intended
signal that new plugin code is being executed.
