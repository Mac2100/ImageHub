#!/usr/bin/env python3
"""Finds types used in the Windows app without the using directive that supplies them.

CS0246 -- "the type or namespace name could not be found" -- is the cheapest possible
mistake and, without a Windows toolchain, one of the most expensive to find: it needs
a full .NET install and a compile on a Windows runner to report, and a single missing
`using` produces a dozen of them at once.

The app's own types are all declared in this repository, so the information needed to
catch this is here too. This builds a map of every top-level type to the namespace
that declares it, then checks each file can actually see the types it names -- either
because it shares their namespace, or because it says so in a using directive.

This is a linter, not a compiler. It only knows about types declared in the app, so
it says nothing about the framework, and it deliberately does not try to resolve
nested types (they are reached through their container). It strips comments, strings
and character literals first, so prose that happens to mention a type name is not
mistaken for code.
"""

from __future__ import annotations

import re
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "Windows/App"

DECLARATION = re.compile(r"\b(?:class|struct|interface|enum|record)\s+([A-Za-z_]\w*)")
NAMESPACE = re.compile(r"^\s*namespace\s+([\w.]+)\s*[;{]", re.MULTILINE)
USING = re.compile(r"^\s*using\s+(?:static\s+)?([\w.]+)\s*;", re.MULTILINE)
USING_ALIAS = re.compile(r"^\s*using\s+([A-Za-z_]\w*)\s*=\s*([\w.<>, ]+)\s*;", re.MULTILINE)
WORD = re.compile(r"[A-Za-z_]\w*")

# A member declaration: an access modifier, a return type, then the member's name. This
# exists to stop a member that happens to share a type's name -- AppPaths has a
# property called OfficeDeploymentTool, and there is a service class of that name --
# from being read as a use of the type.
MEMBER = re.compile(
    r"\b(?:public|private|protected|internal)\b(?![^\n]*\b(?:class|struct|interface|enum|record)\b)"
    r"[^\n;=({]*?\b(\w+)\s*(?:=>|[({;=])")


def strip_noise(source: str) -> str:
    """Removes comments and literals, preserving newlines so line numbers survive."""
    out = []
    index = 0
    length = len(source)
    while index < length:
        char = source[index]
        two = source[index:index + 2]

        if two == "//":
            end = source.find("\n", index)
            index = length if end == -1 else end
            continue
        if two == "/*":
            end = source.find("*/", index + 2)
            end = length if end == -1 else end + 2
            out.append("\n" * source.count("\n", index, end))
            index = end
            continue

        # Raw string literals: three or more quotes, closed by the same run.
        if source.startswith('"""', index):
            fence = 0
            while index + fence < length and source[index + fence] == '"':
                fence += 1
            closing = source.find('"' * fence, index + fence)
            end = length if closing == -1 else closing + fence
            out.append("\n" * source.count("\n", index, end))
            index = end
            continue

        # Verbatim strings: @"...", where "" is an escaped quote.
        if two in ('@"', '$"') or source.startswith('$@"', index) or source.startswith('@$"', index):
            verbatim = "@" in source[index:index + 3]
            cursor = source.index('"', index) + 1
            while cursor < length:
                if source[cursor] == "\\" and not verbatim:
                    cursor += 2
                    continue
                if source[cursor] == '"':
                    if verbatim and source[cursor:cursor + 2] == '""':
                        cursor += 2
                        continue
                    cursor += 1
                    break
                cursor += 1
            out.append("\n" * source.count("\n", index, cursor))
            index = cursor
            continue

        if char == '"':
            cursor = index + 1
            while cursor < length:
                if source[cursor] == "\\":
                    cursor += 2
                    continue
                if source[cursor] == '"':
                    cursor += 1
                    break
                if source[cursor] == "\n":
                    break
                cursor += 1
            index = cursor
            continue

        if char == "'":
            cursor = index + 1
            while cursor < length:
                if source[cursor] == "\\":
                    cursor += 2
                    continue
                if source[cursor] == "'":
                    cursor += 1
                    break
                cursor += 1
            index = cursor
            continue

        out.append(char)
        index += 1

    return "".join(out)


def top_level_types(clean: str) -> set[str]:
    """Type names declared directly in the namespace, not nested inside another type."""
    namespace_match = NAMESPACE.search(clean)
    # A file-scoped namespace (`namespace X;`) leaves declarations at depth 0; a block
    # namespace (`namespace X { }`) puts them at depth 1.
    base = 0
    if namespace_match and clean[namespace_match.end() - 1] == "{":
        base = 1

    names = set()
    depth = 0
    for match in re.finditer(r"[{}]|\b(?:class|struct|interface|enum|record)\s+([A-Za-z_]\w*)", clean):
        token = match.group(0)
        if token == "{":
            depth += 1
        elif token == "}":
            depth -= 1
        elif match.group(1) and depth == base:
            names.add(match.group(1))
    return names


def main() -> int:
    files = sorted(APP.rglob("*.cs"))
    if not files:
        print("::error::no C# found; this check is not looking where it thinks it is")
        return 1

    cleaned: dict[Path, str] = {}
    namespaces: dict[Path, str] = {}
    declares: dict[str, set[str]] = defaultdict(set)

    for path in files:
        clean = strip_noise(path.read_text(encoding="utf-8"))
        cleaned[path] = clean
        match = NAMESPACE.search(clean)
        namespace = match.group(1) if match else ""
        namespaces[path] = namespace
        for name in top_level_types(clean):
            declares[name].add(namespace)

    problems = 0
    for path in files:
        clean = cleaned[path]
        visible = {namespaces[path]} | set(USING.findall(clean))
        aliased = {name for name, _ in USING_ALIAS.findall(clean)}

        # A type declared in this very file is visible whatever the usings say, and a
        # member declared here shadows any type of the same name.
        own = top_level_types(clean) | set(MEMBER.findall(clean))

        missing: dict[str, set[str]] = {}
        for word in set(WORD.findall(clean)):
            if word in own or word in aliased or word not in declares:
                continue
            owners = declares[word]
            if not owners & visible:
                missing[word] = owners

        for name in sorted(missing):
            owners = ", ".join(sorted(missing[name]))
            print(f"::error file={path.relative_to(ROOT)}::'{name}' is declared in "
                  f"{owners}, which this file does not import (add `using {owners};`)")
            problems += 1

    if problems:
        return 1
    print(f"every app type named in {len(files)} C# files is imported where it is used")
    return 0


if __name__ == "__main__":
    sys.exit(main())
