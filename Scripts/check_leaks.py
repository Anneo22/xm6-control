#!/usr/bin/env python3
"""Reject private home paths and email addresses in tracked text files.

Only example domains and GitHub noreply addresses are allowed. This complements
secret scanning; it is not a replacement for a credential scanner.
"""
import re
import subprocess
import sys
from pathlib import Path

HOME = re.compile(r"/(?:Users|home)/[A-Za-z0-9_.-]+/")
EMAIL = re.compile(r"[A-Za-z0-9_.+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})")
ALLOWED = {"example.com", "example.org", "example.net", "users.noreply.github.com"}


def main():
    root = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip())
    files = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).decode().split("\0")
    failures = []
    for name in filter(None, files):
        try:
            content = (root / name).read_bytes()
            if b"\0" in content:
                continue
            text = content.decode("utf-8")
        except (UnicodeDecodeError, FileNotFoundError):
            continue
        for line, value in enumerate(text.splitlines(), 1):
            if HOME.search(value) or any(m.group(1).lower() not in ALLOWED for m in EMAIL.finditer(value)):
                failures.append(f"{name}:{line}")
    if failures:
        print("Private data patterns found in: " + ", ".join(failures), file=sys.stderr)
        return 1
    print("Tracked text leak check passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
