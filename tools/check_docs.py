"""Check repository-local Markdown links without fetching external services."""
from pathlib import Path
from urllib.parse import unquote, urlsplit
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
LINK = re.compile(r"!?\[[^\]\n]*\]\((<[^>]+>|[^\s)]+)(?:\s+[^\n)]*)?\)")


def prose_lines(text):
    fence = None
    for number, line in enumerate(text.splitlines(), 1):
        stripped = line.lstrip()
        marker = re.match(r"(`{3,}|~{3,})", stripped)
        if marker:
            value = marker.group(1)
            if fence is None:
                fence = value
            elif value[0] == fence[0] and len(value) >= len(fence):
                fence = None
            continue
        if fence is None:
            yield number, line


def heading_ids(text):
    counts = {}
    result = set()
    for _, line in prose_lines(text):
        match = re.match(r"^#{1,6} +(.+?) *#* *$", line)
        if not match:
            continue
        title = re.sub(r"\[([^]]+)\]\([^)]*\)", r"\1", match.group(1))
        slug = re.sub(r"[^\w -]", "", title.lower()).replace(" ", "-")
        count = counts.get(slug, 0)
        counts[slug] = count + 1
        result.add(slug if count == 0 else f"{slug}-{count}")
    return result


def check_documents(root):
    root = Path(root).resolve()
    # Notice bodies are unmodified third-party texts, not authored repo guides.
    documents = sorted(p for p in root.glob("*.md") if p.name != "THIRD_PARTY_NOTICES.md")
    documents += sorted((root / "docs").rglob("*.md"))
    errors = []
    checked = 0
    for document in documents:
        try:
            text = document.read_text(encoding="utf-8")
        except UnicodeError:
            errors.append((document.relative_to(root).as_posix(), 1, "not UTF-8"))
            continue
        for number, line in prose_lines(text):
            for match in LINK.finditer(line):
                value = match.group(1).strip("<>")
                parsed = urlsplit(value)
                if parsed.scheme or parsed.netloc:
                    continue
                checked += 1
                target = (document.parent / unquote(parsed.path)).resolve() if parsed.path else document
                reason = None
                if not target.is_relative_to(root):
                    reason = "destination escapes repository"
                elif not target.exists():
                    reason = "missing local destination"
                elif parsed.fragment and target.suffix.lower() == ".md":
                    if unquote(parsed.fragment) not in heading_ids(target.read_text(encoding="utf-8")):
                        reason = "missing local heading"
                if reason:
                    # Do not print link values or document contents.
                    errors.append((document.relative_to(root).as_posix(), number, reason))
    return checked, errors


def main():
    checked, errors = check_documents(ROOT)
    for name, line, reason in errors:
        print(f"{name}:{line}: {reason}")
    print(f"Checked {checked} local documentation links; {len(errors)} error(s). External links were not fetched.")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
