#!/usr/bin/env bash
# Builds the app and runs the test suites against a simulator that exists on this machine.
#
#   --package-only   run only the Swift package tests (host macOS)
#   --skip-ui        skip the UI test target
#
# Environment:
#   OPENCODE_DESTINATION / OPENCODE_SIM_NAME / OPENCODE_SIM_RUNTIME  see destination.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios_root="$(cd "$here/.." && pwd)"
results_dir="$ios_root/.build-results"

package_only=0
skip_ui=0
for argument in "$@"; do
  case "$argument" in
    --package-only) package_only=1 ;;
    --skip-ui) skip_ui=1 ;;
    *) printf 'unknown option: %s\n' "$argument" >&2; exit 2 ;;
  esac
done

mkdir -p "$results_dir"

# Xcode 27 requires each SPM macro plugin to be trusted before it can run. The flag is scoped to
# these two invocations only; see docs/ios-migration/TOOLCHAIN.md. Do not add it globally.
macro_flag=(-skipMacroValidation)

if [[ $package_only -eq 1 ]]; then
  swift test --package-path "$ios_root/OpenCodeKit"
  exit $?
fi

destination="$("$here/destination.sh")"
printf '%s\n' "$destination" > "$results_dir/destination.txt"

"$here/env.sh" | tee "$results_dir/toolchain.txt"

cd "$ios_root"
xcodegen generate

xcodebuild -project OpenCode.xcodeproj -scheme OpenCode \
  -destination "$destination" \
  "${macro_flag[@]}" \
  build | tee "$results_dir/build.log" | tail -n 20

if [[ $skip_ui -eq 0 ]]; then
  xcodebuild -project OpenCode.xcodeproj -scheme OpenCode \
    -destination "$destination" \
    "${macro_flag[@]}" \
    test | tee "$results_dir/test.log" | tail -n 40
else
  xcodebuild -project OpenCode.xcodeproj -scheme OpenCode \
    -destination "$destination" \
    -only-testing:OpenCodeTests \
    "${macro_flag[@]}" \
    test | tee "$results_dir/test.log" | tail -n 40
fi

swift test --package-path OpenCodeKit | tee "$results_dir/package-tests.log" | tail -n 20
