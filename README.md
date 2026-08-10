# ImageHub

Native macOS app for building **bootable Windows golden-image USB drives** from
reusable deployment templates. Built for IT departments that reimage machines by
hand and want the whole thing to be one workflow: wipe the computer, build the
stick, boot it, walk away.

![ImageHub icon](Resources/icon_1024.png)

A template describes what a finished machine looks like — Windows edition, disk
layout, IT admin profile, applications, system configuration, first-boot
experience — and ImageHub turns it into unattended install media. Boot a target
machine from the drive and it wipes the disk, installs Windows, creates the
accounts, installs the apps, applies the configuration, and stops at a summary
screen. No keystrokes in between.

## Features

- **Deployment templates** — as many as you like, each a plain JSON file you can
  export, review in a pull request, and share with the team. Icon, name, and a
  one-line summary; a Review tab that shows the generated answer file and lists
  exactly what's blocking a build — click a problem and it takes you to the tab
  that owns it.
- **Windows image library** — import an ISO (the browser round trip to Microsoft
  is the reliable route; their download service refuses automated requests),
  or pull one from an internal URL with a **pinned SHA-256** so everybody builds
  from the same bytes. Imports are verified byte-for-byte and rejected if the ISO
  won't mount, rather than failing mid-build. Editions inside `install.wim` are
  read natively, no external tools.
- **Wipe and reimage in one pass** — the generated `autounattend.xml` wipes the
  target disk, lays down EFI/MSR/Windows partitions, and installs the edition the
  template asks for.
- **Activation, handled** — by default no product key goes into the answer file at
  all, so Windows uses the OEM key in the PC's firmware (or the machine's digital
  licence) and activates on its own; provisioning installs that firmware key and
  runs activation to be sure. KMS host and MAK/retail keys are both options.
  Nobody opens Settings to clear an "Activate Windows" watermark.
- **IT admin profile** — a local administrator account with a password kept in
  your macOS Keychain, auto-logon for the provisioning run, optional hiding from
  the sign-in screen afterwards.
- **Applications** — winget package IDs (with a built-in catalog of ~70 packages
  IT actually deploys, and none that are known not to work), bundled MSI/EXE
  installers copied onto the stick for offline or version-pinned installs, or
  inline PowerShell. Per-app "fail the build if this doesn't install".
- **Microsoft 365 via the Office Deployment Tool** — winget's `Microsoft.Office`
  failed on every real run, because winget pins an installer hash and Microsoft
  ships a new installer behind the same URL; the manifest is stale more often than
  not and no caller can override it. So it is not in the catalog at all, and Office
  gets Microsoft's own supported path instead. Tick the apps you want — Word, Excel,
  PowerPoint, Outlook, OneNote, Access, Publisher — and that is the whole setting.
  ImageHub downloads the Deployment Tool from Microsoft on the first build that
  needs it (~7 MB, cached) and generates `configuration.xml` **at build time**, so a
  mistake surfaces on your Mac rather than on a bench. Product, channel,
  architecture and language are fixed because each had one right answer; Teams and
  OneDrive are left to the app catalog and to Windows, so nothing installs twice.

  Neither the Deployment Tool nor Office is committed to this repo. Both are
  Microsoft's to license, not ImageHub's to redistribute — fetching the tool from
  source at build time avoids the question, and Office is never bundled at all.
- **System configuration** — time zone and locale, power plan, Remote Desktop,
  Explorer and taskbar defaults written to the *default user profile*, telemetry
  and consumer-feature policies, AppX debloat list, optional Windows features,
  Windows Update policy, BitLocker, Wi-Fi profile, wallpaper/lock screen/Start
  layout, and arbitrary registry values.
- **End-user setup** — leave Windows OOBE to whoever receives the machine,
  pre-create a named local account, or have provisioning prompt the technician
  at first boot. Workgroup, Active Directory domain join, or leave the device
  unjoined for Entra ID / Intune enrolment.
- **Branded setup screen** — provisioning takes 10–40 minutes and otherwise runs
  in a bare PowerShell console. Instead it shows a full-screen screen with your
  logo, organisation name, the current step and a progress bar. It runs as its own
  process polling a status file, so a ten-minute app install can't make it look
  hung, and it can't slow provisioning down. It holds the foreground against
  installer popups and closes the Start menu if the shell puts it in the way, asks
  for the end-user account inline when the template wants a technician to decide,
  and finishes on an unmistakable completion state — badge, summary of what
  happened, and confetti. Organisation name, logo and support contact also land in
  Windows' OEM information, so they show in Settings → About.
