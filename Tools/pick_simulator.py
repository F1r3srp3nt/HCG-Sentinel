#!/usr/bin/env python3
"""Prints SIMULATOR_UDID=<udid> for an available simulator whose name starts with the given prefix.

The simulator runtime is chosen to match the selected Xcode's simulator SDK (same major.minor, else the newest
runtime of the same major version, else the newest of all). Pairing an Xcode with a newer runtime than its SDK
has stalled `simctl launch` on hosted runners.

  python3 Tools/pick_simulator.py iPhone
"""
import json
import subprocess
import sys


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def version(runtime):  # "…SimRuntime.iOS-26-2" -> (26, 2)
    return tuple(int(part) for part in runtime.rsplit("iOS-", 1)[-1].split("-") if part.isdigit())


def main():
    prefix = sys.argv[1] if len(sys.argv) > 1 else "iPhone"
    sdk = tuple(int(part) for part in run("xcrun", "--sdk", "iphonesimulator", "--show-sdk-version").strip().split(".")[:2])
    runtimes = json.loads(run("xcrun", "simctl", "list", "devices", "available", "-j"))["devices"]
    candidates = [r for r in runtimes if "iOS-" in r and any(d["name"].startswith(prefix) for d in runtimes[r])]
    if not candidates:
        sys.exit(f"No available {prefix} simulator was found.")
    # Exact SDK match first, then same major (newest first), then anything (newest first).
    ordered = sorted(candidates, key=lambda r: (version(r)[:2] == sdk, version(r)[:1] == sdk[:1], version(r)), reverse=True)
    chosen = ordered[0]
    device = next(d for d in runtimes[chosen] if d["name"].startswith(prefix))
    print(f"Simulator SDK {'.'.join(map(str, sdk))}; using {device['name']} on iOS {'.'.join(map(str, version(chosen)))}", file=sys.stderr)
    print(f"SIMULATOR_UDID={device['udid']}")


if __name__ == "__main__":
    main()
