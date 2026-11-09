"""Generate notices from the already-installed, locked dependency cache.

No downloads, local paths, secrets, or app license selection are included.
Run after flutter pub get --enforce-lockfile.
"""
import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlparse

ROOT = Path(__file__).resolve().parents[1]

def main(argv=()):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Verify inventory and retained notices without writing files")
    args = parser.parse_args(argv)
    config = json.loads((ROOT / ".dart_tool/package_config.json").read_text(encoding="utf-8"))
    lock = (ROOT / "pubspec.lock").read_text(encoding="utf-8")
    versions = {}
    kinds = {}
    for match in re.finditer(r"^  ([a-z0-9_]+):\n(.*?)(?=^  [a-z0-9_]+:|^sdks:|\Z)", lock, re.M | re.S):
        name, block = match.groups()
        version = re.search(r'^    version: "(.*?)"', block, re.M)
        kind = re.search(r'^    dependency: (.*)', block, re.M)
        versions[name] = version.group(1) if version else "SDK"
        kinds[name] = kind.group(1).strip('"') if kind else "SDK"
    rows = []
    texts = {}
    for package in sorted(config["packages"], key=lambda p: p["name"]):
        name = package["name"]
        if name == "mailburrow":
            continue
        uri = urlparse(package["rootUri"])
        value = unquote(uri.path)
        if re.match(r"^/[A-Za-z]:", value):
            value = value[1:]
        folder = Path(value) if uri.scheme else (ROOT / ".dart_tool" / value).resolve()
        candidates = [folder] + list(folder.parents)[:3] if uri.scheme else [folder]
        source = None
        for candidate in candidates:
            source = next((p for p in candidate.iterdir() if p.is_file() and p.name.lower() in ("license", "license.md", "license.txt", "copying")), None)
            if source:
                break
        if source is None:
            raise RuntimeError("Missing license text for package " + name)
        text = "\n".join(line.rstrip() for line in source.read_text(encoding="utf-8").splitlines()).strip() + "\n"
        digest = hashlib.sha256(text.encode()).hexdigest()
        texts.setdefault(digest, {"text": text, "packages": []})["packages"].append(name)
        lower = text.lower()
        family = ("SDK multi-license bundle" if name == "sky_engine"
                  else "Apache text" if "apache license" in lower
                  else "MIT text" if "permission is hereby granted" in lower
                  else "BSD-style text" if "redistribution and use in source and binary forms" in lower
                  else "Review full text")
        rows.append((name, versions.get(name, "Flutter SDK 3.47.8"), kinds.get(name, "SDK"), family, digest))
    inventory = ["# Dependency license inventory", "", "[Main index](../../README.md)", "",
                 "Generated from the installed packages and committed lockfile. Includes direct, transitive, development, and SDK packages; not every listed package ships on Android or iOS.",
                 "", "License-family labels are text classifications, not legal conclusions. Full unmodified license wording is retained in [THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md); inventory hashes refer to normalized license text, not package archives.",
                 "", "MailBurrow's own code is licensed under the MIT License (see [LICENSE](../../LICENSE)). Android runtime license declarations are inventoried in [native-dependencies.md](native-dependencies.md).",
                 "", "| Package | Version | Dependency role | Observed text | License SHA-256 |",
                 "| --- | --- | --- | --- | --- |"]
    inventory += ["| " + " | ".join(row) + " |" for row in rows]
    inventory += ["", "Regenerate with python tools/dependency_notices.py after flutter pub get --enforce-lockfile. No package-cache paths or account identifiers are included.", ""]
    notices = ["# Third-party license texts", "", "Generated from locked Dart/Flutter dependencies. Copyright holder names and addresses below belong to upstream license notices and must be retained. This file does not license MailShelf's original code.", ""]
    for digest, item in texts.items():
        notices += ["## " + ", ".join(item["packages"]), "", "Normalized license SHA-256: " + digest, "", item["text"], ""]
    if args.check:
        existing = (ROOT / "docs/development/dependencies.md").read_text(encoding="utf-8")
        existing_rows = [tuple(part.strip() for part in line.strip("|").split("|"))
                         for line in existing.splitlines() if re.match(r"^\| [a-z0-9_]+ \|", line)]
        expected_notices = "\n".join(notices).rstrip() + "\n"
        if existing_rows != rows:
            raise SystemExit("Dependency inventory differs from installed locked packages; no files changed")
        if (ROOT / "THIRD_PARTY_NOTICES.md").read_text(encoding="utf-8") != expected_notices:
            raise SystemExit("Retained notice texts differ; review provenance without overwriting the root file")
        print(f"Verified {len(rows)} package rows and {len(texts)} distinct retained license texts; no files changed.")
        return
    (ROOT / "docs/development/dependencies.md").write_text("\n".join(inventory), encoding="utf-8")
    (ROOT / "THIRD_PARTY_NOTICES.md").write_text("\n".join(notices).rstrip() + "\n", encoding="utf-8")
    print(f"Inventoried {len(rows)} packages; retained {len(texts)} distinct license texts.")

if __name__ == "__main__":
    main(sys.argv[1:])