- **Custom PowerShell** — hooks in three phases (Setup `specialize`,
  provisioning, finalize) for anything the template can't express.
- **Live build view** — eight stages with per-stage progress, a streaming log,
  cancel, and a saved log per build in Build History.
- **Safety by construction** — only removable external media is ever offered as a
  target; internal disks are filtered out before the list is built, so there is
  nothing to pick by mistake. The drive is re-verified immediately before
  erasing, and the finished media is checked for its boot files before the build
  is called done.
- **Themes** — six accent themes and a System/Light/Dark appearance override
  (Settings → Appearance).
- **One-click updates** — optional check against GitHub Releases at launch plus
  "Check for Updates…" in the app menu; installing downloads the DMG, swaps the
  app in place, and relaunches.

## Installation

### Download

Grab the latest `ImageHub-x.y.z.dmg` from
[Releases](https://github.com/Mac2100/ImageHub/releases), open it, and drag
**ImageHub** into **Applications**.

> **Note on Gatekeeper:** releases are ad-hoc signed (no paid Apple Developer
> certificate), so the first launch requires right-clicking the app → **Open**, or:
> ```bash
> xattr -d com.apple.quarantine /Applications/ImageHub.app
> ```

### Build from source

Requires Xcode 15+ / Swift 5.9+ on macOS 14 or later.

```bash
git clone https://github.com/Mac2100/ImageHub.git
cd ImageHub
./scripts/make_app.sh    # dist/ImageHub.app, ImageHub-<version>.dmg, and a .zip
```

For development, `swift run` works directly, or open `Package.swift` in Xcode.

### Nothing to install

Every current Windows 11 ISO has an `install.wim` larger than 4 GB. UEFI firmware
is only *guaranteed* to read FAT, so Windows Setup media has to be FAT32 — which
has a 4 GB per-file ceiling. The file therefore has to be split into
`install.swm` parts, which Setup reads natively. ImageHub uses
[wimlib](https://wimlib.net) for that one job, and **ships it inside the app**, so
there is nothing to set up. The split happens automatically during a build.

Everything else — reading edition lists, formatting, copying, generating the
answer file — uses either macOS's own tools (`diskutil`, `hdiutil`) or code in
this repo. Notably the file copying is native rather than `rsync`: macOS still
ships rsync 2.6.9, which lacks the progress reporting this needs.

If you build from source without staging wimlib, the app falls back to finding
Homebrew's copy (`brew install wimlib`) and Settings → Tools has a one-click
installer. To produce the bundled binary yourself:

```bash
./scripts/build_wimlib.sh vendor/bin     # then ./scripts/make_app.sh
```

**Licence note:** `wimlib-imagex` is GPLv3+ (only `libwim` may be LGPL). ImageHub
invokes it as a separate process rather than linking it, so ImageHub itself stays
MIT and this is aggregation — but the DMG does contain a GPLv3 program. Its
licence text and pinned version ship in the app bundle, `scripts/build_wimlib.sh`
records exactly which source it was built from, and Settings → About links to the
licence.

## How a build works

1. **Validate** the template and re-check the drive is still removable external media.
2. **Erase** the drive and create a single FAT32 volume (MBR by default — the most
   widely bootable layout for Setup media).
3. **Copy** the mounted ISO to it, excluding the install image.
4. **Write the install image** — copied straight across if it's under 4 GB, split
   into `install*.swm` with wimlib if not. A template can substitute its own
   captured `install.wim` here.
5. **Generate `autounattend.xml`** from the template, injecting secrets from the
   Keychain at this moment and nowhere else.
6. **Write the `ImageHub\` payload** — `Provision.ps1`, a resolved `config.json`,
   bundled installers, assets, and custom scripts.
7. **Verify** `bootmgr`, `boot/bcd`, `sources/boot.wim`, the install image, the
   answer file, and the payload are all present.

On the target machine, Setup consumes the answer file, stages the payload to
`C:\ImageHub`, signs in as the IT admin account once, and runs `Provision.ps1`,
which does the application installs and configuration and logs everything to
`C:\ImageHub\logs`. See [`Shared/payload/README.md`](Shared/payload/README.md) for
the full order of operations.

## Two kinds of "golden image"

ImageHub supports both, per template:

- **Stock ISO + provisioning** (default) — Microsoft's unmodified `install.wim`
  plus an answer file and provisioning payload. Templates are kilobytes, diff
  cleanly in git, need no Windows machine to build, and are trivial to amend.
- **A captured reference image** — under the template's Windows tab → **Advanced**,
  point *Install a captured image* at a sysprepped (`/generalize /oobe`) image from
  a reference machine or a share. Setup still boots from Microsoft's media; only
  the installed image is yours. Provisioning still runs on top, so the two
  approaches compose.

## Windows

[`Windows/ImageHub.ps1`](Windows/ImageHub.ps1) is the Windows-side builder. It
reads the same template JSON, generates the same `autounattend.xml`, and writes
the same payload, using `diskpart`/`Mount-DiskImage`/`robocopy`/`DISM` instead of
the macOS tools — so a drive built on Windows is interchangeable with one built on
a Mac, and no extra tools are needed there (DISM splits WIMs itself).

```powershell
# From an elevated PowerShell session, inside the checkout
.\Windows\ImageHub.ps1 -ListDisks
.\Windows\ImageHub.ps1 -Template .\StandardWorkstation.json -Iso D:\iso\Win11_24H2.iso -DiskNumber 3
```

Passwords are read from a `<template>.secrets.json` sidecar if present, otherwise
prompted for — they are never stored in the template, which keeps templates safe
to commit.

**Current state:** the Windows side is a complete command-line builder, not yet a
GUI. The template schema
([`Shared/schema/template.schema.json`](Shared/schema/template.schema.json)) is
the documented contract, so a native WinUI front-end is a second client over
logic that already exists rather than a rewrite. CI only builds the macOS app.

## Security notes

- Template passwords, product keys, domain-join credentials, and Wi-Fi
  passphrases are stored **only** in the macOS Keychain. They are never written
  into template JSON, so templates are safe to export and commit.
- They leave the Keychain in exactly one place: writing a drive. Windows Setup
  reads account passwords from `autounattend.xml` in **clear text** — that is how
  the format works — so **treat a finished USB drive as a credential.** The app
  says so before every build.
- `Provision.ps1` deletes `config.json` and the staged `unattend.xml` copies from
  the target machine once it has consumed them.
- Joining Wi-Fi turns Location services on for the length of the connect, and
  turns them back off afterwards. Windows 11 24H2 put the WLAN API behind that
  permission, so `netsh wlan connect` fails with "Access is denied" without it.
  Only the settings that were not already permissive are touched, each is
  restored to the exact value it had, and the log records both the change and
  the restore.
- Enabling BitLocker writes the recovery key to `C:\ImageHub\logs\` so you can
  collect it at handover. Move it into your key escrow and delete the file — both
  the app and the script warn about this.
- ImageHub never mirrors or modifies Microsoft's images. "Download from Microsoft"
  uses the same public download service as microsoft.com and the bytes come from
  Microsoft's CDN. That service rate-limits by IP and commonly blocks VPN and
  datacentre ranges; when it refuses, import an ISO or use an internal URL.
- The only other network requests the app makes are the optional, off-switchable
  update check against the public GitHub Releases API and ISO downloads you ask for.

## Repository layout

```
Sources/ImageHub/          SwiftUI app
  Models/                  Template schema, images, drives, build jobs
  Services/                Disk, ISO, WIM, copying, answer file, payload, updates
  ViewModels/AppState      App-wide state and the build queue
  Views/                   UI, theme system, settings
Shared/payload/            Provision.ps1 + Splash.ps1 — copied onto every drive
Shared/schema/             JSON Schema for templates and the payload config
Windows/ImageHub.ps1       Windows-side builder over the same schema
scripts/make_app.sh        Universal build → .app, .zip, .dmg
scripts/build_wimlib.sh    Builds the bundled wimlib-imagex for this arch
scripts/make_icon.swift    Redraws the app icon from the in-app SF Symbol
```

## CI / Releases

Every push and pull request builds the universal app and uploads both a DMG and a
zipped `.app` as artifacts, and parses the PowerShell payload to catch syntax
errors early. Pushing a tag like `v1.2.0` additionally creates a GitHub Release
with both files attached — which is what the in-app update checker looks at.

To cut a release: bump `AppVersion.marketing` in
`Sources/ImageHub/Support/AppVersion.swift`, then tag the commit `v<version>` and
push the tag. Or run the workflow manually with **Publish a GitHub Release**
ticked.

## License

[MIT](LICENSE)
