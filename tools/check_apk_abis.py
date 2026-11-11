"""Check that an Android APK packages native libraries for arm64-v8a only.

Usage: python tools/check_apk_abis.py path/to/app-release.apk

Public release APKs ship 64-bit ARM only (see docs/releasing/android.md).
Exit code 0 when every lib/<abi>/ entry is arm64-v8a and at least one exists;
1 otherwise. Prints ABI names and library file names only.
"""
import sys
import zipfile

ALLOWED_ABI = "arm64-v8a"


def native_libraries(apk_path):
    with zipfile.ZipFile(apk_path) as apk:
        return sorted(
            name for name in apk.namelist()
            if name.startswith("lib/") and not name.endswith("/") and name.count("/") >= 2
        )


def problems(libraries):
    found = []
    if not libraries:
        found.append("no native libraries under lib/")
    for name in libraries:
        abi = name.split("/")[1]
        if abi != ALLOWED_ABI:
            found.append("unexpected ABI " + abi + ": " + name.rsplit("/", 1)[-1])
    return found


def main(argv):
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[2])
        return 2
    libraries = native_libraries(argv[1])
    for name in libraries:
        print(name)
    issues = problems(libraries)
    abis = sorted({name.split("/")[1] for name in libraries})
    print("ABIs: " + (", ".join(abis) if abis else "none"))
    for issue in issues:
        print("FAIL: " + issue)
    if not issues:
        print("OK: arm64-v8a only.")
    return 1 if issues else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
