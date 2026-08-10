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

<#
    Windows 11 24H2 moved the WLAN API behind the location permission, and
    "netsh wlan connect" calls WlanGetAvailableNetworkList underneath. Storing a
    profile still works; connecting does not. A real run showed exactly that
    shape -- "Profile stored: Profile DCE-Public is added on interface Wi-Fi"
    immediately followed by "Network shell commands need location permission to
    access WLAN information [...] WlanGetAvailableNetworkList returns error 5:
    Access is denied", and then thirty seconds of an adapter that never
    associated.

    A freshly imaged machine has location off, because nothing turned it on:
    the answer file skips the OOBE privacy pages. So the permission has to be
    granted here or the connect cannot work.

    It is granted for the length of the connect and then put back, so a machine
    is not left with Location services on because it once needed to join a
    network. Association survives the restore: the permission gates apps calling
    the WLAN API, not the profile, and Wireless AutoConfig reconnects on its own
    afterwards.

    This is deliberately the same block as the one in Provision.ps1. The two
    scripts share no module -- this one is copied to C:\ImageHub and runs long
    after provisioning has finished -- and the wlansvc handling above is
    duplicated for the same reason.
#>
$LocationConsentKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location'
$LocationPolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors'

function Get-LocationValue {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    try {
        return (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name
    } catch {
        return $null
    }
}

function Grant-LocationAccess {
    <#
        Returns what it changed rather than what it set, so the restore can put
        back exactly the previous state -- including removing a value that was
        not there to begin with. Wrapped in a hashtable because returning a bare
        array of one element would unroll to the element itself, and a hashtable
        reports its key count as .Count.
    #>
    $changed = @()

    # The master toggle and the desktop-app toggle are separate: netsh is a
    # non-packaged app, so granting only the first still leaves it denied.
    foreach ($path in @($LocationConsentKey, (Join-Path $LocationConsentKey 'NonPackaged'))) {
        try {
            $before = Get-LocationValue -Path $path -Name 'Value'
            if ($before -eq 'Allow') { continue }
            if (-not (Test-Path -LiteralPath $path)) {
                New-Item -Path $path -Force -ErrorAction Stop | Out-Null
            }
            New-ItemProperty -LiteralPath $path -Name 'Value' -Value 'Allow' `
                -PropertyType String -Force -ErrorAction Stop | Out-Null
            $changed += @{ Path = $path; Name = 'Value'; Before = $before }
        } catch {
            Write-Log -Level WARN -Message ("Couldn't grant location access at ${path}: " +
                $_.Exception.Message)
        }
    }

    # Group Policy overrides the consent store outright, so a machine with this
    # set stays denied no matter what the toggles say.
    if ((Get-LocationValue -Path $LocationPolicyKey -Name 'DisableLocation') -eq 1) {
        try {
            New-ItemProperty -LiteralPath $LocationPolicyKey -Name 'DisableLocation' -Value 0 `
                -PropertyType DWord -Force -ErrorAction Stop | Out-Null
            $changed += @{ Path = $LocationPolicyKey; Name = 'DisableLocation'; Before = 1 }
        } catch {
            Write-Log -Level WARN -Message ("Couldn't clear the DisableLocation policy: " +
                $_.Exception.Message)
        }
    }

    if (@($changed).Count -gt 0) {
        Write-Log -Message ("Granted location access to the WLAN API for the connect " +
            "($(@($changed).Count) setting(s) changed, restored afterwards).")
    }
    return @{ Changes = $changed }
}

function Restore-LocationAccess {
    param($State)
    $changes = @($State.Changes)
    foreach ($change in $changes) {
        try {
            if ($null -eq $change.Before) {
                Remove-ItemProperty -LiteralPath $change.Path -Name $change.Name -ErrorAction Stop
            } else {
                Set-ItemProperty -LiteralPath $change.Path -Name $change.Name `
                    -Value $change.Before -ErrorAction Stop
            }
        } catch {
            Write-Log -Level WARN -Message ("Couldn't restore $($change.Name) under " +
                "$($change.Path), so it is still set for the connect: $($_.Exception.Message)")
        }
    }
    if ($changes.Count -gt 0) {
        Write-Log -Message 'Location settings put back the way they were found.'
    }
}

function Test-LocationDenied {
    <# The two things netsh says when the permission is what stopped it. #>
    param([string]$Text)
    return ($Text -match 'location permission' -or $Text -match 'WlanGetAvailableNetworkList')
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

<#
    Wait for the driver to land. Staying registered means giving up now costs
    nothing -- the next logon or restart tries again.

    The wait logs as it goes. It used to be silent, so a log holding a single
    "starting" line was indistinguishable from a hung script when it was in fact
    doing exactly what it was told to.
#>
$deadline = (Get-Date).AddMinutes($WaitMinutes)
$found = $false
$checks = 0
Write-Log "Waiting up to $WaitMinutes minute(s) for a wireless interface to appear."
while ((Get-Date) -lt $deadline) {
    $interfaces = & netsh.exe wlan show interfaces 2>&1
    if ($LASTEXITCODE -eq 0 -and ($interfaces -match 'Name\s*:')) { $found = $true; break }
    $checks++
    # Every fifth check, so a twenty-minute wait leaves four lines rather than forty.
    if ($checks % 5 -eq 0) {
        $left = [int]([Math]::Ceiling((($deadline - (Get-Date)).TotalMinutes)))
        Write-Log "Still no wireless interface; $left minute(s) left in this attempt."
    }
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

$location = Grant-LocationAccess
$joined = $false
$state = @()
$connectText = ''
try {
    $connect = & netsh.exe wlan connect name="$Ssid" 2>&1
    $connectText = (($connect | Where-Object { "$_".Trim() }) -join '; ')
    Write-Log "Connect requested: $connectText"

    for ($attempt = 0; $attempt -lt 15; $attempt++) {
        Start-Sleep -Seconds 2
        $state = & netsh.exe wlan show interfaces 2>&1
        $stateText = ($state -join ' ')
        if ($stateText -match 'State\s*:\s*connected' -and $stateText -match [regex]::Escape($Ssid)) {
            $joined = $true
            break
        }
    }
} finally {
    Restore-LocationAccess -State $location
}

if ($joined) {
    Write-Log -Level OK -Message "Connected to $Ssid."
} elseif (Test-LocationDenied $connectText) {
    <#
        Granting the permission is the fix, so reaching here means it could not be
        granted -- Group Policy owning Location services is the usual reason, and
        that is not something that changes between one logon and the next.

        Fall through to Remove-Self like every other outcome. Staying registered
        would look like a retry and would not be one: the run after this finds the
        profile already stored, takes the "nothing to do" exit at the top, and
        unregisters without ever reaching the connect.
    #>
    Write-Log -Level WARN -Message ('Stored the profile, but Windows refused the connect: the ' +
        'WLAN API needs location permission and it could not be granted, which usually means ' +
        'Group Policy owns Location services on this machine. The profile is saved, so ' +
        "Windows will join $Ssid by itself once that permission is available.")
} else {
    # The profile is stored either way, which is the part that matters: Windows
    # uses it by itself when the machine is next off Ethernet and in range.
    $current = (($state | Where-Object { "$_" -match 'State\s*:|SSID\s*:' }) -join '; ')
    Write-Log -Level WARN -Message ("Stored the profile but did not associate within 30s. " +
        "Adapter now: $current")
}

Remove-Self
exit 0
