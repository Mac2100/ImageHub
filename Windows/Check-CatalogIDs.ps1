<#
.SYNOPSIS
    Checks every winget package ID in ImageHub's catalog against winget itself.

.DESCRIPTION
    Catalog IDs are typed on a Mac, where there is no winget to check them with.
    Two have been wrong in real use: Slack shipped as Slack.Slack and failed with
    "No package found matching input criteria", and Microsoft.Office failed for a
    different reason entirely. Guessing has a track record, so this asks instead.

    Run it on any Windows machine with winget. It prints only the IDs winget cannot
    find, because a wall of lines saying OK is not the useful part.

    The list below is kept in step with Sources/ImageHub/Services/AppCatalog.swift
    by a check in .github/workflows/build.yml, so it cannot quietly drift.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File Check-CatalogIDs.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

$ids = @(
    'Google.Chrome', 'Mozilla.Firefox', 'Microsoft.Edge',
    'Adobe.Acrobat.Reader.64-bit', 'Microsoft.Teams', 'Zoom.Zoom',
    'SlackTechnologies.Slack', 'Notion.Notion', 'Libreoffice.Libreoffice',
    'Anthropic.Claude', 'Anthropic.ClaudeCode', '7zip.7zip',
    'Microsoft.PowerToys', 'Notepad++.Notepad++', 'VideoLAN.VLC',
    'voidtools.Everything', 'WinDirStat.WinDirStat', 'CrystalDewWorld.CrystalDiskInfo',
    'TeamViewer.TeamViewer', 'RealVNC.VNCViewer', 'AnyDeskSoftwareGmbH.AnyDesk',
    'Microsoft.EdgeWebView2Runtime', 'Microsoft.VCRedist.2015+.x64', 'Microsoft.DotNet.DesktopRuntime.8',
    'Oracle.JavaRuntimeEnvironment', 'Microsoft.VisualStudioCode', 'Git.Git',
    'Python.Python.3.12', 'Microsoft.WindowsTerminal', 'PuTTY.PuTTY',
    'Bitwarden.Bitwarden', '1Password.1Password', 'Malwarebytes.Malwarebytes',
    'KeePassXCTeam.KeePassXC', 'Cisco.Secure-Client', 'OpenVPNTechnologies.OpenVPNConnect',
    'WireGuard.WireGuard', 'Microsoft.OneDrive', 'Google.GoogleDrive',
    'Dropbox.Dropbox', 'Adobe.Acrobat.Reader.32-bit', 'Foxit.FoxitReader',
    'PDFgear.PDFgear', 'Microsoft.OneNote', 'Mozilla.Thunderbird',
    'Cisco.Webex', 'GoTo.GoToMeeting', 'RingCentral.RingCentral',
    'Discord.Discord', 'Rufus.Rufus', 'Greenshot.Greenshot',
    'ShareX.ShareX', 'WinSCP.WinSCP', 'FileZilla.Client',
    'Balena.Etcher', 'CPUID.CPU-Z', 'TechPowerUp.GPU-Z',
    'Piriform.CCleaner', 'Microsoft.Sysinternals.Suite', 'Splashtop.SplashtopBusiness',
    'Google.ChromeRemoteDesktop', 'Microsoft.RemoteDesktopClient', 'Microsoft.VCRedist.2013.x64',
    'Microsoft.DotNet.Runtime.8', 'Microsoft.DotNet.Framework.DeveloperPack_4', 'Adoptium.Temurin.21.JRE',
    'Microsoft.PowerShell', 'Microsoft.SQLServerManagementStudio', 'WinMerge.WinMerge',
    'Postman.Postman', 'Docker.DockerDesktop', 'GitHub.GitHubDesktop',
    'Insecure.Nmap', 'WiresharkFoundation.Wireshark'
)

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Host 'winget is not on this machine. Install App Installer from the Store first.' -ForegroundColor Red
    exit 1
}

Write-Host "Checking $($ids.Count) package IDs against winget..." -ForegroundColor Cyan
$missing = @()

foreach ($id in $ids) {
    # --exact so a near-miss cannot pass, --source winget so a Store package with a
    # similar name cannot answer for it.
    winget show --id $id --exact --source winget --disable-interactivity 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $missing += $id
        Write-Host "  MISSING  $id" -ForegroundColor Red
    }
}

Write-Host ''
Write-Host "$($ids.Count - $missing.Count) of $($ids.Count) found." -ForegroundColor Green
if ($missing.Count -gt 0) {
    Write-Host ''
    Write-Host 'Paste these back so the catalog can be corrected:' -ForegroundColor Yellow
    $missing | ForEach-Object { Write-Host "  $_" }
    Write-Host ''
    Write-Host 'To find the right ID, search by name, e.g.:' -ForegroundColor Yellow
    Write-Host '  winget search claude --source winget'
}
