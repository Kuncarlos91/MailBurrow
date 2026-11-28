"""Check public PR text without printing matched text or using network access."""
import argparse
import json
from pathlib import Path
import re
import sys

from privacy_check import inspect


MAX_INPUT_BYTES = 2 * 1024 * 1024
RULES = (
    ("private-repository-reference", re.compile(
        r"\b(?:https?://(?:(?:www\.)?github\.com/|api\.github\.com/repos/))?"
        r"[\w.-]+/mailshelf(?![\w.-])", re.I)),
    ("private-run-reference", re.compile(
        r"\b(?:mailshelf|private|internal)\s+(?:actions?\s+)?"
        r"(?:workflow\s+)?(?:run|pr|pull\s+request)\s*#?\s*\d+\b", re.I)),
    ("distribution-approval", re.compile(
        r"\b(?:(?:owner|maintainer)[ -]+(?:has\s+)?(?:approved|authori[sz]ed)"
        r"|(?:approved|authori[sz]ed)\s+by\s+(?:the\s+)?(?:owner|maintainer))\b"
        r"[^\n]{0,160}\b(?:testflight|signing|workflow|macos\s+run)\b", re.I)),
    ("pending-distribution-status", re.compile(
        r"\bbuild\s+\d+\s+(?:(?:was|is)\s+)?not\s+consumed\b", re.I)),
)


def findings(title, body):
    """Return fixed labels only; legacy product names and public CI are allowed."""
    result = set()
    for value in (title, body):
        result.update(inspect(value.encode("utf-8"), check_path=False))
        for label, pattern in RULES:
            if pattern.search(value):
                result.add(label)
    return result


def read_input(path):
    with Path(path).open("rb") as stream:
        data = stream.read(MAX_INPUT_BYTES + 1)
    if len(data) > MAX_INPUT_BYTES:
        raise ValueError("oversized input")
    return data.decode("utf-8")


def event_text(value):
    event = json.loads(value)
    pr = event.get("pull_request") if isinstance(event, dict) else None
    if not isinstance(pr, dict):
        raise ValueError("missing pull request")
    title, body = pr.get("title"), pr.get("body")
    if not isinstance(title, str) or not (body is None or isinstance(body, str)):
        raise ValueError("invalid pull request text")
    return title, body or ""


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--event", help="GitHub pull_request event JSON file")
    source.add_argument("--body-file", help="Local PR body to check before posting")
    parser.add_argument("--title", default="", help="Title for --body-file")
    args = parser.parse_args(argv)
    try:
        value = read_input(args.event or args.body_file)
        if args.event:
            if args.title:
                raise ValueError("title belongs with body file")
            title, body = event_text(value)
        else:
            title, body = args.title, value
    except (OSError, UnicodeError, ValueError):
        print("PR text input is unreadable, oversized or invalid; values withheld.", file=sys.stderr)
        return 2
    labels = sorted(findings(title, body))
    if labels:
        print("PR text needs review: " + ", ".join(labels), file=sys.stderr)
        print("Keep private run references, distribution approvals and internal release records out of public PR text.", file=sys.stderr)
        return 1
    print("PR title and body passed the bounded privacy check.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
