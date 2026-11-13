#!/usr/bin/env python3
"""Boot and wait for the exact simulator used by XCTest; print only its UDID."""
import json
import re
import subprocess
import sys


def select_device(data, name="iPhone 18 Pro"):
    candidates = []
    for runtime, devices in data["devices"].items():
        if ".iOS-" not in runtime:
            continue
        version = tuple(map(int, re.findall(r"\d+", runtime.rsplit(".iOS-", 1)[1])))
        for device in devices:
            if device["name"] == name and device.get("isAvailable", True):
                candidates.append((version, device))
    if not candidates:
        raise RuntimeError(f"No available {name} simulator")
    return max(candidates, key=lambda item: item[0])[1]


def main():
    data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"]))
    device = select_device(data)
    udid = device["udid"]
    if device["state"] != "Booted":
        subprocess.run(["xcrun", "simctl", "boot", udid], check=True, stdout=sys.stderr)
    # xcodebuild may otherwise race the freshly restarted CoreSimulator and
    # fail its first app launch before it has a process ID.
    subprocess.run(["xcrun", "simctl", "bootstatus", udid, "-b"], check=True, stdout=sys.stderr)
    print(udid)


if __name__ == "__main__":
    main()
