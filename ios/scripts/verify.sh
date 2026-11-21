#!/usr/bin/env bash
# The phase gate: toolchain, project generation, app build, unit and UI tests, package tests.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios_root="$(cd "$here/.." && pwd)"

cd "$ios_root"
"$here/env.sh"
"$here/test.sh" "$@"

printf '\nverification complete. Logs and the selected toolchain are in ios/.build-results/.\n'
