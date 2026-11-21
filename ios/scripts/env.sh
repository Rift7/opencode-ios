#!/usr/bin/env bash
# Verifies the toolchain this project is built and tested with. Prints the versions it found and
# exits non-zero when they do not match the migration baseline.
set -euo pipefail

required_xcode="${OPENCODE_XCODE_VERSION:-27.2}"
required_swift="${OPENCODE_SWIFT_VERSION:-6.4}"
required_sdk="${OPENCODE_IOS_SDK_VERSION:-27.2}"

developer_dir="$(xcode-select -p)"
xcode_version="$(xcodebuild -version | sed -n '1s/^Xcode //p')"
swift_version="$(swift --version 2>/dev/null | sed -n '1s/.*Apple Swift version \([0-9.]*\).*/\1/p')"
sdk_version="$(xcrun --sdk iphonesimulator --show-sdk-version)"

status=0

printf '%-22s %s\n' "developer directory" "$developer_dir"
printf '%-22s %s\n' "Xcode" "$xcode_version"
printf '%-22s %s\n' "Swift" "$swift_version"
printf '%-22s %s\n' "iOS simulator SDK" "$sdk_version"

check() {
  local label="$1" found="$2" required="$3"
  if [[ "$found" != "$required"* ]]; then
    printf 'error: %s %s does not match the required %s\n' "$label" "$found" "$required" >&2
    status=1
  fi
}

check Xcode "$xcode_version" "$required_xcode"
check Swift "$swift_version" "$required_swift"
check "iOS simulator SDK" "$sdk_version" "$required_sdk"

if [[ $status -ne 0 ]]; then
  cat >&2 <<'MESSAGE'

This project targets Xcode 27.2 with its Swift 6.4 compiler and the iOS 27.2 SDK.
Install that toolchain or select it with DEVELOPER_DIR; do not substitute another one.
MESSAGE
fi

exit $status
