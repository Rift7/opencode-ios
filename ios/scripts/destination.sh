#!/usr/bin/env bash
# Prints an xcodebuild destination for a simulator that exists on this machine and can run the
# app (runtime at or above the deployment target).
#
#   OPENCODE_DESTINATION      use this destination verbatim
#   OPENCODE_SIM_NAME         require this device name (default: best available iPhone)
#   OPENCODE_SIM_RUNTIME      require this runtime label, e.g. "iOS 27.2" (default: newest)
#   OPENCODE_SIM_MIN_RUNTIME  minimum runtime label (default: iOS 27.2)
set -euo pipefail

if [[ -n "${OPENCODE_DESTINATION:-}" ]]; then
  printf '%s\n' "$OPENCODE_DESTINATION"
  exit 0
fi

python3 - \
  "${OPENCODE_SIM_NAME:-}" \
  "${OPENCODE_SIM_RUNTIME:-}" \
  "${OPENCODE_SIM_MIN_RUNTIME:-iOS 27.2}" <<'PY'
import json
import re
import subprocess
import sys

wanted_name, wanted_runtime, min_runtime = sys.argv[1], sys.argv[2], sys.argv[3]

devices = json.loads(
    subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"])
)["devices"]

def runtime_label(identifier: str) -> str:
    tail = identifier.split("SimRuntime.")[-1]
    match = re.match(r"iOS-(\d+)-(\d+)", tail)
    return f"iOS {match.group(1)}.{match.group(2)}" if match else tail

def version(label: str):
    return tuple(int(part) for part in re.findall(r"\d+", label))

floor = version(min_runtime)

iphones = []
for identifier, entries in devices.items():
    if "SimRuntime.iOS-" not in identifier:
        continue
    label = runtime_label(identifier)
    if version(label) < floor:
        continue
    if wanted_runtime and label != wanted_runtime:
        continue
    for entry in entries:
        name = entry.get("name", "")
        if not entry.get("isAvailable", True) or not name.startswith("iPhone"):
            continue
        iphones.append((label, name, entry["udid"]))

if not iphones:
    sys.exit(
        "error: no available iPhone simulator on "
        f"{wanted_runtime or min_runtime} or newer.\n"
        "Create one in Xcode, or run:\n"
        "  xcrun simctl create 'iPhone 18 Pro Max' com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro-Max"
    )

if wanted_name:
    matches = [candidate for candidate in iphones if candidate[1] == wanted_name]
    if not matches:
        available = sorted({candidate[1] for candidate in iphones})
        sys.exit(
            f"error: no available simulator named {wanted_name!r} at or above {min_runtime}.\n"
            f"available: {', '.join(available)}\n"
            "Set OPENCODE_SIM_NAME to one of them, or unset it to pick automatically."
        )
    iphones = matches

def preference(name: str) -> int:
    if "Pro Max" in name:
        return 0
    if name.endswith("Pro"):
        return 1
    if "e" in name:
        return 3
    return 2

iphones.sort(key=lambda candidate: (version(candidate[0]), -preference(candidate[1])), reverse=True)
label, name, udid = iphones[0]

print(f"platform=iOS Simulator,id={udid}")
print(f"# {name} on {label} ({udid})", file=sys.stderr)
PY
