#!/usr/bin/env python3
"""Checks every XML file in the repository is well-formed.

MSBuild and WPF find these eventually, but only on a Windows runner, and only
after .NET has been installed and a restore attempted. Worse, a malformed .csproj
fails at *project load*, before a single line of C# is compiled, so a five-minute
job reports one XML complaint and nothing else -- then does it again for the next
one. Checking here means a whole run's worth of them surface at once, in seconds,
on Linux.

The rule that actually catches people is that an XML comment may not contain a
double hyphen. Prose about command-line switches is full of them, and a comment is
exactly where such prose goes, so the failure lands in the one place nobody thinks
of as code.
"""

from __future__ import annotations

import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

SUFFIXES = {
    ".csproj", ".xaml", ".manifest", ".props", ".targets",
    ".resx", ".plist", ".xml", ".config",
}

# Not ours to validate, and full of files that are XML only by extension.
SKIPPED = {".git", "bin", "obj", "dist", "vendor", ".build"}


def candidates() -> list[Path]:
    found = []
    for path in sorted(ROOT.rglob("*")):
        if path.suffix.lower() not in SUFFIXES or not path.is_file():
            continue
        if any(part in SKIPPED for part in path.relative_to(ROOT).parts):
            continue
        found.append(path)
    return found


def main() -> int:
    files = candidates()
    if not files:
        print("::error::no XML files found; this check is not looking where it thinks it is")
        return 1

    problems = 0
    for path in files:
        relative = path.relative_to(ROOT)
        try:
            ET.parse(path)
        except ET.ParseError as error:
            line, column = error.position
            print(f"::error file={relative},line={line},col={column}::{error}")
            if "not well-formed" in str(error):
                print("::error::  (a '--' inside an XML comment is the usual cause)")
            problems += 1

    if problems:
        return 1
    print(f"all {len(files)} XML files are well-formed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
