"""Select an installed, available iOS runtime matching the selected Xcode SDK.

Reads xcrun simctl list runtimes --json from stdin. Never downloads runtimes.
"""
import json
import re
import sys


def select_runtime(data, sdk):
    match = re.fullmatch(r"(\d+)\.(\d+)(?:\.\d+)?", sdk.strip())
    if not match:
        raise ValueError("Unexpected simulator SDK version")
    prefix = match.group(1) + "." + match.group(2)
    candidates = [
        item for item in data.get("runtimes", [])
        if item.get("isAvailable") is True
        and item.get("identifier", "").startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
        and (item.get("version") == prefix or item.get("version", "").startswith(prefix + "."))
    ]
    if not candidates:
        raise ValueError("No installed available iOS runtime matches the selected SDK; do not download automatically")
    return sorted(candidates, key=lambda item: item["version"])[-1]["identifier"]


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2:
            raise ValueError("One selected simulator SDK version is required")
        print(select_runtime(json.load(sys.stdin), sys.argv[1]))
    except (ValueError, KeyError, TypeError):
        print("No safe matching installed simulator runtime; review toolchain/runtime inventory.", file=sys.stderr)
        sys.exit(1)
