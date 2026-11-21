# AGENTS — native iOS app (`ios/`)

This directory is a native iPhone app: SwiftUI, Swift 6 language mode, Swift 6.4 compiler, Xcode 27.2,
iOS 27.2 deployment target, iPhone only. It is a reconstruction of the OpenCode iPhone app from the
behaviour recorded in this repository's Kotlin sources, parity corpus and audit evidence. It is **not**
a port of the Android tree and does not share its code.

Root `AGENTS.md` describes the Android app and its Gradle modules. Those rules do not apply here except
where a migration instruction says so; this file is authoritative for `ios/`.

## Layout

| Path | Contents |
| --- | --- |
| `ios/project.yml` | XcodeGen spec — the checked-in source of truth for the project |
| `ios/OpenCode.xcodeproj` | generated; never committed |
| `ios/OpenCodeKit/` | local Swift package: all logic and its tests |
| `ios/OpenCodeKit/Sources/OpenCodeCore` | design tokens, motion vocabulary, haptics, logging, dependency clients, storage |
| `ios/OpenCodeKit/Sources/OpenCodeServer` | server address, pairing, wire models, retry, SSE and the client |
| `ios/OpenCodeKit/Sources/OpenCodeApp` | app reducer and launch configuration |
| `ios/OpenCodeKit/Sources/OpenCodeTestSupport` | isolated test environment, scripted network guard (fixtures, chunks, redirects) |
| `ios/OpenCode/App/` | app target: entry point, root view, scenes |
| `ios/OpenCode/{Drawer,Session,Transcript,Composer,Media,Voice,Settings,System}/` | UI areas, filled by their phases |
| `ios/OpenCodeTests/` | hostless unit tests (no TCA dependency) |
| `ios/OpenCode/Info.plist` | app plist: local-network use, ATS local/overlay exceptions |
| `ios/OpenCodeUITests/` | XCUITest launch smoke tests |
| `ios/scripts/` | toolchain check, simulator selection, build/test |
| `docs/ios-migration/` | status, parity, decisions, handoff, toolchain, sanitized audit |

Directories are created when their phase needs them. Do not pre-create empty Swift packages or mirror
the Gradle module list; add a package target only when a layer needs to be tested independently.

## Build and test

```sh
cd ios
./scripts/env.sh          # verifies Xcode 27.2, Swift 6.4, iOS 27.2 SDK
./scripts/destination.sh  # prints a simulator destination that exists on this machine
./scripts/verify.sh       # the full gate: generate, build, unit + UI tests, package tests
```

`verify.sh` accepts `--skip-ui` and `--package-only`. Simulator selection is configurable:

| Variable | Meaning |
| --- | --- |
| `OPENCODE_DESTINATION` | use a destination verbatim |
| `OPENCODE_SIM_NAME` | require this device name |
| `OPENCODE_SIM_RUNTIME` | require this runtime label |
| `OPENCODE_SIM_MIN_RUNTIME` | minimum runtime (default `iOS 27.2`) |

The script derives a device from what is installed; it never assumes a UDID. Logs and the selected
toolchain are written to `ios/.build-results/`, which is not committed.

## Project generation

`xcodegen generate` produces `OpenCode.xcodeproj` from `project.yml`. XcodeGen 2.48 or newer is required.
Everything needed to open and build the project is checked in; the generated project is not, so a
regeneration is always available rather than a stale binary file. Add a target or a build setting in
`project.yml`, never by hand in the generated project.

## Dependencies

- `swift-composable-architecture` **1.26.2**, pinned exactly. Reducers, effects, cancellation identity
  and `TestStore` come from it; do not replace them with view models.
- Add a dependency only with a written reason in `docs/ios-migration/DECISIONS.md`. Pin exact versions.
- No font packages. Interface text uses the system font, code uses the system monospaced design.

## Isolation

The app target uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` with complete strict concurrency.
Package targets stay nonisolated and mark the types that need the main actor (`@MainActor`), because
Foundation and URL loading types are not main-actor bound. Do not add `@unchecked Sendable` or
`nonisolated(unsafe)` to silence a warning; fix the ownership boundary instead. A justified use needs a
one-line reason at the declaration and a `DECISIONS.md` entry.

## Tests

- Swift Testing for logic, reducers and transport; XCTest for UI automation.
- Every test is isolated: a temporary directory, an in-memory store, a pinned clock and a deterministic
  identifier sequence (`OpenCodeTestSupport.IsolatedTestEnvironment`).
- Network is blocked by default in tests (`OpenCodeTestSupport.NetworkGuard`). A test that needs an
  HTTP response registers a fixture on a `.invalid` host. Live checks are opt-in behind environment
  variables that are unset by default.
- Screenshots are captured on a simulator with no personal data in frame and no machine identifiers in
  file names.

## Branches and PRs

- `ios` is the integration branch, based on the audited `dev` commit recorded in
  `docs/ios-migration/BASELINE.md`.
- Each implementation issue gets a task branch from `ios` (`ios-foundation`, `ios-networking`, …),
  pushed to the fork, with a **draft** PR into `ios`. Do not merge, change the default branch, publish
  or distribute from here.
- Commit only files this phase owns. Review the staged diff for personal information (home paths,
  machine names, credentials, server addresses) before committing.

## Copy and assets

- User-visible text lives in string resources, not literals, once a screen is implemented. Reducers and
  errors use the same rule. Tests assert the English text.
- Reuse the recovered accessibility identifiers and copy where they still describe the UI
  (`docs/ios-migration/audit/FEATURE_MAP.md`).
- Log through `AppLog`'s structured records. Public fields are numbers and booleans only (counts, statuses,
  durations, flags); free text goes through `LogPrivateField` and is emitted with private visibility. There is no
  API that publishes an arbitrary string, so a call site cannot leak a credential, path, address or message body
  into the public log by accident.
- Do not bundle fonts. Provider icons and wordmarks arrive with their own phase and their notices.
