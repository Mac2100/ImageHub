#!/usr/bin/env python3
"""Checks the artifacts an ImageHub build generates, before any drive is written.

Run against the output of `--emit-answer-file`, `--emit-office-config` and
`--emit-payload-config`, which both the macOS binary and ImageHub.exe implement.
CI runs it once per platform, so a mistake in either generator is caught by the
same rules rather than by whichever job happened to have the check.

autounattend.xml is the artifact with the least margin for error: a malformed one
fails on a technician's bench after the image is applied, not here. Everything
below is a failure mode that actually shipped once.

Usage:
    verify_generated.py <autounattend.xml> <office.xml> <config.json> [--repo DIR]
"""

from __future__ import annotations

import argparse
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

NS = {"u": "urn:schemas-microsoft-com:unattend"}

# Schema order for the components ImageHub writes, in the order Setup expects.
# Element order inside a component is part of the unattend schema, and Setup
# rejects the entire answer file when it is wrong -- it does not skip the
# offending element. A well-formed file shipped for weeks with RunSynchronous
# after UserData, which made every windowsPE pass invalid.
COMPONENT_ORDER = {
    "Microsoft-Windows-Setup": [
        "ComplianceCheck", "Diagnostics", "DiskConfiguration", "DynamicUpdate",
        "EnableFirewall", "EnableNetwork", "ImageInstall", "LogPath", "Multivariant",
        "Restart", "RunAsynchronous", "RunSynchronous", "UpgradeData", "UserData",
        "UseConfigurationSet", "WindowsDeploymentServices",
    ],
    # Only this component is checked. International-Core-WinPE is deliberately
    # left out: its canonical form puts SetupUILanguage first rather than
    # alphabetically, so asserting an order there would risk failing CI over
    # something unverified.
}

# RunSynchronousCommand/Path is capped at 259 characters. Exceeding it makes
# Windows reject the WHOLE unattend file -- and it does so at oobeSystem, after
# the image is applied, so the machine ends up in a "computer restarted
# unexpectedly" loop rather than failing early. An inline PowerShell one-liner hit
# 324 characters and shipped. Whether FirstLogonCommands/CommandLine shares the
# limit could not be confirmed, so it gets a looser bound: enough to catch an
# inlined script without failing a release over a guess.
COMMAND_LIMITS = {"Path": 259, "CommandLine": 1024}


class Report:
    def __init__(self) -> None:
        self.failures: list[str] = []

    def fail(self, message: str) -> None:
        self.failures.append(message)
        print(f"::error::{message}")

    def ok(self, message: str) -> None:
        print(f"  ok: {message}")


def check_answer_file(path: Path, report: Report) -> None:
    try:
        tree = ET.parse(path)
    except ET.ParseError as error:
        report.fail(f"{path.name} is not well-formed XML: {error}")
        return
    report.ok(f"{path.name} is well-formed ({path.stat().st_size} bytes)")

    root = tree.getroot()

    # Every pass Setup reads must be present, or the drive boots and then sits
    # waiting for a human.
    passes = {settings.get("pass") for settings in root.findall("u:settings", NS)}
    for wanted in ("windowsPE", "specialize", "oobeSystem"):
        if wanted not in passes:
            report.fail(f"the answer file is missing the {wanted} pass")
    if {"windowsPE", "specialize", "oobeSystem"} <= passes:
        report.ok("windowsPE, specialize and oobeSystem are all present")

    for settings in root.findall("u:settings", NS):
        which = settings.get("pass")
        for component in settings.findall("u:component", NS):
            name = component.get("name")
            expected = COMPONENT_ORDER.get(name or "")
            if not expected:
                continue
            seen = [child.tag.split("}")[-1] for child in component]
            ranks, unknown = [], []
            for tag in seen:
                if tag in expected:
                    ranks.append((expected.index(tag), tag))
                else:
                    unknown.append(tag)
            if unknown:
                report.fail(
                    f"{which}/{name}: element(s) not in the known schema order list: "
                    f"{unknown} — extend COMPONENT_ORDER in scripts/verify_generated.py")
            for (a, first), (b, second) in zip(ranks, ranks[1:]):
                if a > b:
                    report.fail(
                        f"{which}/{name}: <{first}> must come after <{second}>; "
                        "Setup will reject this answer file")
    report.ok("element order is valid for every checked component")

    over_length = []
    for node in root.iter():
        tag = node.tag.split("}")[-1]
        limit = COMMAND_LIMITS.get(tag)
        text = (node.text or "").strip()
        if limit and text and len(text) > limit:
            over_length.append(f"<{tag}> is {len(text)} chars (limit {limit}): {text[:80]}…")
    for line in over_length:
        report.fail(line)
    if not over_length:
        report.ok("all command strings are within their length limits")

    # Provisioning is launched via Launch.cmd, and the payload staged by Stage.cmd,
    # rather than by inlining PowerShell into the answer file -- the inlined version
    # was too long for the command string.
    text = path.read_text(encoding="utf-8")
    for helper in ("Stage", "Launch"):
        if f"{helper}.cmd" not in text:
            report.fail(f"the answer file never calls {helper}.cmd")
        else:
            report.ok(f"the answer file calls {helper}.cmd")

    # A <ProductKey> in the answer file overrides the OEM key in the PC's firmware,
    # which is what left machines showing "Activate Windows" until somebody opened
    # Settings by hand. The default template must not write one; an operator
    # choosing a MAK or KMS key is a separate, deliberate act.
    if root.find(".//u:ProductKey", NS) is not None:
        report.fail("the default template writes a <ProductKey>, which blocks OEM activation")
    else:
        report.ok("no product key in the default answer file, so the firmware key wins")


