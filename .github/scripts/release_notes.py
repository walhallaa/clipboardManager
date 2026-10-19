#!/usr/bin/env python3
"""Loads and checks the App Store "What's New" text kept in fastlane/release_notes/.

default.txt is used for every language. <locale>.txt (en-US.txt, tr.txt) overrides it for that language.

usage: release_notes.py check [directory]
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

MAX_LENGTH = 4000
DEFAULT_DIRECTORY = Path(__file__).resolve().parents[2] / "fastlane" / "release_notes"


def problems(text: str) -> list[str]:
    """Store copy rules for this app. Each entry reads as the end of "<file> ..."."""
    text = text.strip()
    if not text:
        return ["is empty"]
    found = []
    if re.search(r"todo", text, re.IGNORECASE):
        found.append("still has a TODO in it")
    if len(text) > MAX_LENGTH:
        found.append(f"is {len(text)} characters, over the {MAX_LENGTH} App Store Connect allows")
    if re.search("[–—]", text):
        found.append("has an en or em dash (use a colon, comma, full stop or the word to)")
    if "⌘" in text:
        found.append("has the command key glyph, which App Store Connect rejects (write Command-K)")
    if re.search(r"\bfree\b", text, re.IGNORECASE):
        found.append('says "free", and the app must never be marketed as free')
    return found


def load(directory: str | Path = DEFAULT_DIRECTORY) -> dict[str, str]:
    """Maps language to text, always including "default". Exits with the reasons if anything is wrong."""
    directory = Path(directory)
    notes = {path.stem: path.read_text(encoding="utf-8").strip() for path in sorted(directory.glob("*.txt"))}
    if "default" not in notes:
        sys.exit(f"{directory}/default.txt is missing")
    errors = [f"{name}.txt {issue}" for name, text in notes.items() for issue in problems(text)]
    if errors:
        sys.exit("Release notes need fixing:\n  " + "\n  ".join(errors))
    return notes


def main() -> None:
    if len(sys.argv) < 2 or sys.argv[1] != "check":
        sys.exit(__doc__)
    notes = load(sys.argv[2] if len(sys.argv) > 2 else DEFAULT_DIRECTORY)
    print(f"Release notes OK ({', '.join(notes)})")


if __name__ == "__main__":
    main()
