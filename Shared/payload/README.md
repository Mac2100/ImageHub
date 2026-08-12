# Provisioning payload

Everything in this folder is copied verbatim onto every USB drive ImageHub
builds, landing at `<usb>\ImageHub\`. Windows Setup stages it to `C:\ImageHub`
during its `specialize` pass, so provisioning keeps working after the stick is
pulled out.

| File | Purpose |
| --- | --- |
| `Provision.ps1` | The whole first-boot provisioning run. Reads `config.json`. |
| `Splash.ps1` | Full-screen branded progress screen. Runs as its own process and polls `status.json`, so a long install can't make it look hung. |
| `status.json` | Written on the target machine: what provisioning is doing right now. |
| `config.json` | Written at build time from the deployment template. **Not in git** — it's generated per drive and contains resolved secrets. |
| `template.json` | An audit copy of the template the drive was built from. |
| `Installers/` | Bundled MSI/EXE installers, when the template has any. |
| `Assets/` | Wallpaper, lock screen, Start layout. |
| `Scripts/` | Custom PowerShell from the template, one file per script. |
| `logs/` | Written on the target machine: one log per provisioning run. |

## Running it by hand

`Provision.ps1` is a normal script — it does not need to be run from Setup. To
re-apply a template to a machine that's already installed:

```powershell
powershell -ExecutionPolicy Bypass -File C:\ImageHub\Provision.ps1
```

It is close to idempotent: re-running mostly re-applies settings and skips apps
that winget reports as already installed. The exceptions are the interactive
paths (`promptAtFirstBoot`, BitLocker with a PIN), which will ask again.

Useful during development:

```powershell
# Point it at a config somewhere else and don't wait for a keypress at the end
.\Provision.ps1 -ConfigPath D:\ImageHub\config.json -NoPause
```

## What it does, in order

1. **Wi-Fi** — imports the profile and connects, before anything that needs the
   network.
2. **Naming** — resolves the computer-name tokens and renames the machine;
   sets the workgroup when the template isn't domain-joined.
3. **Regional and power** — time zone, power plan, sleep/hibernation/fast startup.
4. **Remote access** — Remote Desktop and the ICMP firewall rule.
5. **Desktop defaults** — written to `C:\Users\Default\NTUSER.DAT` as well as the
   current user, so accounts created later inherit them.
6. **Telemetry and consumer features** — policy keys and scheduled tasks.
7. **Debloat** — removes the listed AppX packages for all users *and* their
   provisioned copies, so new profiles don't get them back.
8. **Optional features** — DISM features such as `NetFx3`.
9. **Applications** — winget packages, bundled installers, inline scripts.
   Waits for internet first when any winget app is present.
10. **Branding** — OEM support information (Settings → About), wallpaper, lock
    screen, Start layout.
11. **Windows Update policy**, and optionally installs pending updates.
12. **Accounts** — password-change flags, or the interactive end-user prompt.
13. **BitLocker** — enables it and writes the recovery key to `logs\`.
14. **Registry tweaks** from the template.
15. **Custom scripts** — `provision` phase, then `finalize`.
16. **Cleanup** — deletes `config.json` and the staged `unattend.xml` copies,
    because they hold credentials in clear text.

## Failure behaviour

Every step is wrapped: a failing step is logged and the run continues. Apps
marked `required` and scripts with `continueOnError: false` are recorded as
*failures* (non-zero exit); everything else is a *warning*. Both are summarised
on screen at the end and written to `provisioned.json`.

This is deliberate — a machine that is 90% provisioned with a log explaining the
gap is far more useful to a technician than one that died on step three.

## Editing these scripts

`Shared/payload/` is the canonical copy, shared by all three builders:

- the macOS app bundles it into `ImageHub.app/Contents/Resources/payload`
  (see `scripts/make_app.sh`);
- the Windows app embeds it as resources inside the single `ImageHub.exe`
  (see the `EmbeddedResource` item in `Windows/App/ImageHub.csproj`) and writes it
  back out byte for byte;
- `Windows/ImageHub.ps1` copies it straight out of the checkout.

To iterate without rebuilding, point **Settings → Tools → Provisioning scripts**
(macOS) or **Tools → Options → Advanced** (Windows) at your checkout's
`Shared/payload`.

CI parses every `.ps1` here on each push, so a syntax error fails the build
rather than a technician's machine at 2am. It also checks each file is plain ASCII
with a UTF-8 BOM: Windows PowerShell 5.1, which is what actually runs
`Provision.ps1` on a target machine, decodes a BOM-less file as Windows-1252, and
an em dash then becomes three characters ending in a curly quote — which
PowerShell treats as a string delimiter, producing a "Missing closing '}'" on a
script that parses perfectly under PowerShell 7. And a separate job checks the
Windows `.exe` still carries every file listed here, since a missing one would
only show up on a drive with no `Provision.ps1` on it.