def check_office_config(path: Path, report: Report) -> None:
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as error:
        report.fail(f"{path.name} is not well-formed XML: {error}")
        return

    if root.tag != "Configuration":
        report.fail(f"Office config root is <{root.tag}>, expected <Configuration>")
        return

    add = root.find("Add")
    if add is None:
        report.fail("Office config has no <Add> element, so it installs nothing")
        return
    product = add.find("Product")
    if product is None or not product.get("ID"):
        report.fail('Office config <Add> has no <Product ID="…">')
        return

    # Level None is what makes it unattended; a visible installer waits for a human
    # who is not there.
    display = root.find("Display")
    if display is None or display.get("Level") != "None":
        report.fail('Office config is not silent (<Display Level="None"> missing)')
    if display is None or display.get("AcceptEULA") != "TRUE":
        report.fail("Office config does not accept the EULA, so it will prompt")
    if root.find("RemoveMSI") is None:
        report.fail("Office config has no <RemoveMSI />; an older MSI Office breaks the install")
    report.ok(f"Office config installs {product.get('ID')} silently")


def check_payload_config(path: Path, report: Report) -> None:
    try:
        config = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        report.fail(f"{path.name} is not valid JSON: {error}")
        return
    report.ok("payload config is valid JSON")

    # Provisioning's activation step reads this; a rename would silently turn
    # activation off rather than fail.
    mode = config.get("system", {}).get("activation", {}).get("mode")
    if mode != "automatic":
        report.fail(f"payload config activation.mode is {mode!r}, expected 'automatic'")
    else:
        report.ok("payload config carries the activation settings")

    for key in ("admin", "endUser", "identity", "apps", "microsoft365", "system", "scripts"):
        if key not in config:
            report.fail(f"payload config has no {key!r} section; Provision.ps1 reads it")


def check_payload_scripts(repo: Path, report: Report) -> None:
    payload = repo / "Shared/payload"

    for helper in ("Stage.cmd", "Launch.cmd", "JoinWifi.ps1", "Provision.ps1", "Splash.ps1"):
        if not (payload / helper).is_file():
            report.fail(f"Shared/payload/{helper} is missing")

    provision = (payload / "Provision.ps1").read_text(encoding="utf-8-sig", errors="replace")
    # Provision.ps1 schedules JoinWifi.ps1 by path when a machine has no wireless
    # interface yet. A missing reference would only surface on a technician's bench,
    # and only on the machines that need it most.
    if "JoinWifi.ps1" not in provision:
        report.fail("Provision.ps1 never references JoinWifi.ps1")

    launch = (payload / "Launch.cmd").read_text(encoding="utf-8-sig", errors="replace")
    # A machine came back with a staged payload, no provisioning and no logs at all,
    # because Launch.cmd trusted schtasks and exited 0 in silence. Three properties
    # stop that being possible again, and each is easy to undo by accident while
    # editing batch.
    if "launch.log" not in launch:
        report.fail("Launch.cmd no longer logs what it decided")
    if "provision-*.log" not in launch:
        report.fail("Launch.cmd no longer waits for proof that provisioning started")
    # The launch guard has to be a directory: mkdir is atomic, so two launchers
    # firing together cannot both proceed.
    if r'mkdir "C:\ImageHub\.launched"' not in launch:
        report.fail("Launch.cmd's launch guard is no longer the atomic mkdir")

    stage = (payload / "Stage.cmd").read_text(encoding="utf-8-sig", errors="replace")
    # RunOnce is the independent second trigger for a first logon that never runs
    # FirstLogonCommands.
    if "RunOnce" not in stage:
        report.fail("Stage.cmd no longer registers the RunOnce fallback")

    report.ok("launcher chain has logging, proof-of-start, a second trigger and an atomic guard")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("answer_file", type=Path)
    parser.add_argument("office_config", type=Path)
    parser.add_argument("payload_config", type=Path)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parent.parent)
    arguments = parser.parse_args()

    report = Report()
    print("Answer file")
    check_answer_file(arguments.answer_file, report)
    print("Office configuration")
    check_office_config(arguments.office_config, report)
    print("Payload configuration")
    check_payload_config(arguments.payload_config, report)
    print("Payload scripts")
    check_payload_scripts(arguments.repo, report)

    if report.failures:
        print(f"\n{len(report.failures)} problem(s) found.")
        return 1
    print("\nAll generated artifacts look right.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
