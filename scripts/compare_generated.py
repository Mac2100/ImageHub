#!/usr/bin/env python3
"""Proves the macOS and Windows apps generate the same media.

The README promises that a drive built on Windows is interchangeable with one built
on a Mac. That promise lives or dies on three generated files, and the only way to
know is to generate them on both platforms from the same template and compare:

    autounattend.xml     what Windows Setup consumes
    configuration.xml    what the Office Deployment Tool consumes
    config.json          what Provision.ps1 consumes

The comparison is semantic, not textual. Both apps escape and order elements
identically, but they indent differently — the Swift builder's string literals have
a couple of quirks, and the C# writer indents properly — and whitespace between
elements means nothing to Setup. So XML is compared as parsed trees (tags,
attributes, and text with surrounding whitespace stripped, comments ignored) and
JSON as parsed objects.

Two config.json keys are excluded, because they are meant to differ: generatedAt is
a timestamp, and generatedBy names the app that wrote it.

Usage:
    compare_generated.py <macos-dir> <windows-dir>
"""

from __future__ import annotations

import argparse
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

IGNORED_CONFIG_KEYS = {"generatedAt", "generatedBy"}


def normalise(element: ET.Element) -> tuple:
    """A comparable shape for an element: tag, attributes, text, children."""
    text = (element.text or "").strip()
    children = [
        normalise(child)
        for child in element
        # Comments come through as a callable tag from ElementTree.
        if isinstance(child.tag, str)
    ]
    return element.tag, dict(sorted(element.attrib.items())), text, children


def describe(element: ET.Element) -> str:
    return element.tag.split("}")[-1]


def diff_xml(left: ET.Element, right: ET.Element, path: str, out: list[str]) -> None:
    if left.tag != right.tag:
        out.append(f"{path}: element is <{describe(left)}> on macOS, <{describe(right)}> on Windows")
        return

    here = f"{path}/{describe(left)}"

    if left.attrib != right.attrib:
        out.append(f"{here}: attributes differ — macOS {dict(sorted(left.attrib.items()))}, "
                   f"Windows {dict(sorted(right.attrib.items()))}")

    left_text = (left.text or "").strip()
    right_text = (right.text or "").strip()
    if left_text != right_text:
        out.append(f"{here}: text differs\n    macOS:   {left_text!r}\n    Windows: {right_text!r}")

    left_children = [child for child in left if isinstance(child.tag, str)]
    right_children = [child for child in right if isinstance(child.tag, str)]
    if len(left_children) != len(right_children):
        out.append(
            f"{here}: {len(left_children)} child element(s) on macOS, "
            f"{len(right_children)} on Windows — "
            f"macOS has {[describe(c) for c in left_children]}, "
            f"Windows has {[describe(c) for c in right_children]}")
        return

    for index, (a, b) in enumerate(zip(left_children, right_children)):
        diff_xml(a, b, f"{here}[{index}]", out)


def compare_xml(name: str, left: Path, right: Path) -> bool:
    try:
        a = ET.parse(left).getroot()
        b = ET.parse(right).getroot()
    except ET.ParseError as error:
        print(f"::error::{name}: couldn't parse — {error}")
        return False

    if normalise(a) == normalise(b):
        print(f"  ok: {name} is identical on both platforms")
        return True

    problems: list[str] = []
    diff_xml(a, b, "", problems)
    if not problems:
        problems.append("the trees differ but no specific difference was located; "
                        "compare the two files by hand")
    print(f"::error::{name} differs between macOS and Windows:")
    for problem in problems[:25]:
        print(f"::error::  {problem}")
    if len(problems) > 25:
        print(f"::error::  …and {len(problems) - 25} more")
    return False


def strip_ignored(value):
    if isinstance(value, dict):
        return {k: strip_ignored(v) for k, v in value.items() if k not in IGNORED_CONFIG_KEYS}
    if isinstance(value, list):
        return [strip_ignored(item) for item in value]
    return value


def diff_json(left, right, path: str, out: list[str]) -> None:
    if type(left) is not type(right) and not (
            isinstance(left, (int, float)) and isinstance(right, (int, float))):
        out.append(f"{path}: {type(left).__name__} on macOS, {type(right).__name__} on Windows")
        return
    if isinstance(left, dict):
        for key in sorted(set(left) | set(right)):
            if key not in left:
                out.append(f"{path}/{key}: missing on macOS (Windows has {right[key]!r})")
            elif key not in right:
                out.append(f"{path}/{key}: missing on Windows (macOS has {left[key]!r})")
            else:
                diff_json(left[key], right[key], f"{path}/{key}", out)
    elif isinstance(left, list):
        if len(left) != len(right):
            out.append(f"{path}: {len(left)} item(s) on macOS, {len(right)} on Windows")
            return
        for index, (a, b) in enumerate(zip(left, right)):
            diff_json(a, b, f"{path}[{index}]", out)
    elif left != right:
        out.append(f"{path}: macOS {left!r}, Windows {right!r}")


def compare_json(name: str, left: Path, right: Path) -> bool:
    try:
        a = strip_ignored(json.loads(left.read_text(encoding="utf-8")))
        b = strip_ignored(json.loads(right.read_text(encoding="utf-8")))
    except json.JSONDecodeError as error:
        print(f"::error::{name}: couldn't parse — {error}")
        return False

    if a == b:
        print(f"  ok: {name} is identical on both platforms "
              f"(ignoring {', '.join(sorted(IGNORED_CONFIG_KEYS))})")
        return True

    problems: list[str] = []
    diff_json(a, b, "", problems)
    print(f"::error::{name} differs between macOS and Windows:")
    for problem in problems[:25]:
        print(f"::error::  {problem}")
    if len(problems) > 25:
        print(f"::error::  …and {len(problems) - 25} more")
    return False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("macos", type=Path, help="directory of artifacts from the macOS build")
    parser.add_argument("windows", type=Path, help="directory of artifacts from the Windows build")
    arguments = parser.parse_args()

    checks = [
        ("autounattend.xml", compare_xml),
        ("office.xml", compare_xml),
        ("config.json", compare_json),
    ]

    missing = False
    for name, _ in checks:
        for directory in (arguments.macos, arguments.windows):
            if not (directory / name).is_file():
                print(f"::error::{directory / name} is missing")
                missing = True
    if missing:
        return 1

    ok = True
    for name, compare in checks:
        if not compare(name, arguments.macos / name, arguments.windows / name):
            ok = False

    if ok:
        print("\nBoth apps generate the same media.")
        return 0
    print("\nThe two apps would produce different media. Fix the generator that drifted:")
    print("  Sources/ImageHub/Services/{AnswerFileBuilder,OfficeConfigBuilder,PayloadBuilder}.swift")
    print("  Windows/App/Services/{AnswerFileBuilder,OfficeConfigBuilder,PayloadBuilder}.cs")
    return 1


if __name__ == "__main__":
    sys.exit(main())
