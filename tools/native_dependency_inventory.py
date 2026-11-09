"""Inventory declarations in cached Android POMs for a resolved Gradle report.

Run after: android/gradlew :app:dependencies --configuration releaseRuntimeClasspath
Pass the captured report as the only argument. No package-cache paths are emitted.
"""
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

def main():
    if len(sys.argv) != 2:
        raise SystemExit("Usage: python tools/native_dependency_inventory.py PATH_TO_GRADLE_REPORT")
    report = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
    if "BUILD SUCCESSFUL" not in report or "FAILED" in report:
        raise SystemExit("A successful resolved Gradle dependency report is required.")
    coordinates = set()
    for line in report.splitlines():
        match = re.search(r"(?:\+---|\\---)\s+([\w.-]+):([\w.-]+):([^\s]+)", line)
        if not match:
            continue
        group, artifact, version = match.groups()
        selected = re.search(r" -> ([^\s]+)", line)
        if selected:
            resolved = selected.group(1).split(":")
            if len(resolved) == 3:
                group, artifact, version = resolved
            else:
                version = selected.group(1)
        coordinates.add((group, artifact, version))
    if not coordinates:
        raise SystemExit("No resolved dependency coordinates found.")
    rows = []
    for group, artifact, version in sorted(coordinates):
        cache = Path.home() / ".gradle/caches/modules-2/files-2.1" / group / artifact / version
        declarations = set()
        for pom in cache.glob("*/*.pom"):
            root = ET.fromstring(pom.read_bytes())
            for node in root.findall(".//{*}licenses/{*}license"):
                name = node.findtext("{*}name", default="Unspecified")
                declarations.add(name.replace("|", "/").replace("\n", " "))
        rows.append((f"{group}:{artifact}", version, "; ".join(sorted(declarations)) or "Not declared in cached POM; review upstream notices"))
    text = ["# Android native dependency inventory", "", "[Main index](../../README.md)", "",
            "Resolved from the supplied successful releaseRuntimeClasspath report; record the source checkpoint separately. These are declared cached POM license names, not a completed license-compliance determination. Gradle plugin/build-tool dependencies are outside this runtime list.",
            "", "Flutter/Dart notices are in [THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md). Coordinates with missing declarations require upstream review. Native notices and binary provenance must be reviewed before each binary release. iOS framework dependency licensing is not inventoried here; successful native compilation does not establish notice completeness.",
            "", "| Coordinate | Selected version | Cached POM license declaration |", "| --- | --- | --- |"]
    text += ["| " + " | ".join(row) + " |" for row in rows]
    text += ["", "Regenerate using tools/native_dependency_inventory.py with a successful releaseRuntimeClasspath report. Keep raw reports outside Git if they contain local paths.", ""]
    Path(__file__).resolve().parents[1].joinpath("docs/development/native-dependencies.md").write_text("\n".join(text), encoding="utf-8")
    print(f"Inventoried {len(rows)} resolved Android runtime coordinates; {sum('Not declared' in row[2] for row in rows)} need license-declaration review.")

if __name__ == "__main__":
    main()
