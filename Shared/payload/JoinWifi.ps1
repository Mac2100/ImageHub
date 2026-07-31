<#
.SYNOPSIS
    Joins the Wi-Fi network a template asked for, once the machine can see one.

.DESCRIPTION
    Provisioning cannot store a Wi-Fi profile on a machine with no wireless
    interface -- netsh refuses every wlan operation with "There is no wireless
    interface on the system". On a freshly imaged laptop that is almost always a
    missing driver rather than missing hardware: Windows fetches the Wi-Fi driver
    from Windows Update some time after provisioning has finished.

    So Provision.ps1 registers this script as the scheduled task
    ImageHubJoinWifi, triggered at logon and at startup. It waits for an
    interface to appear, stores the profile, connects, and verifies. On success it
    deletes the stored profile and unregisters itself, so it runs exactly as many
    times as it needs to and no more.

    Run it by hand to retry immediately:
        powershell -ExecutionPolicy Bypass -File C:\ImageHub\JoinWifi.ps1 -Ssid "My SSID"

.PARAMETER Ssid
    The network to join. Must match the profile stored in wifi.bin.

.PARAMETER WaitMinutes
    How long to wait for a wireless interface before giving up for this run. The
    task stays registered, so the next logon or restart tries again.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Ssid,
    [int]$WaitMinutes = 20
)

$ErrorActionPreference = 'Stop'

$StateDirectory = 'C:\ProgramData\ImageHub'
$Blob = Join-Path $StateDirectory 'wifi.bin'
$TaskName = 'ImageHubJoinWifi'

$LogDirectory = 'C:\ImageHub\logs'
New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
$LogFile = Join-Path $LogDirectory ("wifi-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))

function Write-Log {
    param([Parameter(Mandatory)][string]$Message, [string]$Level = 'INFO')
    $line = "[{0:HH:mm:ss}] [{1}] {2}" -f (Get-Date), $Level, $Message
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
}

function Remove-Self {
    <# Nothing left to do, so leave nothing behind. #>
    Remove-Item -LiteralPath $Blob -Force -ErrorAction SilentlyContinue
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-Log -Level OK -Message "Unregistered $TaskName."
    } catch {
        Write-Log -Level WARN -Message "Couldn't unregister $TaskName : $($_.Exception.Message)"
    }
}

Write-Log "Deferred Wi-Fi join for '$Ssid' starting."

if (-not (Test-Path -LiteralPath $Blob)) {
    Write-Log -Level WARN -Message 'No stored profile, so there is nothing to join. Removing the task.'
    Remove-Self
    exit 0
}

# Already on it from an earlier run, or a human set it up in the meantime.
$existing = & netsh.exe wlan show profiles 2>&1
if ($LASTEXITCODE -eq 0 -and ($existing -join ' ') -match [regex]::Escape($Ssid)) {
    Write-Log -Level OK -Message "A profile for '$Ssid' already exists. Nothing to do."
    Remove-Self
    exit 0
}

# The service is demand-start, and nothing on a wired machine triggers it.
try {
    $service = Get-Service -Name 'wlansvc' -ErrorAction Stop
    if ($service.StartType -ne 'Automatic') {
        Set-Service -Name 'wlansvc' -StartupType Automatic -ErrorAction Stop
    }
    if ($service.Status -ne 'Running') {
        Start-Service -Name 'wlansvc' -ErrorAction Stop
        $service.WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
    }
} catch {
    Write-Log -Level WARN -Message "Wireless AutoConfig would not start: $($_.Exception.Message)"
    exit 0
}

# Wait for the driver to land. Staying registered means giving up now costs
# nothing -- the next logon or restart tries again.
$deadline = (Get-Date).AddMinutes($WaitMinutes)
$found = $false
while ((Get-Date) -lt $deadline) {
    $interfaces = & netsh.exe wlan show interfaces 2>&1
    if ($LASTEXITCODE -eq 0 -and ($interfaces -match 'Name\s*:')) { $found = $true; break }
    Start-Sleep -Seconds 30
}

if (-not $found) {
    Write-Log -Level WARN -Message ("Still no wireless interface after $WaitMinutes minute(s). " +
        'Leaving the task registered to try again at the next logon or restart.')
    exit 0
}
Write-Log -Level OK -Message 'A wireless interface is present.'

# Unprotect, store, connect.
$profilePath = Join-Path $env:TEMP 'imagehub-wifi-deferred.xml'
try {
    Add-Type -AssemblyName System.Security -ErrorAction Stop
    $xml = [System.Text.Encoding]::UTF8.GetString(
        [System.Security.Cryptography.ProtectedData]::Unprotect(
            [System.IO.File]::ReadAllBytes($Blob),
            $null,
            [System.Security.Cryptography.DataProtectionScope]::LocalMachine))
    Set-Content -LiteralPath $profilePath -Value $xml -Encoding UTF8

    $added = & netsh.exe wlan add profile filename="$profilePath" user=all 2>&1
    $addedText = (($added | Where-Object { "$_".Trim() }) -join '; ')
    if ($LASTEXITCODE -ne 0) {
        Write-Log -Level WARN -Message "netsh refused the profile: $addedText"
        exit 0
    }
    Write-Log -Level OK -Message "Profile stored: $addedText"
} catch {
    Write-Log -Level WARN -Message "Couldn't restore the stored profile: $($_.Exception.Message)"
    exit 0
} finally {
    Remove-Item -LiteralPath $profilePath -Force -ErrorAction SilentlyContinue
}

$connect = & netsh.exe wlan connect name="$Ssid" 2>&1
Write-Log "Connect requested: $((($connect | Where-Object { "$_".Trim() }) -join '; '))"

$joined = $false
$state = @()
for ($attempt = 0; $attempt -lt 15; $attempt++) {
    Start-Sleep -Seconds 2
    $state = & netsh.exe wlan show interfaces 2>&1
    $stateText = ($state -join ' ')
    if ($stateText -match 'State\s*:\s*connected' -and $stateText -match [regex]::Escape($Ssid)) {
        $joined = $true
        break
    }
}

if ($joined) {
    Write-Log -Level OK -Message "Connected to $Ssid."
} else {
    # The profile is stored either way, which is the part that matters: Windows
    # uses it by itself when the machine is next off Ethernet and in range.
    $current = (($state | Where-Object { "$_" -match 'State\s*:|SSID\s*:' }) -join '; ')
    Write-Log -Level WARN -Message ("Stored the profile but did not associate within 30s. " +
        "Adapter now: $current")
}

Remove-Self
exit 0
