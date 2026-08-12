#!/usr/bin/env python3
"""Checks every Setter TargetName in a template points at something WPF can target.

A trigger's `TargetName` is resolved against the *elements* of the template it sits
in. Two things go wrong there, and both are silent until the XAML markup compiler
runs on a Windows machine:

  * the name does not exist in that template at all -- a typo, or a name that lives
    in a sibling template;
  * the name exists but belongs to a Freezable rather than an element. Naming a
    RotateTransform and setting its Angle from a trigger reads perfectly and is
    wrong; WPF reports MC4111 "Cannot find the Trigger target", which sounds like a
    missing name and is really a wrong *kind* of name. Replace the whole
    RenderTransform on the named element instead.

The markup compiler stops at the first of these, so a handful of them costs a
handful of full Windows runs to find. This finds all of them at once, anywhere.
"""

from __future__ import annotations

import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

XAML = "{http://schemas.microsoft.com/winfx/2006/xaml}"
TEMPLATE_TAGS = {"ControlTemplate", "DataTemplate", "ItemsPanelTemplate", "HierarchicalDataTemplate"}

# Freezables that carry an x:Name convincingly but are not part of the template's
# element tree, so a TargetName can never resolve to them.
NOT_TARGETABLE = {
    "RotateTransform", "ScaleTransform", "TranslateTransform", "SkewTransform",
    "MatrixTransform", "TransformGroup", "TransformCollection",
    "SolidColorBrush", "LinearGradientBrush", "RadialGradientBrush",
    "ImageBrush", "VisualBrush", "DrawingBrush", "GradientStop",
    "DropShadowEffect", "BlurEffect",
    "PathGeometry", "StreamGeometry", "EllipseGeometry", "RectangleGeometry",
    "LineGeometry", "GeometryGroup", "CombinedGeometry",
    "Pen", "DoubleAnimation", "ColorAnimation", "ThicknessAnimation",
}


def local(tag: str) -> str:
    return tag.split("}")[-1]


def check(path: Path) -> list[str]:
    tree = ET.parse(path)
    root = tree.getroot()

    parents = {child: parent for parent in root.iter() for child in parent}

    def enclosing_template(element):
        current = parents.get(element)
        while current is not None:
            if local(current.tag) in TEMPLATE_TAGS:
                return current
            current = parents.get(current)
        return None

    # name -> tag, per template.
    names: dict[object, dict[str, str]] = {}
    for template in root.iter():
        if local(template.tag) not in TEMPLATE_TAGS:
            continue
        found: dict[str, str] = {}
        for element in template.iter():
            name = element.get(XAML + "Name") or element.get("Name")
            if name:
                found[name] = local(element.tag)
        names[template] = found

    problems = []
    for element in root.iter():
        target = element.get("TargetName")
        if target is None:
            continue
        template = enclosing_template(element)
        if template is None:
            problems.append(
                f"<{local(element.tag)} TargetName=\"{target}\"> is not inside a template, "
                f"so the name cannot resolve")
            continue

        known = names.get(template, {})
        if target not in known:
            near = ", ".join(sorted(known)) or "none"
            problems.append(
                f"TargetName=\"{target}\" does not name anything in its template "
                f"(that template defines: {near})")
        elif known[target] in NOT_TARGETABLE:
            problems.append(
                f"TargetName=\"{target}\" names a <{known[target]}>, which is a Freezable "
                f"rather than an element in the template — WPF reports this as MC4111. "
                f"Set the property that holds it on the parent element instead.")

    return problems


def main() -> int:
    files = sorted(ROOT.glob("Windows/App/**/*.xaml"))
    if not files:
        print("::error::no XAML found; this check is not looking where it thinks it is")
        return 1

    total = 0
    for path in files:
        try:
            problems = check(path)
        except ET.ParseError as error:
            print(f"::error file={path.relative_to(ROOT)}::{error}")
            total += 1
            continue
        for problem in problems:
            print(f"::error file={path.relative_to(ROOT)}::{problem}")
        total += len(problems)

    if total:
        return 1
    print(f"every TargetName in {len(files)} XAML files resolves to a targetable element")
    return 0


if __name__ == "__main__":
    sys.exit(main())
