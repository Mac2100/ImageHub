#!/usr/bin/env python3
"""Keeps the three copies of the winget app catalog in step.

The catalog lives in Swift, is mirrored in C# for the Windows app, and is embedded
in Windows/Check-CatalogIDs.ps1 so that checker can run standalone on a Windows
machine. Three copies means they can drift, and a drifted copy is worse than none:
it would offer a package the others dropped, or miss one they ship.

Nothing here needs a compiler, so it runs on every push before either app is built.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

SWIFT = ROOT / "Sources/ImageHub/Services/AppCatalog.swift"
CSHARP = ROOT / "Windows/App/Services/AppCatalog.cs"
POWERSHELL = ROOT / "Windows/Check-CatalogIDs.ps1"


def swift_ids() -> list[str]:
    text = SWIFT.read_text(encoding="utf-8")
    return re.findall(r'Entry\(id: "([^"]+)"', text)


def csharp_ids() -> list[str]:
    text = CSHARP.read_text(encoding="utf-8")
    # The entries are `new("Id", "Name", "Category"[, "note"])` inside the Entries
    # array; the constructor's first argument is the package ID.
    start = text.index("public static readonly Entry[] Entries")
    end = text.index("public static IReadOnlyList<string> Categories", start)
    return re.findall(r'new\("([^"]+)"', text[start:end])


def powershell_ids() -> list[str]:
    text = POWERSHELL.read_text(encoding="utf-8-sig")
    start = text.index("$ids = @(")
    end = text.index(")", start)
    return re.findall(r"'([^']+)'", text[start:end])


def compare(name: str, reference: list[str], other: list[str]) -> list[str]:
    problems = []
    missing = [package for package in reference if package not in other]
    extra = [package for package in other if package not in reference]
    if missing:
        problems.append(f"{name} is missing {missing}")
    if extra:
        problems.append(f"{name} lists IDs no longer in the Swift catalog: {extra}")
    return problems


def main() -> int:
    swift = swift_ids()
    if not swift:
        print(f"::error::no catalog entries found in {SWIFT.relative_to(ROOT)}")
        return 1

    duplicates = [package for package in set(swift) if swift.count(package) > 1]
    problems = []
    if duplicates:
        problems.append(f"the Swift catalog lists {duplicates} more than once")

    problems += compare(str(CSHARP.relative_to(ROOT)), swift, csharp_ids())
    problems += compare(str(POWERSHELL.relative_to(ROOT)), swift, powershell_ids())

    for problem in problems:
        print(f"::error::{problem}")
    if problems:
        return 1

    print(f"all three catalogs cover the same {len(swift)} package IDs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
