# ImageHub

Native **macOS and Windows** apps for building **bootable Windows golden-image USB
drives** from reusable deployment templates. Built for IT departments that reimage
machines by hand and want the whole thing to be one workflow: wipe the computer,
build the stick, boot it, walk away.

Both apps are in this repository, are built from the same commit, ship in the same
release, and read and write the same template files. They have the same features
and the same eight-stage build, each written to look like it belongs on its own
platform. A drive built on Windows is interchangeable with one built on a Mac —
and [CI proves it](#ci--releases) on every push rather than leaving it to trust.

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
- **IT admin profile** — a local administrator account with a password kept in your
  macOS Keychain (or, on Windows, DPAPI-encrypted for your account, with Credential
  Manager as an option), auto-logon for the provisioning run, optional hiding from
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
  mistake surfaces on the machine you built from rather than on a bench. Product, channel,
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
- **Screen lock and power timeouts** — inactivity lock, display and sleep
  timeouts on mains and battery, and what closing the lid does. All written as
  *machine policy* rather than with `powercfg`: power schemes are per-user, so
  configuring them during provisioning would set them for the IT admin account
  and leave the person who receives the machine on Windows' defaults. The policy
  keys cover every account and outrank a user's own scheme.
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
  (Settings → Appearance on macOS, Tools → Options → Appearance on Windows, where
  "System" follows the Windows personalisation setting).
- **One-click updates** — optional check against GitHub Releases at launch plus
  "Check for Updates…" in the app menu (Help menu on Windows). One release, one
  version number, one check; each app picks the asset for its own platform, so the
  Mac downloads the DMG and Windows downloads the `.exe`, swaps itself in place,
  and relaunches.

## Installation

Every [release](https://github.com/Mac2100/ImageHub/releases) carries both
platforms under one version number:

| File | Platform |
| --- | --- |
| `ImageHub-x.y.z.dmg` | macOS 14+, Apple Silicon and Intel |
| `ImageHub-x.y.z-win-x64.exe` | Windows 10 or 11, x64 |
| `ImageHub-x.y.z-macos-universal.zip` | the `.app` on its own |
| `ImageHub-x.y.z-win-x64.zip` | the `.exe` on its own, for deployment tools |

### macOS

Open the DMG and drag **ImageHub** into **Applications**.

> **Note on Gatekeeper:** releases are ad-hoc signed (no paid Apple Developer
> certificate), so the first launch requires right-clicking the app → **Open**, or:
> ```bash
> xattr -d com.apple.quarantine /Applications/ImageHub.app
> ```

### Windows

Download the `.exe` and run it. There is nothing to install: it is a single
self-contained file with the .NET runtime, the provisioning payload and the icons
inside it, so it runs from a folder, a share, or a stick.

Put it somewhere writable if you want in-app updates — the updater replaces the
file it is running from, and `C:\Program Files` needs elevation for that.
`%LOCALAPPDATA%\Programs\ImageHub\` is a good choice.

> **Note on SmartScreen:** the `.exe` is unsigned (a code-signing certificate is a
> paid, per-year, identity-verified purchase), so the first run shows "Windows
> protected your PC" → **More info** → **Run anyway**. Nothing needs to be turned
> off, and the warning stops once the file has a reputation.

The app asks for administrator rights only when it needs them — erasing a drive,
partitioning, mounting an ISO — and the status bar says which state you are in,
with **Restart as Administrator** in the Tools menu when you need to change it. It
does not demand elevation just to start, so browsing templates and reviewing an
answer file need no prompt at all.

### Build from source

**macOS** — Xcode 15+ / Swift 5.9+ on macOS 14 or later:

```bash
git clone https://github.com/Mac2100/ImageHub.git
cd ImageHub
./scripts/make_app.sh    # dist/ImageHub.app, ImageHub-<version>.dmg, and a .zip
```

For development, `swift run` works directly, or open `Package.swift` in Xcode.

**Windows** — the [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0),
and nothing else (no Visual Studio, no Windows SDK):

```powershell
git clone https://github.com/Mac2100/ImageHub.git
cd ImageHub
dotnet publish Windows\App\ImageHub.csproj -c Release -o publish
.\publish\ImageHub.exe
```

`dotnet run --project Windows\App` works for development. Both apps take their
version from `AppVersion.marketing` in
`Sources/ImageHub/Support/AppVersion.swift` — the csproj reads that Swift file at
build time, so there is one number to bump and the two apps can never disagree
about which release is newer than they are.

### No other tools, on either platform

Every current Windows 11 ISO has an `install.wim` larger than 4 GB. UEFI firmware
is only *guaranteed* to read FAT, so Windows Setup media has to be FAT32 — which
has a 4 GB per-file ceiling. The file therefore has to be split into
`install.swm` parts, which Setup reads natively.

On **Windows** that is DISM's `/Split-Image`, which is part of the operating
system; everything else uses the built-in storage cmdlets (`Clear-Disk`,
`New-Partition`, `Format-Volume`, `Mount-DiskImage`). Nothing to install.

On **macOS** there is no equivalent, so ImageHub uses
[wimlib](https://wimlib.net) for that one job and **ships it inside the app**.
Everything else — reading edition lists, formatting, copying, generating the
answer file — uses either macOS's own tools (`diskutil`, `hdiutil`) or code in
this repo. Notably the file copying is native rather than `rsync`: macOS still
ships rsync 2.6.9, which lacks the progress reporting this needs.

If you build the Mac app from source without staging wimlib, it falls back to
finding Homebrew's copy (`brew install wimlib`) and Settings → Tools has a
one-click installer. To produce the bundled binary yourself:

```bash
./scripts/build_wimlib.sh vendor/bin     # then ./scripts/make_app.sh
```

**Licence note:** `wimlib-imagex` is GPLv3+ (only `libwim` may be LGPL). ImageHub
invokes it as a separate process rather than linking it, so ImageHub itself stays
MIT and this is aggregation — but the DMG does contain a GPLv3 program. Its
licence text and pinned version ship in the app bundle, `scripts/build_wimlib.sh`
records exactly which source it was built from, and Settings → About links to the
licence. The Windows `.exe` contains no wimlib and no GPL code: DISM does the split.

## How a build works

Identical on both platforms — same eight stages, same log, same output:

1. **Validate** the template and re-check the drive is still removable external media.
2. **Erase** the drive and create a single FAT32 volume (MBR by default — the most
   widely bootable layout for Setup media).
3. **Copy** the mounted ISO to it, excluding the install image.
4. **Write the install image** — copied straight across if it's under 4 GB, split
   into `install*.swm` if not (wimlib on macOS, DISM on Windows). A template can
   substitute its own captured `install.wim` here.
5. **Generate `autounattend.xml`** from the template, injecting secrets from the
   Keychain (or DPAPI / Credential Manager) at this moment and nowhere else.
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

## The Windows app

[`Windows/App/`](Windows/App) is a WPF app on .NET 8, published as one
self-contained `ImageHub.exe`. It is not a port of the UI so much as the same app
written to Windows' conventions:

- **A real menu bar** — File, Edit, View, Tools, Help, with the accelerators
  Windows users expect (<kbd>Alt</kbd> navigation, <kbd>Ctrl</kbd>+<kbd>N</kbd>,
  <kbd>F5</kbd>, <kbd>F1</kbd>) rather than a Mac menu bar transplanted across.
- **Tools → Options**, a six-category settings dialog with OK / Cancel / Apply —
  not a macOS-style preferences window that saves as you type.
- **Fluent styling** — Windows 11 metrics (4px controls, 8px cards, 32px control
  height), accent underlines on tabs, the system accent colour honoured, a dark
  title bar via `DwmSetWindowAttribute`, and light/dark following the Windows
  personalisation setting.
- **A status bar** that states plainly whether you are running elevated, and a
  UAC shield on the actions that will prompt.
- **Native placement** — templates and settings in `%APPDATA%`, the image library,
  logs and caches in `%LOCALAPPDATA%`, notification-area balloons for finished
  builds, and drives appearing the moment they are plugged in (a `WM_DEVICECHANGE`
  hook, not a polling timer).

Two behavioural differences from the Mac are worth knowing, both from Windows
itself rather than choices made here:

- **A FAT32 volume is capped at 31 GB.** Windows' own `Format-Volume` refuses
  FAT32 above 32 GB, and Setup media has to be FAT32 (see above). On a larger
  stick ImageHub creates a 31 GB partition and leaves the rest unallocated, which
  is plenty for an ISO plus payload. macOS' `newfs_msdos` has no such limit and
  uses the whole drive.
- **Reading the edition list inside an ISO needs administrator rights**, because
  mounting the ISO does. Importing without them still works and the image is
  usable; its editions are listed as "Editions unread" until you refresh the entry
  while elevated.

### The PowerShell builder

[`Windows/ImageHub.ps1`](Windows/ImageHub.ps1) is still here and still supported.
It reads the same template JSON, generates the same `autounattend.xml`, and writes
the same payload, with no .NET and no app to install — which is what you want from
a task-sequence step, a lab bench with an execution-policy-only PowerShell, or a
build you script:

```powershell
# From an elevated PowerShell session, inside the checkout
.\Windows\ImageHub.ps1 -ListDisks
.\Windows\ImageHub.ps1 -Template .\StandardWorkstation.json -Iso D:\iso\Win11_24H2.iso -DiskNumber 3
```

Passwords are read from a `<template>.secrets.json` sidecar if present, otherwise
prompted for — they are never stored in the template, which keeps templates safe
to commit.

The app is the better choice for interactive work: it has the template editor, the
image library, build history and the update check, and it keeps secrets in DPAPI
rather than a sidecar file.

## Security notes

- Template passwords, product keys, domain-join credentials, and Wi-Fi
  passphrases are stored **only** in the operating system's own secret store: the
  macOS Keychain, or on Windows DPAPI-encrypted per user under
  `%LOCALAPPDATA%\ImageHub\` (Windows Credential Manager instead, if you prefer it
  — Tools → Options → Passwords). Either way they are never written into template
  JSON, so templates are safe to export and commit. Secrets do not travel with a
  template: move one between machines and the app asks for the passwords again.
- They leave the store in exactly one place: writing a drive. Windows Setup
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

The two apps mirror each other file for file, so a change on one platform has an
obvious counterpart on the other.

```
Sources/ImageHub/          SwiftUI app (macOS)
  Models/                  Template schema, images, drives, build jobs
  Services/                Disk, ISO, WIM, copying, answer file, payload, updates
  ViewModels/AppState      App-wide state and the build queue
  Views/                   UI, theme system, settings
Windows/App/               WPF app (.NET 8) — same layout, same file names
  Models/ Services/        The same schema and the same services, in C#
  ViewModels/AppState.cs   The same app-wide state
  Ui/                      Windows UI: menu bar, Options dialog, Fluent theme
  Themes/                  Light, Dark, and the control styles
Shared/payload/            Provision.ps1, Stage.cmd, Launch.cmd, Splash.ps1 —
                           the one copy, written onto every drive by both apps
Shared/schema/             JSON Schema for templates and the payload config
Windows/ImageHub.ps1       Scriptable Windows builder over the same schema
scripts/make_app.sh        Universal macOS build → .app, .zip, .dmg
scripts/build_wimlib.sh    Builds the bundled wimlib-imagex for this arch
scripts/make_icon.swift    Redraws the macOS icon from the in-app SF Symbol
scripts/make_win_icon.py   Draws Windows/App/Assets/ImageHub.ico from the same shape
scripts/check_catalog_parity.py  Keeps the three copies of the app catalog in step
scripts/verify_generated.py      Asserts what Windows Setup requires of the output
scripts/compare_generated.py     Compares the two apps' output, file by file
```

## CI / Releases

Every push and pull request builds **both** apps and checks they still agree:

| Job | What it does |
| --- | --- |
| Repository checks | Parses every PowerShell script, checks the payload is ASCII with a BOM (Windows PowerShell 5.1 decodes a BOM-less file as ANSI), and checks the three copies of the app catalog list the same package IDs. On Linux, so a typo fails in a minute. |
| Build wimlib | Builds the bundled `wimlib-imagex`. Allowed to fail for Intel: the app falls back to Homebrew. |
| Build macOS app | The universal `.app`, a `.dmg` and a `.zip`. |
| Build Windows app | `ImageHub-<version>-win-x64.exe` and a `.zip`, and asserts the `.exe` reports the version in `AppVersion.swift` and really does carry the payload inside it. |
| Same media from both apps | Both apps generate `autounattend.xml`, `configuration.xml` and `config.json` from the same template, and the two sets are compared. |
| Publish release | Refuses to publish unless both a DMG and a `win-x64.exe` are present. |

The parity job is the one that matters. A release ships two programs that have to
produce interchangeable media, and "we ported it carefully" is not evidence. So
each app is asked to emit its generated files (`--emit-answer-file`,
`--emit-office-config`, `--emit-payload-config`), each platform checks its own
output against what Windows Setup actually requires — the three passes, the
schema's element order, the 259- and 1024-character limits on command strings, a
silent Office install — and then the two sets are compared as parsed trees rather
than as text, so reindentation is ignored and a changed value is not. If the two
generators drift, this fails and names the file and the element.

To cut a release: bump `AppVersion.marketing` in
`Sources/ImageHub/Support/AppVersion.swift` — the one place either app reads its
version from — then tag the commit `v<version>` and push the tag. Or run the
workflow manually with **Publish a GitHub Release** ticked. The release carries
both platforms' files, which is what the in-app update check on each platform
looks at.

## License

[MIT](LICENSE)
