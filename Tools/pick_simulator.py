#!/usr/bin/env python3
"""Prints SIMULATOR_UDID=<udid> for a simulator matching the selected Xcode's simulator SDK.

  python3 Tools/pick_simulator.py iPhone     newest-runtime iPhone
  python3 Tools/pick_simulator.py iPad       newest-runtime iPad
  python3 Tools/pick_simulator.py small      a 375-point-wide iPhone (iPhone SE), created if needed

The runtime is chosen to match the selected Xcode's simulator SDK (same major.minor, else same major, else
newest). Pairing an Xcode with a newer runtime than its SDK has stalled `simctl launch` on hosted runners.
"""
import json
import subprocess
import sys

SMALL_TYPES = ["com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation",
               "com.apple.CoreSimulator.SimDeviceType.iPhone-SE--2nd-generation-"]


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def version(identifier):  # "…SimRuntime.iOS-26-2" -> (26, 2)
    return tuple(int(part) for part in identifier.rsplit("iOS-", 1)[-1].split("-") if part.isdigit())


def main():
    prefix = sys.argv[1] if len(sys.argv) > 1 else "iPhone"
    sdk = tuple(int(part) for part in run("xcrun", "--sdk", "iphonesimulator", "--show-sdk-version").strip().split(".")[:2])
    rank = lambda r: (version(r)[:2] == sdk, version(r)[:1] == sdk[:1], version(r))

    if prefix == "small":
        runtimes = [r["identifier"] for r in json.loads(run("xcrun", "simctl", "list", "runtimes", "-j"))["runtimes"]
                    if r.get("isAvailable") and "iOS" in r["identifier"]]
        for runtime in sorted(runtimes, key=rank, reverse=True):
            for device_type in SMALL_TYPES:
                created = subprocess.run(["xcrun", "simctl", "create", "Sentinel small iPhone", device_type, runtime],
                                         capture_output=True, text=True)
                if created.returncode == 0:
                    print(f"Created {device_type} on {runtime}", file=sys.stderr)
                    print(f"SIMULATOR_UDID={created.stdout.strip()}")
                    return
        print("No 375-point iPhone type available; falling back to an iPhone", file=sys.stderr)
        prefix = "iPhone"

    devices = json.loads(run("xcrun", "simctl", "list", "devices", "available", "-j"))["devices"]
    candidates = [r for r in devices if "iOS-" in r and any(d["name"].startswith(prefix) for d in devices[r])]
    if not candidates:
        sys.exit(f"No available {prefix} simulator was found.")
    chosen = sorted(candidates, key=rank, reverse=True)[0]
    device = next(d for d in devices[chosen] if d["name"].startswith(prefix))
    print(f"Simulator SDK {'.'.join(map(str, sdk))}; using {device['name']} on iOS {'.'.join(map(str, version(chosen)))}", file=sys.stderr)
    print(f"SIMULATOR_UDID={device['udid']}")


if __name__ == "__main__":
    main()
