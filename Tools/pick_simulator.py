#!/usr/bin/env python3
"""Prints SIMULATOR_UDID=<udid> for the newest available simulator whose name starts with the given prefix.

  python3 Tools/pick_simulator.py iPhone
"""
import json
import subprocess
import sys


def main():
    prefix = sys.argv[1] if len(sys.argv) > 1 else "iPhone"
    listing = subprocess.run(["xcrun", "simctl", "list", "devices", "available", "-j"],
                             check=True, capture_output=True, text=True).stdout
    runtimes = json.loads(listing)["devices"]

    def version(runtime):  # "…SimRuntime.iOS-26-2" -> (26, 2)
        return tuple(int(part) for part in runtime.rsplit("iOS-", 1)[-1].split("-") if part.isdigit())

    for runtime in sorted((r for r in runtimes if "iOS-" in r), key=version, reverse=True):
        for device in runtimes[runtime]:
            if device["name"].startswith(prefix):
                print(f"SIMULATOR_UDID={device['udid']}")
                return
    sys.exit(f"No available {prefix} simulator was found.")


if __name__ == "__main__":
    main()
