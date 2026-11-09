"""Render approved static website files locally; does not publish or change privacy exceptions."""
from pathlib import Path
import hashlib
import html
import re

from privacy_check import EMAIL, inspect

ROOT = Path(__file__).resolve().parents[1]
CONTACT_HASH = "c514aca59a13578c5ee5fa0c93a6661f7f39225b698e80550293f05b25ed2987"

def render(template, contact_record):
    values = {}
    for marker, label in (("PUBLIC_CONTACT_EMAIL", "Email"), ("PUBLIC_PROVIDER_NAME", "Provider name")):
        match = re.search(r"^" + label + r": \*\*(.+?)\*\*$", contact_record, re.M)
        if not match:
            raise ValueError("Missing approved public contact field")
        values[marker] = match.group(1)
    if hashlib.sha256(values["PUBLIC_CONTACT_EMAIL"].encode()).hexdigest() != CONTACT_HASH:
        raise ValueError("Unapproved contact address")
    if values["PUBLIC_PROVIDER_NAME"] != "Carlos Diaz":
        raise ValueError("Unapproved provider name")
    result = template
    for marker, value in values.items():
        result = result.replace("{{" + marker + "}}", html.escape(value, quote=True))
    if "{{" in result or "}}" in result:
        raise ValueError("Unresolved template marker")
    return result

def validate_public_content(content):
    data = content.encode("utf-8")
    addresses = list(EMAIL.finditer(data))
    if any(hashlib.sha256(match.group()).hexdigest() != CONTACT_HASH for match in addresses):
        raise ValueError("Unapproved email in public-page output")
    findings = inspect(data, check_path=False)
    # Website-only reviewed contact handling; never change the APK/source classifier.
    if addresses:
        findings.discard("email-address-review")
    if findings:
        raise ValueError("Unsafe public-page content: " + ", ".join(sorted(findings)))


def public_files(contact_record):
    files = {
        name: render((ROOT / "site/templates" / name).read_text(encoding="utf-8"), contact_record)
        for name in ("index.html", "privacy.html")
    }
    for name in ("styles.css", "_headers"):
        files[name] = (ROOT / "site/assets" / name).read_text(encoding="utf-8")
    for content in files.values():
        validate_public_content(content)
    return files


def linked(path):
    return path.is_symlink() or (hasattr(path, "is_junction") and path.is_junction())


def main():
    contact = (ROOT / "docs/security/public-contacts.md").read_text(encoding="utf-8")
    files = public_files(contact)
    output = ROOT / "build/public-pages"
    if linked(ROOT / "build") or linked(output):
        raise ValueError("Refusing linked output directory")
    output.mkdir(parents=True, exist_ok=True)
    if any(p.name not in files or linked(p) or not p.is_file() for p in output.iterdir()):
        raise ValueError("Unexpected output entry; review manually")
    for name, content in files.items():
        target = output / name
        if target.exists() and target.stat().st_nlink > 1:
            raise ValueError("Refusing hard-linked output file")
    for name, content in files.items():
        (output / name).write_text(content, encoding="utf-8")
    print("Rendered four upload-ready website files in build/public-pages; not uploaded or published.")


if __name__ == "__main__":
    main()
