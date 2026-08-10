<#
.SYNOPSIS
    ImageHub first-boot provisioning.

.DESCRIPTION
    Reads config.json (written by ImageHub when the USB drive was built) and
    applies the deployment template: network, naming, system configuration,
    debloat, optional features, applications, branding, encryption, and any
    custom scripts.

    Windows Setup stages this folder to C:\ImageHub during its specialize pass
    and the answer file runs this script at the IT admin account's first logon.
    Everything it does is logged to C:\ImageHub\logs.

    Run it by hand to re-apply a template to an already-installed machine:
        powershell -ExecutionPolicy Bypass -File C:\ImageHub\Provision.ps1

.NOTES
    This file is the shared contract between the macOS app and the Windows
    builder - both write the same config.json and ship this same script.
#>

[CmdletBinding()]
param(
    [string]$ConfigPath,
    # Skip the "press a key" pause at the end (used by automated runs).
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# ---------------------------------------------------------------------------
# Paths and logging
# ---------------------------------------------------------------------------

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ConfigPath) { $ConfigPath = Join-Path $Root 'config.json' }

$LogDirectory = Join-Path $Root 'logs'
New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
$LogFile = Join-Path $LogDirectory ("provision-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))

$script:Failures = @()
$script:Warnings = @()
# Counted so the finish screen can say what happened without anyone opening a log.
$script:AppsInstalled = 0
$script:AppsTotal = 0
$script:AccountCreated = ''

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'FAIL', 'STEP', 'OK')][string]$Level = 'INFO'
    )
    $line = "[{0:HH:mm:ss}] [{1}] {2}" -f (Get-Date), $Level, $Message
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    switch ($Level) {
        'STEP' { Write-Host ''; Write-Host $Message -ForegroundColor Cyan }
        'OK'   { Write-Host "  $Message" -ForegroundColor Green }
        'WARN' { Write-Host "  $Message" -ForegroundColor Yellow }
        'FAIL' { Write-Host "  $Message" -ForegroundColor Red }
        default { Write-Host "  $Message" -ForegroundColor Gray }
    }
}

<#
    Every step runs through this: one failing tweak must never abort the whole
    provisioning run, because a machine that is 90% configured and logged is far
    more useful to a technician than one that died on step three.
#>
function Invoke-Step {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action,
        [switch]$Critical
    )
    Write-Log -Level STEP -Message $Name
    $script:StepIndex++
    Set-Status -Step $Name
    try {
        & $Action
        return $true
    } catch {
        $message = "$Name failed: $($_.Exception.Message)"
        Write-Log -Level FAIL -Message $message
        if ($Critical) {
            $script:Failures += $message
        } else {
            $script:Warnings += $message
        }
        return $false
    }
}

function Set-RegistryValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [ValidateSet('DWord', 'QWord', 'String', 'ExpandString', 'MultiString', 'Binary')]
        [string]$Type = 'DWord'
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '  ImageHub provisioning' -ForegroundColor White
Write-Host '  ---------------------' -ForegroundColor DarkGray

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-Log -Level FAIL -Message "No config.json found at $ConfigPath. Nothing to do."
    exit 1
}

$Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
Write-Log "Template: $($Config.templateName)"
Write-Log "Built by: $($Config.generatedBy) at $($Config.generatedAt)"
Write-Log "Log file: $LogFile"

function Get-Setting {
    <# Tolerates config files written by an older ImageHub. #>
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

$System = Get-Setting $Config 'system'
$Admin = Get-Setting $Config 'admin'
$EndUser = Get-Setting $Config 'endUser'
$Identity = Get-Setting $Config 'identity'

# ---------------------------------------------------------------------------
# Progress screen
# ---------------------------------------------------------------------------

# Splash.ps1 runs as its own process and polls this file. Keeping it out of
# process matters: a single app install can take minutes, and a window sharing
# this thread would sit there greyed out as "Not Responding".
$StatusPath = Join-Path $Root 'status.json'
$script:StepIndex = 0
$script:StepTotal = 12
$script:SplashProcess = $null

function Resolve-AssetPath {
    param([string]$Relative)
    if (-not $Relative) { return '' }
    $staged = Join-Path 'C:\ProgramData\ImageHub\Assets' ([System.IO.Path]::GetFileName($Relative))
    if (Test-Path -LiteralPath $staged) { return $staged }
    $local = Join-Path $Root $Relative
    if (Test-Path -LiteralPath $local) { return $local }
    return ''
}

function Set-Status {
    param(
        [string]$Step,
        [string]$Detail = '',
        [ValidateSet('running', 'done', 'failed')][string]$State = 'running',
        [string]$Note = '',
        # Tells the progress screen to show its end-user account fields.
        [switch]$Prompting,
        # Seconds left before provisioning gives up waiting for those fields.
        [int]$PromptRemaining = 0,
        # Finish-screen lines: what happened, so the machine can be handed over
        # without opening a log.
        [string[]]$Summary = @()
    )
    try {
        [ordered]@{
            state            = $State
            step             = $Step
            detail           = $Detail
            prompting        = [bool]$Prompting
            promptRemaining  = $PromptRemaining
            summary          = @($Summary)
            index            = $script:StepIndex
            total            = $script:StepTotal
            organizationName = [string](Get-Setting $System 'organizationName' '')
            logo             = Resolve-AssetPath ([string](Get-Setting $System 'logo' ''))
            supportPhone     = [string](Get-Setting $System 'supportPhone' '')
            supportUrl       = [string](Get-Setting $System 'supportURL' '')
            failures         = @($script:Failures)
            warnings         = @($script:Warnings)
            note             = $Note
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $StatusPath -Encoding UTF8
    } catch {
        # The screen is a convenience; never let it interrupt provisioning.
    }
}

# Rough step count so the bar advances sensibly rather than sitting at zero.
$script:StepTotal = 12 + @(Get-Setting $Config 'apps' @()).Count `
    + @(Get-Setting $Config 'scripts' @()).Count
if ([string](Get-Setting (Get-Setting $System 'activation') 'mode' 'automatic') -ne 'skip') {
    $script:StepTotal++
}
# Both are their own step only when asked for, so the bar counts them the same way.
if ([int](Get-Setting $System 'screenLockMinutes' 0) -gt 0) { $script:StepTotal++ }
if (Get-Setting $System 'managePowerTimeouts' $false) { $script:StepTotal++ }

if (Get-Setting $System 'showProvisioningScreen' $true) {
    # The logo has to exist before the screen starts, so stage assets early.
    $logoRelative = [string](Get-Setting $System 'logo' '')
    if ($logoRelative) {
        try {
            New-Item -ItemType Directory -Path 'C:\ProgramData\ImageHub\Assets' -Force | Out-Null
            $logoSource = Join-Path $Root $logoRelative
            if (Test-Path -LiteralPath $logoSource) {
                Copy-Item -LiteralPath $logoSource -Destination 'C:\ProgramData\ImageHub\Assets' -Force
            }
        } catch { }
    }

    Set-Status -Step 'Starting setup...'
    $splash = Join-Path $Root 'Splash.ps1'
    if (Test-Path -LiteralPath $splash) {
        try {
            $script:SplashProcess = Start-Process -FilePath 'powershell.exe' -PassThru `
                -WindowStyle Hidden `
                -ArgumentList @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass',
                    '-File', "`"$splash`"", '-StatusPath', "`"$StatusPath`""
                )
            Write-Log "Progress screen started (PID $($script:SplashProcess.Id))."
        } catch {
            Write-Log -Level WARN -Message "Couldn't start the progress screen: $($_.Exception.Message)"
        }
    }
}

# Whether this run has the privileges it needs, stated up front. Half of what
# follows writes to HKLM or the default user hive, and without elevation those
# fail one by one with "Attempted to perform an unauthorized operation" -- which
# is exactly what happened to the Explorer defaults step on a real machine. This
# line existed once and was lost when the driver feature was removed; without it
# there is no way to tell a privilege problem from a bug.
$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
$script:IsElevated = $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($script:IsElevated) {
    Write-Log -Level OK -Message "Running elevated as $($identity.Identity.Name)."
} else {
    Write-Log -Level WARN -Message ("NOT elevated (running as $($identity.Identity.Name)). " +
        "Machine-wide settings and the default user profile will fail. " +
        "Launch.cmd normally registers an elevated scheduled task for this.")
    $script:Warnings += 'Provisioning ran without administrator rights, so machine-wide settings were skipped.'
}

# ---------------------------------------------------------------------------
# 1. Network - first, because everything else may need it
# ---------------------------------------------------------------------------

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

    It is granted for the length of the connect and then put back. Provisioning
    switches telemetry and consumer features off two steps later, and quietly
    leaving Location services on afterwards would undercut that -- an imaging
    tool should not be the reason a setting the operator never asked for is
    enabled. Association survives the restore: the permission gates apps calling
    the WLAN API, not the profile, and Wireless AutoConfig reconnects on its own
    afterwards.
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

<#
    Hands the Wi-Fi profile to a scheduled task for later.

    Needed because netsh cannot store a profile with no wireless interface
    present, and on a freshly imaged laptop the Wi-Fi driver typically arrives
    from Windows Update well after provisioning has finished. JoinWifi.ps1 waits
    for the interface, joins, and removes both the file and itself once it works.

    The profile XML carries the passphrase, so it is written DPAPI-protected under
    the machine key and with an ACL that admits only SYSTEM and Administrators.
    That is weaker than never writing it at all -- a local administrator can still
    unprotect it -- but it is the price of joining a network whose driver does not
    exist yet, and the file is deleted the moment the join succeeds.
#>
function Register-DeferredWifiJoin {
    param(
        [Parameter(Mandatory)][string]$Ssid,
        [Parameter(Mandatory)][string]$ProfileXml
    )

    $joinScript = Join-Path $Root 'JoinWifi.ps1'
    if (-not (Test-Path -LiteralPath $joinScript)) {
        Write-Log -Level WARN -Message "JoinWifi.ps1 is missing from $Root, so Wi-Fi cannot be deferred."
        return $false
    }

    try {
        $stateDirectory = 'C:\ProgramData\ImageHub'
        New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
        $blob = Join-Path $stateDirectory 'wifi.bin'

        Add-Type -AssemblyName System.Security -ErrorAction Stop
        $protected = [System.Security.Cryptography.ProtectedData]::Protect(
            [System.Text.Encoding]::UTF8.GetBytes($ProfileXml),
            $null,
            [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
        [System.IO.File]::WriteAllBytes($blob, $protected)

        # Well-known SIDs rather than names, which are localised.
        $acl = New-Object System.Security.AccessControl.FileSecurity
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
            $account = New-Object System.Security.Principal.SecurityIdentifier ($sid)
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                $account, 'FullControl', 'Allow')))
        }
        Set-Acl -LiteralPath $blob -AclObject $acl

        $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' +
                $joinScript + '" -Ssid "' + $Ssid + '"')
        # At logon and at startup: whichever comes first after the driver lands.
        $triggers = @((New-ScheduledTaskTrigger -AtLogOn), (New-ScheduledTaskTrigger -AtStartup))
        # LogonType ServiceAccount is required for SYSTEM; without it registration
        # asks for a password that does not exist.
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' `
            -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries -StartWhenAvailable `
            -ExecutionTimeLimit ([TimeSpan]::FromHours(1))

        Register-ScheduledTask -TaskName 'ImageHubJoinWifi' -Action $action -Trigger $triggers `
            -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null

        <#
            Start it now as well as registering it.

            Both triggers are already in the past by the time we get here: the task
            is created during provisioning, which is itself running at first logon,
            and the machine started well before that. So nothing would have fired
            until somebody next signed in or rebooted -- a machine could sit there
            all afternoon with the driver installed and the task waiting for an
            event that had already happened. Starting it means it begins its wait
            immediately, which is the window where Windows Update actually delivers
            the driver.
        #>
        try {
            Start-ScheduledTask -TaskName 'ImageHubJoinWifi' -ErrorAction Stop
            Write-Log -Level OK -Message ("Registered and started ImageHubJoinWifi; it will join " +
                "$Ssid as soon as a wireless interface exists, and again at the next logon or " +
                'restart if the driver takes longer than that.')
        } catch {
            Write-Log -Level OK -Message ("Registered ImageHubJoinWifi (couldn't start it now: " +
                "$($_.Exception.Message)); it will join $Ssid at the next logon or restart.")
        }
        return $true
    } catch {
        Write-Log -Level WARN -Message "Couldn't defer the Wi-Fi join: $($_.Exception.Message)"
        return $false
    }
}

$wifi = Get-Setting $System 'wifi'
if ((Get-Setting $wifi 'enabled' $false) -and (Get-Setting $wifi 'ssid')) {
    Invoke-Step "Adding Wi-Fi profile '$($wifi.ssid)'" {
        $ssid = $wifi.ssid
        $hexSSID = ($ssid.ToCharArray() | ForEach-Object { [int]$_ } | ForEach-Object { '{0:X2}' -f $_ }) -join ''
        $security = Get-Setting $wifi 'security' 'WPA2PSK'
        $password = Get-Setting $wifi 'password' ''

        if ($security -eq 'open') {
            $authentication = 'open'
            $encryption = 'none'
            $sharedKey = ''
        } else {
            $authentication = if ($security -eq 'WPA3SAE') { 'WPA3SAE' } else { 'WPA2PSK' }
            $encryption = 'AES'
            $sharedKey = @"
                <sharedKey>
                    <keyType>passPhrase</keyType>
                    <protected>false</protected>
                    <keyMaterial>$([System.Security.SecurityElement]::Escape($password))</keyMaterial>
                </sharedKey>
"@
        }

        $connectionMode = if (Get-Setting $wifi 'connectAutomatically' $true) { 'auto' } else { 'manual' }
        $nonBroadcast = if (Get-Setting $wifi 'hidden' $false) { 'true' } else { 'false' }

        $profileXml = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
    <name>$([System.Security.SecurityElement]::Escape($ssid))</name>
    <SSIDConfig>
        <SSID>
            <hex>$hexSSID</hex>
            <name>$([System.Security.SecurityElement]::Escape($ssid))</name>
        </SSID>
        <nonBroadcast>$nonBroadcast</nonBroadcast>
    </SSIDConfig>
    <connectionType>ESS</connectionType>
    <connectionMode>$connectionMode</connectionMode>
    <MSM>
        <security>
            <authEncryption>
                <authentication>$authentication</authentication>
                <encryption>$encryption</encryption>
                <useOneX>false</useOneX>
            </authEncryption>
$sharedKey
        </security>
    </MSM>
</WLANProfile>
"@
        <#
            Everything below used to end in "| Out-Null", so the step reported
            "profile added and connection requested" whether netsh had succeeded
            or refused outright -- and a run that never joined the network looked
            identical in the log to one that did. Keep the output, check it, and
            confirm the association rather than assuming it.
        #>
        <#
            netsh wlan cannot do anything at all without the Wireless AutoConfig
            service, and on a freshly imaged machine that has only ever been on
            Ethernet nothing has started it -- wlansvc ships demand-start. Three
            runs failed here with "The Wireless AutoConfig Service (wlansvc) is
            not running", which the old "| Out-Null" hid completely.
        #>
        try {
            $wlansvc = Get-Service -Name 'wlansvc' -ErrorAction Stop
            if ($wlansvc.StartType -ne 'Automatic') {
                Set-Service -Name 'wlansvc' -StartupType Automatic -ErrorAction Stop
            }
            if ($wlansvc.Status -ne 'Running') {
                Write-Log -Level INFO -Message 'Starting the Wireless AutoConfig service.'
                Start-Service -Name 'wlansvc' -ErrorAction Stop
                $wlansvc.WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
            }
            Write-Log -Level OK -Message 'Wireless AutoConfig is running.'
        } catch {
            throw ('The Wireless AutoConfig service could not be started, so no Wi-Fi ' +
                "profile can be stored: $($_.Exception.Message)")
        }

        <#
            Check for an interface BEFORE trying to store anything: netsh wlan
            refuses every operation when there is none, including "add profile",
            with "There is no wireless interface on the system."

            On a freshly imaged laptop that is usually not a missing adapter but a
            missing driver -- Windows has not fetched the Wi-Fi driver from Windows
            Update yet, and provisioning runs long before it does. Failing here
            would mean the profile never gets stored at all, so instead the work is
            handed to a scheduled task that waits for the interface to turn up.
        #>
        $interfaces = & netsh.exe wlan show interfaces 2>&1
        $hasInterface = ($LASTEXITCODE -eq 0) -and ($interfaces -match 'Name\s*:')

        if (-not $hasInterface) {
            $deferred = Register-DeferredWifiJoin -Ssid $ssid -ProfileXml $profileXml
            if ($deferred) {
                throw ("No wireless interface exists yet - usually the Wi-Fi driver has " +
                    "not arrived from Windows Update. $ssid will be joined automatically " +
                    'once it does; a scheduled task now waits for it. Nothing else to do.')
            }
            throw ('No wireless interface exists yet and the deferred join could not be ' +
                "registered, so $ssid was not configured.")
        }

        $profilePath = Join-Path $env:TEMP 'imagehub-wifi.xml'
        Set-Content -LiteralPath $profilePath -Value $profileXml -Encoding UTF8
        $added = & netsh.exe wlan add profile filename="$profilePath" user=all 2>&1
        Remove-Item -LiteralPath $profilePath -Force -ErrorAction SilentlyContinue
        $addedText = (($added | Where-Object { "$_".Trim() }) -join '; ')
        if ($LASTEXITCODE -ne 0) {
            throw "netsh refused the profile: $addedText"
        }
        Write-Log -Level OK -Message "Profile stored: $addedText"

        $location = Grant-LocationAccess
        $joined = $false
        $state = @()
        $connectText = ''
        try {
            $connect = & netsh.exe wlan connect name="$ssid" 2>&1
            $connectText = (($connect | Where-Object { "$_".Trim() }) -join '; ')
            Write-Log -Level INFO -Message "Connect requested: $connectText"

            <#
                Association takes a few seconds, and on a machine that is already on
                Ethernet Windows is in no hurry about it. Poll rather than declare
                victory: "State : connected" against our SSID is the only thing that
                actually means joined.
            #>
            for ($attempt = 0; $attempt -lt 15; $attempt++) {
                Start-Sleep -Seconds 2
                $state = & netsh.exe wlan show interfaces 2>&1
                $stateText = ($state -join ' ')
                if ($stateText -match 'State\s*:\s*connected' -and $stateText -match [regex]::Escape($ssid)) {
                    $joined = $true
                    break
                }
            }
        } finally {
            Restore-LocationAccess -State $location
        }

        if ($joined) {
            Write-Log -Level OK -Message "Connected to $ssid."
        } elseif (Test-LocationDenied $connectText) {
            <#
                Granting the permission is the fix, so reaching here means it could
                not be granted -- Group Policy owning Location services is the usual
                reason. Say that, rather than blaming Ethernet for it.
            #>
            throw ("Stored the profile for $ssid but Windows refused the connect: the WLAN " +
                'API needs location permission and it could not be granted, which usually ' +
                'means Group Policy owns Location services on this machine. The profile is ' +
                'saved and Windows will use it once the permission is available.')
        } else {
            $current = (($state | Where-Object { "$_" -match 'State\s*:|SSID\s*:' }) -join '; ')
            throw ("Stored the profile for $ssid but the adapter did not join within 30s. " +
                "Adapter now: $current. If this machine is on Ethernet, Windows may " +
                'simply not have bothered - the profile is saved and will be used when ' +
                'the cable comes out.')
        }
    }
}

function Wait-ForNetwork {
    param([int]$TimeoutSeconds = 90)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            if (Test-Connection -ComputerName 'www.msftconnecttest.com' -Count 1 -Quiet -ErrorAction Stop) {
                return $true
            }
        } catch { }
        Start-Sleep -Seconds 5
    }
    return $false
}

# ---------------------------------------------------------------------------
# 2. Machine name and workgroup
# ---------------------------------------------------------------------------

function Resolve-ComputerName {
    param([string]$Template)
    if ([string]::IsNullOrWhiteSpace($Template)) { return $null }

    $serial = ''
    $model = ''
    try {
        $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
        $serial = ($bios.SerialNumber -replace '[^A-Za-z0-9]', '')
        $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $model = ($computerSystem.Model -replace '[^A-Za-z0-9]', '')
    } catch {
        Write-Log -Level WARN -Message "Couldn't read BIOS details for the computer name: $($_.Exception.Message)"
    }

    $serial4 = if ($serial.Length -ge 4) { $serial.Substring($serial.Length - 4) } else { $serial }
    $templateSlug = ($Config.templateName -replace '[^A-Za-z0-9]', '')
    if ($templateSlug.Length -gt 8) { $templateSlug = $templateSlug.Substring(0, 8) }

    $name = $Template
    $name = $name -replace '%SERIAL4%', $serial4
    $name = $name -replace '%SERIAL%', $serial
    $name = $name -replace '%MODEL%', $model
    $name = $name -replace '%TEMPLATE%', $templateSlug
    $name = $name -replace '%RANDOM4%', ('{0:D4}' -f (Get-Random -Minimum 0 -Maximum 9999))

    # NetBIOS names: 15 characters, alphanumerics and hyphens only.
    $name = ($name -replace '[^A-Za-z0-9\-]', '')
    if ($name.Length -gt 15) { $name = $name.Substring(0, 15) }
    $name = $name.Trim('-')
    if ([string]::IsNullOrWhiteSpace($name)) { return $null }
    return $name.ToUpper()
}

$desiredName = Resolve-ComputerName (Get-Setting $System 'computerNameTemplate')
if ($desiredName -and $desiredName -ne $env:COMPUTERNAME) {
    Invoke-Step "Renaming this computer to $desiredName" {
        Rename-Computer -NewName $desiredName -Force -ErrorAction Stop
        Write-Log -Level OK -Message "Renamed to $desiredName (takes effect on the next restart)."
    }
}

$joinMode = Get-Setting $Identity 'joinMode' 'workgroup'
if ($joinMode -eq 'workgroup') {
    $workgroup = Get-Setting $Identity 'workgroup' 'WORKGROUP'
    if ($workgroup -and $workgroup -ne (Get-CimInstance Win32_ComputerSystem).Workgroup) {
        Invoke-Step "Setting workgroup to $workgroup" {
            Add-Computer -WorkGroupName $workgroup -Force -ErrorAction Stop
            Write-Log -Level OK -Message "Workgroup set to $workgroup."
        }
    }
}

# ---------------------------------------------------------------------------
# 3. Windows activation
# ---------------------------------------------------------------------------

$activation = Get-Setting $System 'activation'
$activationMode = [string](Get-Setting $activation 'mode' 'automatic')

<#
    Runs a program with a hard time limit and captures what it said.

    Everything expensive in this script is bounded -- installers, the network
    probe, the account prompt -- except, until now, the two things activation
    depends on. Provisioning stopped dead at "Activating Windows" on a machine
    with no name resolution: slmgr's /ato returned 0x80072EE7 and the licence
    status query that followed never came back. Reading
    SoftwareLicensingProduct makes the Software Protection service re-evaluate
    the licence, and on an offline machine that can block indefinitely.

    A child process can be killed. An in-process WMI call cannot, which is why
    the status query below runs out-of-process too.
#>
function Invoke-Bounded {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Arguments = '',
        [int]$TimeoutSeconds = 90
    )

    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $FilePath
    $info.Arguments = $Arguments
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    [void]$process.Start()

    # Start reading before waiting: a child that fills the pipe buffer blocks
    # forever if nobody is draining it, which would defeat the timeout.
    $out = $process.StandardOutput.ReadToEndAsync()
    $err = $process.StandardError.ReadToEndAsync()

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill() } catch { }
        return [pscustomobject]@{ TimedOut = $true; ExitCode = -1; Output = '' }
    }

    $text = ((($out.Result + "`n" + $err.Result) -split "`r?`n" |
        Where-Object { $_.Trim() }) -join '; ')
    return [pscustomobject]@{ TimedOut = $false; ExitCode = $process.ExitCode; Output = $text }
}

<#
    slmgr.vbs is the only supported way to install a key or trigger activation.
    Under wscript it reports through a message box, which on an unattended run
    means an invisible dialog nobody dismisses; cscript keeps everything on
    stdout so it reaches the log instead.
#>
function Invoke-Slmgr {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $line = '//Nologo "' + "$env:SystemRoot\System32\slmgr.vbs" + '" ' + ($Arguments -join ' ')
    $result = Invoke-Bounded -FilePath "$env:SystemRoot\System32\cscript.exe" `
        -Arguments $line -TimeoutSeconds 120
    if ($result.TimedOut) {
        Write-Log -Level WARN -Message ('slmgr ' + ($Arguments -join ' ') +
            ' did not return within 120s and was stopped.')
        return ''
    }
    # Logged here rather than at the call sites: Write-Log's -Message is a
    # mandatory string, and a silent slmgr run would fail the binding.
    if ($result.Output) { Write-Log -Level INFO -Message $result.Output }
    return $result.Output
}

<#
    Answers one question: is Windows licensed?

    It used to ask a subtly different one -- "what is the status of the first
    Windows SKU that has a product key?" -- and got it wrong on a machine that
    activated perfectly. SoftwareLicensingProduct holds an instance per SKU, and a
    machine that has had more than one key installed over its life has more than
    one carrying a PartialProductKey. Select-Object -First 1 then picks whichever
    WMI happens to return first, which on that run was a stale unlicensed entry:
    slmgr reported "Product activated successfully" and this reported status -1
    for two and a half minutes until the deadline gave up.

    Asking whether *any* keyed Windows SKU is licensed has no such ordering
    dependence. The child also prints a word rather than a number, so parsing
    cannot turn stray output into a plausible-looking status.

    Deliberately out-of-process and time-limited: see Invoke-Bounded.
#>
function Get-ActivationState {
    $probe = @'
try {
  $licensed = Get-CimInstance -ClassName SoftwareLicensingProduct -ErrorAction Stop |
    Where-Object {
      $_.ApplicationID -eq "55c92734-d682-4d71-983e-d6ec3f16059f" -and
      $_.PartialProductKey -and $_.LicenseStatus -eq 1
    }
  if ($licensed) { "LICENSED" } else { "NOTLICENSED" }
} catch { "UNREADABLE" }
'@
    # EncodedCommand sidesteps every layer of quoting between here and the child.
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($probe))
    $result = Invoke-Bounded `
        -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -Arguments "-NoProfile -EncodedCommand $encoded" -TimeoutSeconds 60

    if ($result.TimedOut) {
        Write-Log -Level WARN -Message ('Reading the licence status timed out. The Software ' +
            'Protection service is usually wedged on a machine with no internet.')
        return 'unreadable'
    }
    if ($result.Output -match 'LICENSED' -and $result.Output -notmatch 'NOTLICENSED') { return 'licensed' }
    if ($result.Output -match 'NOTLICENSED') { return 'notlicensed' }
    return 'unreadable'
}

if ($activationMode -eq 'skip') {
    Write-Log -Level INFO -Message 'Activation is set to leave-alone; not touching it.'
} else {
    Invoke-Step 'Activating Windows' {
        if ((Get-ActivationState) -eq 'licensed') {
            Write-Log -Level OK -Message 'Windows is already activated.'
            return
        }

        # Wait for the network, but do not refuse to try without it: the check is
        # an ICMP ping and plenty of corporate networks drop those while routing
        # HTTPS fine. slmgr's own error is more trustworthy than this probe.
        if (-not (Wait-ForNetwork -TimeoutSeconds 60)) {
            Write-Log -Level WARN -Message 'No ping response; trying activation anyway.'
        }

        if ($activationMode -eq 'kms') {
            $kmsHost = [string](Get-Setting $activation 'kmsHost' '')
            if ([string]::IsNullOrWhiteSpace($kmsHost)) {
                throw 'Activation is set to use a KMS host but no host was configured.'
            }
            Write-Log -Level INFO -Message "Pointing activation at KMS host $kmsHost."
            Invoke-Slmgr @('/skms', $kmsHost) | Out-Null
        } else {
            # The OEM key lives in the firmware's ACPI MSDM table. Reinstalling it
            # explicitly covers the case where the image was applied with a
            # different key already in place, which is the usual reason a machine
            # that shipped with Windows comes back unactivated.
            # Out-of-process and bounded for the same reason as the status read:
            # this is the same WMI provider, and it can block just as long.
            $oemKey = ''
            $keyScript = @'
try {
  (Get-CimInstance -ClassName SoftwareLicensingService -ErrorAction Stop).OA3xOriginalProductKey
} catch { "" }
'@
            $keyResult = Invoke-Bounded `
                -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
                -Arguments ('-NoProfile -EncodedCommand ' + [Convert]::ToBase64String(
                    [System.Text.Encoding]::Unicode.GetBytes($keyScript))) -TimeoutSeconds 60
            if ($keyResult.TimedOut) {
                Write-Log -Level WARN -Message 'Reading the firmware key timed out.'
            } else {
                # A product key is five groups of five, and nothing else on the line.
                $match = [regex]::Match($keyResult.Output, '[A-Z0-9]{5}(-[A-Z0-9]{5}){4}')
                if ($match.Success) { $oemKey = $match.Value }
            }

            if (-not [string]::IsNullOrWhiteSpace($oemKey)) {
                Write-Log -Level INFO -Message 'Installing the OEM key from this PC firmware.'
                Invoke-Slmgr @('/ipk', $oemKey) | Out-Null
            } else {
                Write-Log -Level INFO -Message 'No firmware key; relying on the digital licence.'
            }
        }

        $result = Invoke-Slmgr @('/ato')

        <#
            slmgr's own word first. It is the thing that performed the activation,
            so when it says the product activated there is nothing to poll for --
            and disbelieving it is exactly how a successful activation came to be
            reported as a failure.
        #>
        if ($result -match 'successfully') {
            Write-Log -Level OK -Message 'Windows is activated.'
            return
        }

        <#
            Otherwise poll, because /ato can return before the licence state
            settles -- but against a deadline, and abandoning the poll the moment
            the read stops answering, since asking again would only wait again.
        #>
        $deadline = (Get-Date).AddMinutes(2)
        $state = Get-ActivationState
        while ($state -eq 'notlicensed' -and (Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 5
            $state = Get-ActivationState
        }

        if ($state -eq 'licensed') {
            Write-Log -Level OK -Message 'Windows is activated.'
            return
        }

        # 0x80072EE7 is "the server name could not be resolved" -- no DNS, so no
        # internet. Worth naming, because it is not an activation problem and
        # Windows retries on its own schedule once the machine is online.
        if ($result -match '0x80072EE7|0x8007232B|0x80072EFD|0x800705B4') {
            throw ("This machine has no internet connection, so activation could not " +
                "reach Microsoft ($result). The key is installed; Windows will activate " +
                'itself once the machine is online. Plug in Ethernet or wait for Wi-Fi.')
        }

        throw "Windows is not activated ($state). $result"
    }
}

# ---------------------------------------------------------------------------
# 4. Regional and power settings
# ---------------------------------------------------------------------------

$timeZone = Get-Setting $System 'timeZone'
if ($timeZone) {
    Invoke-Step "Setting time zone to $timeZone" {
        & tzutil.exe /s "$timeZone"
        if ($LASTEXITCODE -ne 0) { throw "tzutil returned $LASTEXITCODE" }
        Write-Log -Level OK -Message "Time zone set."
    }
}

Invoke-Step 'Applying power settings' {
    $guid = Get-Setting $System 'powerPlanGUID'
    if ($guid) {
        & powercfg.exe /setactive $guid
        Write-Log -Level OK -Message "Power plan activated."
    }
    if (Get-Setting $System 'disableSleepOnAC' $true) {
        & powercfg.exe /change standby-timeout-ac 0
        & powercfg.exe /change monitor-timeout-ac 20
        & powercfg.exe /change disk-timeout-ac 0
        Write-Log -Level OK -Message "Sleep disabled on mains power."
    }
    if (Get-Setting $System 'disableHibernation' $false) {
        & powercfg.exe /hibernate off
        Write-Log -Level OK -Message "Hibernation off (hiberfil.sys reclaimed)."
    }
    if (Get-Setting $System 'disableFastStartup' $false) {
        Set-RegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
            -Name 'HiberbootEnabled' -Value 0
        Write-Log -Level OK -Message "Fast startup disabled."
    }
}

<#
    Screen lock and the display/sleep/lid timeouts, both written as machine
    policy and deliberately not through powercfg.

    Power schemes are per-user. powercfg here would configure ITAdmin -- an
    account that is often hidden straight afterwards and never signed into again
    -- and leave the person who actually receives the machine on Windows'
    defaults. The Power Management keys under HKLM\SOFTWARE\Policies are what
    Group Policy itself writes: one place, every account, and they take
    precedence over whatever scheme a user later picks.

    The same reasoning puts the lock on InactivityTimeoutSecs, which is HKLM, and
    not on the per-user screensaver values.
#>
function Get-PowerSettingGuid {
    <#
        Asks powercfg which GUID sits behind an alias instead of hardcoding it.
        The display and sleep GUIDs are easy to confirm; the lid one is quoted
        more often than it is sourced, and the machine holds the authoritative
        answer either way.
    #>
    param([Parameter(Mandatory)][string]$Alias)
    foreach ($line in (& powercfg.exe /aliases 2>&1)) {
        if ("$line".Trim() -match '^([0-9a-fA-F-]{36})\s+(\S+)$' -and $Matches[2] -eq $Alias) {
            return $Matches[1]
        }
    }
    return $null
}

function Set-PowerSettingPolicy {
    param(
        [Parameter(Mandatory)][string]$Alias,
        [Parameter(Mandatory)][int]$AC,
        [Parameter(Mandatory)][int]$DC,
        [Parameter(Mandatory)][string]$What
    )
    $guid = Get-PowerSettingGuid -Alias $Alias
    if (-not $guid) {
        Write-Log -Level WARN -Message ("powercfg does not list a $Alias setting on this " +
            "build, so $What was left alone.")
        return $false
    }
    $path = "HKLM:\SOFTWARE\Policies\Microsoft\Power\PowerSettings\$guid"
    Set-RegistryValue -Path $path -Name 'ACSettingIndex' -Value $AC
    Set-RegistryValue -Path $path -Name 'DCSettingIndex' -Value $DC
    return $true
}

$screenLockMinutes = [int](Get-Setting $System 'screenLockMinutes' 0)
if ($screenLockMinutes -gt 0) {
    Invoke-Step "Locking the screen after $screenLockMinutes minute(s) of inactivity" {
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
            -Name 'InactivityTimeoutSecs' -Value ($screenLockMinutes * 60)
        Write-Log -Level OK -Message 'Machine inactivity limit set; it covers every account.'
    }
}

if (Get-Setting $System 'managePowerTimeouts' $false) {
    Invoke-Step 'Applying display, sleep and lid policy' {
        # Windows stores these timeouts in seconds; the template speaks minutes.
        $displayAC = [int](Get-Setting $System 'displayOffMinutesAC' 15) * 60
        $displayDC = [int](Get-Setting $System 'displayOffMinutesDC' 5) * 60
        $sleepAC = [int](Get-Setting $System 'sleepMinutesAC' 0) * 60
        $sleepDC = [int](Get-Setting $System 'sleepMinutesDC' 30) * 60
        # Lid actions are an enumeration, not a duration, so they pass through.
        $lidAC = [int](Get-Setting $System 'lidCloseActionAC' 1)
        $lidDC = [int](Get-Setting $System 'lidCloseActionDC' 1)

        $set = 0
        if (Set-PowerSettingPolicy -Alias 'VIDEOIDLE' -AC $displayAC -DC $displayDC `
                -What 'the display timeout') { $set++ }
        if (Set-PowerSettingPolicy -Alias 'STANDBYIDLE' -AC $sleepAC -DC $sleepDC `
                -What 'the sleep timeout') { $set++ }
        if (Set-PowerSettingPolicy -Alias 'LIDACTION' -AC $lidAC -DC $lidDC `
                -What 'the lid close action') { $set++ }

        if ($set -eq 0) {
            throw 'None of the power settings could be resolved, so nothing was applied.'
        }
        Write-Log -Level OK -Message ("Power policy applied for every account " +
            "($set of 3 setting(s)).")
    }
}

# ---------------------------------------------------------------------------
# 5. Remote access
# ---------------------------------------------------------------------------

if (Get-Setting $System 'enableRemoteDesktop' $false) {
    Invoke-Step 'Enabling Remote Desktop' {
        Set-RegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' `
            -Name 'fDenyTSConnections' -Value 0
        Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue
        Write-Log -Level OK -Message "Remote Desktop enabled and the firewall rule opened."
    }
}

if (Get-Setting $System 'allowPing' $false) {
    Invoke-Step 'Allowing inbound ping' {
        Enable-NetFirewallRule -Name 'CoreNet-ICMP4-DUFRAG-In' -ErrorAction SilentlyContinue
        New-NetFirewallRule -DisplayName 'ImageHub - Allow ICMPv4 Echo' -Direction Inbound `
            -Protocol ICMPv4 -IcmpType 8 -Action Allow -ErrorAction SilentlyContinue | Out-Null
        Write-Log -Level OK -Message "ICMP echo allowed."
    }
}

# ---------------------------------------------------------------------------
# 6. Desktop defaults - written into the default user hive so every account
#    created from here on inherits them
# ---------------------------------------------------------------------------

Invoke-Step 'Applying Explorer and shell defaults' {
    $defaultHive = 'C:\Users\Default\NTUSER.DAT'
    $loaded = $false
    if (Test-Path -LiteralPath $defaultHive) {
        & reg.exe load 'HKU\ImageHubDefault' $defaultHive 2>$null | Out-Null
        $loaded = ($LASTEXITCODE -eq 0)
    }

    # Apply to the current user and, when the hive loaded, to the template
    # profile future users are cloned from.
    $targets = @('HKCU:')
    if ($loaded) { $targets += 'Registry::HKU\ImageHubDefault' }

    <#
        Each value is attempted on its own. The whole step used to be one
        try-block, so the first refusal threw and every remaining tweak was
        skipped -- one unwritable key silently cost the machine all of its shell
        defaults. Collect the failures and report them instead.
    #>
    function Set-ShellValue {
        param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
        try {
            Set-RegistryValue -Path $Path -Name $Name -Value $Value -Type $Type
            $script:ShellApplied++
        } catch {
            $script:ShellRefused += "$Name at $Path ($($_.Exception.Message))"
        }
    }
    $script:ShellApplied = 0
    $script:ShellRefused = @()

    try {
        foreach ($base in $targets) {
            $advanced = "$base\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
            if (Get-Setting $System 'showFileExtensions' $true) {
                Set-ShellValue $advanced 'HideFileExt' 0
            }
            if (Get-Setting $System 'showHiddenFiles' $false) {
                Set-ShellValue $advanced 'Hidden' 1
            }
            if (Get-Setting $System 'taskbarAlignLeft' $false) {
                Set-ShellValue $advanced 'TaskbarAl' 0
            }
            # TaskbarDa is not the way to do this any more. Windows 11 25H2
            # protects the value, so both writes came back "Attempted to perform
            # an unauthorized operation" -- the machine policy below is the
            # supported route and is applied once, outside this per-hive loop.
            if (Get-Setting $System 'classicContextMenu' $false) {
                $clsid = "$base\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32"
                Set-ShellValue $clsid '(Default)' '' 'String'
            }
        }

        <#
            DisableSearchBoxSuggestions is a *policy* value, and HKCU\Software\
            Policies is read-only to the logged-on user however elevated the
            process is -- writing it threw "Attempted to perform an unauthorized
            operation" and took the rest of this step down with it. The machine
            hive is the correct place for it and covers every account anyway.
        #>
        if (Get-Setting $System 'disableWebSearch' $false) {
            Set-ShellValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' `
                'DisableSearchBoxSuggestions' 1
            if ($loaded) {
                Set-ShellValue 'Registry::HKU\ImageHubDefault\Software\Policies\Microsoft\Windows\Explorer' `
                    'DisableSearchBoxSuggestions' 1
            }
        }

        # Widgets: the machine policy, which is what Microsoft documents and what
        # actually takes. It covers every account, so it is written once.
        if (Get-Setting $System 'disableWidgets' $false) {
            Set-ShellValue 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
        }

        $applied = $script:ShellApplied
        $refused = @($script:ShellRefused)
        if ($refused.Count -gt 0) {
            Write-Log -Level WARN -Message ("Shell defaults: $applied value(s) applied, " +
                "$($refused.Count) refused - " + ($refused -join '; '))
        } else {
            Write-Log -Level OK -Message ("Shell defaults applied to the current and " +
                "default profiles ($applied value(s)).")
        }
    } finally {
        <#
            reg unload is refused while PowerShell still holds a handle on the
            hive we just wrote to, and the refusal used to escape this finally
            block -- turning a step that had done its job into
            "Applying Explorer and shell defaults failed: ERROR: Access is
            denied." on top of the warning it had already logged correctly.

            cmd.exe swallows reg's stderr so it cannot become a PowerShell error
            record, the collect-and-retry gives the handles time to go, and a
            hive that still will not unload is a warning, never a failure.
        #>
        if ($loaded) {
            $unloaded = $false
            $unloadOutput = ''
            for ($attempt = 1; $attempt -le 5; $attempt++) {
                [gc]::Collect()
                [gc]::WaitForPendingFinalizers()
                $unloadOutput = & cmd.exe /c 'reg.exe unload HKU\ImageHubDefault 2>&1'
                if ($LASTEXITCODE -eq 0) { $unloaded = $true; break }
                Start-Sleep -Milliseconds 400
            }
            if (-not $unloaded) {
                Write-Log -Level WARN -Message ('Left the default user hive loaded: ' +
                    "$unloadOutput. It unloads by itself at the next restart.")
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 7. Telemetry and consumer features
# ---------------------------------------------------------------------------

if (Get-Setting $System 'disableTelemetry' $true) {
    Invoke-Step 'Turning off telemetry and diagnostic data' {
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' `
            -Name 'AllowTelemetry' -Value 0
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' `
            -Name 'AllowTelemetry' -Value 0
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' `
            -Name 'DisabledByGroupPolicy' -Value 1
        foreach ($task in @(
            'Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
            'Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
            'Microsoft\Windows\Customer Experience Improvement Program\UsbCeip'
        )) {
            Disable-ScheduledTask -TaskName (Split-Path $task -Leaf) `
                -TaskPath ('\' + (Split-Path $task -Parent) + '\') -ErrorAction SilentlyContinue | Out-Null
        }
        Write-Log -Level OK -Message "Telemetry policies set."
    }
}

if (Get-Setting $System 'disableConsumerFeatures' $true) {
    Invoke-Step 'Turning off consumer features and suggested apps' {
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' `
            -Name 'DisableWindowsConsumerFeatures' -Value 1
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' `
            -Name 'DisableConsumerAccountStateContent' -Value 1
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' `
            -Name 'AutoDownload' -Value 2
        Write-Log -Level OK -Message "Consumer content policies set."
    }
}

# ---------------------------------------------------------------------------
# 8. Debloat
# ---------------------------------------------------------------------------

$bloatware = @(Get-Setting $System 'bloatware' @())
if ((Get-Setting $System 'removeBloatware' $true) -and $bloatware.Count -gt 0) {
    Invoke-Step "Removing $($bloatware.Count) preinstalled packages" {
        $removed = 0
        foreach ($package in $bloatware) {
            try {
                $installed = Get-AppxPackage -AllUsers -Name $package -ErrorAction SilentlyContinue
                if ($installed) {
                    $installed | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
                    $removed++
                }
                # Also drop the provisioned copy so new profiles don't get it back.
                Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                    Where-Object { $_.DisplayName -eq $package } |
                    ForEach-Object {
                        Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName `
                            -ErrorAction SilentlyContinue | Out-Null
                    }
            } catch {
                Write-Log -Level WARN -Message "Couldn't remove ${package}: $($_.Exception.Message)"
            }
        }
        Write-Log -Level OK -Message "Removed $removed installed package(s) and cleared their provisioned copies."
    }
}

# ---------------------------------------------------------------------------
# 9. Optional Windows features
# ---------------------------------------------------------------------------

$features = @(Get-Setting $System 'optionalFeatures' @())
if ($features.Count -gt 0) {
    Invoke-Step "Enabling $($features.Count) optional feature(s)" {
        foreach ($feature in $features) {
            try {
                Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart `
                    -ErrorAction Stop | Out-Null
                Write-Log -Level OK -Message "Enabled $feature."
            } catch {
                Write-Log -Level WARN -Message "Couldn't enable ${feature}: $($_.Exception.Message)"
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 10. Applications
# ---------------------------------------------------------------------------

function Resolve-Winget {
    $command = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    # winget lives under WindowsApps and isn't always on SYSTEM's PATH yet.
    $candidate = Get-ChildItem -Path "$env:ProgramFiles\WindowsApps" -Filter 'winget.exe' `
        -Recurse -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1
    if ($candidate) { return $candidate.FullName }

    # Try to register App Installer if it's present but not registered.
    try {
        Get-AppxPackage -AllUsers -Name 'Microsoft.DesktopAppInstaller' -ErrorAction Stop |
            ForEach-Object {
                Add-AppxPackage -DisableDevelopmentMode -Register `
                    "$($_.InstallLocation)\AppXManifest.xml" -ErrorAction SilentlyContinue
            }
        $command = Get-Command winget.exe -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
    } catch { }

    return $null
}

$apps = @(Get-Setting $Config 'apps' @())
if ($apps.Count -gt 0) {
    $needsWinget = @($apps | Where-Object { $_.source -eq 'winget' }).Count -gt 0
    $winget = $null

    if ($needsWinget) {
        Write-Log -Level STEP -Message 'Preparing winget'
        if (-not (Wait-ForNetwork -TimeoutSeconds 90)) {
            Write-Log -Level WARN -Message 'No internet connection detected - winget installs will probably fail.'
            $script:Warnings += 'No internet connection was available for winget installs.'
        }
        $winget = Resolve-Winget
        if ($winget) {
            Write-Log -Level OK -Message "Using $winget"
            & $winget source update --disable-interactivity 2>&1 | Out-Null
        } else {
            Write-Log -Level FAIL -Message 'winget could not be found on this machine.'
            $script:Warnings += 'winget was unavailable, so winget-sourced apps were skipped.'
        }
    }

    Write-Log -Level STEP -Message "Installing $($apps.Count) application(s)"
    $script:AppsTotal = $apps.Count
    $appNumber = 0
    foreach ($app in $apps) {
        $name = Get-Setting $app 'name' 'Unnamed app'
        $source = Get-Setting $app 'source' 'winget'
        $required = Get-Setting $app 'required' $false

        $appNumber++
        $script:StepIndex++
        Set-Status -Step "Installing applications ($appNumber of $($apps.Count))" -Detail $name

        try {
            switch ($source) {
                'winget' {
                    if (-not $winget) { throw 'winget is not available.' }
                    $packageID = [string](Get-Setting $app 'packageID')
                    # --source winget: catalog IDs are winget IDs, and leaving the
                    # source open lets the Microsoft Store copy of the same app
                    # (Slack has one) join the match and muddy the result.
                    $arguments = @(
                        'install', '--id', $packageID,
                        '--exact', '--silent', '--source', 'winget',
                        '--accept-package-agreements', '--accept-source-agreements',
                        '--disable-interactivity'
                    )
                    $version = [string](Get-Setting $app 'version' '')
                    if ($version) { $arguments += @('--version', $version) }

                    # The exact command, so a failure can be reproduced by hand
                    # and a stray pinned version is visible rather than inferred.
                    Write-Log "Installing $name via winget: winget $($arguments -join ' ')"
                    $output = & $winget @arguments 2>&1
                    $output | ForEach-Object { Add-Content -LiteralPath $LogFile -Value "      $_" }

                    <#
                        A pinned version that no longer exists in the catalog fails
                        with the same "No package found matching input criteria" as a
                        wrong ID, which is thoroughly misleading -- it sends you
                        hunting for a package that was there all along. If a version
                        was pinned, drop it and try once more for the latest.
                    #>
                    if ($LASTEXITCODE -eq -1978335212 -and $version) {
                        Write-Log -Level WARN -Message ("$name version $version was not found. " +
                            'Retrying without the version pin.')
                        $arguments = @(
                            'install', '--id', $packageID,
                            '--exact', '--silent', '--source', 'winget',
                            '--accept-package-agreements', '--accept-source-agreements',
                            '--disable-interactivity'
                        )
                        $output = & $winget @arguments 2>&1
                        $output | ForEach-Object { Add-Content -LiteralPath $LogFile -Value "      $_" }
                    }

                    <#
                        winget uses 0 for success, and two more codes that also mean
                        the machine ends up with the app -- which is the only thing
                        this step is trying to achieve:

                          -1978335135 / 0x8A150061  already installed, nothing tried
                          -1978335189 / 0x8A15002B  already installed, nothing newer

                        The second is what anything Windows 11 preinstalls returns.
                        A real run logged "[FAIL] OneDrive did not install: winget
                        exited with -1978335189 - Found an existing package already
                        installed [...] No newer package versions are available",
                        which is a machine in exactly the wanted state being called
                        a failure. winget only reports it after finding an existing
                        install, so it can never mean the app is absent.
                    #>
                    $alreadyPresent = @(-1978335135, -1978335189)
                    if ($LASTEXITCODE -ne 0 -and $alreadyPresent -notcontains $LASTEXITCODE) {
                        # The exit code alone says nothing useful. winget's own last
                        # lines usually name the reason outright -- an unaccepted
                        # agreement, no applicable installer for this architecture,
                        # a hash mismatch, a network failure -- so surface them
                        # instead of making someone open the log to find out.
                        $reason = @($output | Where-Object { "$_".Trim() } | Select-Object -Last 3)
                        $detail = if ($reason) { ' - ' + ($reason -join ' / ') } else { '' }

                        <#
                            "No package found matching input criteria" with no
                            version pinned means the ID really is wrong. Guessing the
                            right one from a Mac with no winget on it has already
                            failed, so ask winget: search by display name and log the
                            candidate IDs. The next log then contains the answer.
                        #>
                        if ($LASTEXITCODE -eq -1978335212) {
                            try {
                                $found = & $winget search --name $name --source winget `
                                    --accept-source-agreements 2>&1
                                Write-Log -Level WARN -Message ("No winget package '" +
                                    "$packageID'. Searching for '$name' instead:")
                                $found | Select-Object -First 12 | ForEach-Object {
                                    Add-Content -LiteralPath $LogFile -Value "      $_"
                                }
                            } catch {
                                Write-Log -Level WARN -Message "winget search also failed: $($_.Exception.Message)"
                            }
                        }

                        throw "winget exited with $LASTEXITCODE$detail"
                    }
                    # Distinguished rather than both logged as "installed": a run
                    # that changed nothing should not read like one that did.
                    if ($alreadyPresent -contains $LASTEXITCODE) {
                        Write-Log -Level OK -Message "$name is already installed and up to date."
                    } else {
                        Write-Log -Level OK -Message "$name installed."
                    }
                }
                'installer' {
                    $relative = Get-Setting $app 'installer'
                    if (-not $relative) { throw 'No installer path in the config.' }
                    $installer = Join-Path $Root $relative
                    if (-not (Test-Path -LiteralPath $installer)) {
                        throw "Installer missing at $installer"
                    }
                    $silentArgs = Get-Setting $app 'silentArgs' ''
                    Write-Log "Running $([System.IO.Path]::GetFileName($installer)) $silentArgs..."

                    # No -Wait: a wrong silent switch makes an installer show a
                    # GUI error dialog and sit there. On a real run Sophos rejected
                    # '/S' with "Non-option passed: /S", put up a modal, and the
                    # whole provisioning run stopped dead with no timeout. Poll
                    # instead and kill it if it outstays the budget.
                    $timeoutMinutes = [int](Get-Setting $app 'timeoutMinutes' 30)
                    if ([System.IO.Path]::GetExtension($installer) -ieq '.msi') {
                        $msiArgs = @('/i', "`"$installer`"")
                        if ($silentArgs) { $msiArgs += $silentArgs.Split(' ') } else { $msiArgs += '/qn' }
                        $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -PassThru
                    } elseif ($silentArgs) {
                        $process = Start-Process -FilePath $installer -ArgumentList $silentArgs -PassThru
                    } else {
                        $process = Start-Process -FilePath $installer -PassThru
                    }

                    if (-not $process.WaitForExit($timeoutMinutes * 60 * 1000)) {
                        try { $process.Kill($true) } catch { try { $process.Kill() } catch {} }
                        throw ("No response after $timeoutMinutes minutes, so it was stopped. " +
                            "A silent-install switch that the installer rejects will show a dialog " +
                            "and wait forever - check the arguments for this app.")
                    }
                    $process.Refresh()

                    # 3010 means "success, needs a reboot" - not a failure.
                    if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
                        throw "Installer exited with $($process.ExitCode)"
                    }
                    Write-Log -Level OK -Message "$name installed."
                }
                'script' {
                    $body = Get-Setting $app 'script' ''
                    if (-not $body) { throw 'Script body is empty.' }
                    Write-Log "Running the PowerShell step for $name..."
                    & ([scriptblock]::Create($body))
                    Write-Log -Level OK -Message "$name completed."
                }
                default { throw "Unknown app source '$source'." }
            }
            $script:AppsInstalled++
        } catch {
            $message = "$name did not install: $($_.Exception.Message)"
            Write-Log -Level FAIL -Message $message
            if ($required) { $script:Failures += $message } else { $script:Warnings += $message }
        }
    }
}

# ---------------------------------------------------------------------------
# 11. Microsoft 365 through the Office Deployment Tool
# ---------------------------------------------------------------------------

<#
    winget's Microsoft.Office package fails on nearly every run with "Installer
    hash does not match; this cannot be overridden when running as admin" -- winget
    pins a hash, Microsoft ships a new installer behind the same URL, and the
    manifest is stale more often than not. Nothing on this side can fix that.

    The ODT is Microsoft's own supported path. ImageHub bundles the operator's
    setup.exe and generates configuration.xml at build time, so all this step has
    to do is run it and interpret the result.
#>

$office = Get-Setting $Config 'microsoft365'
if ([bool](Get-Setting $office 'enabled' $false)) {
    $script:StepTotal++
    Invoke-Step 'Installing Microsoft 365' {
        $setup = Join-Path $Root ([string](Get-Setting $office 'setup' ''))
        $configuration = Join-Path $Root ([string](Get-Setting $office 'configuration' ''))

        if (-not (Test-Path -LiteralPath $setup)) {
            throw "The Office Deployment Tool is missing from the payload: $setup"
        }
        if (-not (Test-Path -LiteralPath $configuration)) {
            throw "The Office configuration is missing from the payload: $configuration"
        }

        # Office comes down from Microsoft's CDN, so no network means no install.
        # Say that plainly rather than letting setup.exe fail with a bare code.
        if (-not (Wait-ForNetwork -TimeoutSeconds 60)) {
            Write-Log -Level WARN -Message 'No ping response; attempting the Office install anyway.'
        }

        $timeoutMinutes = [int](Get-Setting $office 'timeoutMinutes' 90)
        if ($timeoutMinutes -lt 5) { $timeoutMinutes = 90 }
        Write-Log -Level INFO -Message ('Installing Microsoft 365 with the Office Deployment ' +
            "Tool. This downloads several GB and may take a while (limit $timeoutMinutes minutes).")

        $result = Invoke-Bounded -FilePath $setup `
            -Arguments ('/configure "' + $configuration + '"') `
            -TimeoutSeconds ($timeoutMinutes * 60)

        if ($result.TimedOut) {
            throw "The Office install did not finish within $timeoutMinutes minutes and was stopped."
        }
        if ($result.Output) { Write-Log -Level INFO -Message $result.Output }

        <#
            setup.exe returns 0 on success and 1 for "a restart is needed", which is
            not a failure. 17002 is the ODT's "the install was cancelled or another
            Click-to-Run operation is in progress" -- worth naming because an OEM
            trial mid-uninstall causes it and a retry usually succeeds.
        #>
        if ($result.ExitCode -eq 0 -or $result.ExitCode -eq 1) {
            Write-Log -Level OK -Message 'Microsoft 365 installed.'
        } elseif ($result.ExitCode -eq 17002) {
            throw ('Another Click-to-Run operation was already in progress, so Office did ' +
                'not install. A preinstalled Office trial being removed is the usual cause; ' +
                'running the step again once it settles normally works.')
        } else {
            throw "The Office Deployment Tool exited with $($result.ExitCode)."
        }
    }
}

# ---------------------------------------------------------------------------
# 12. Branding
# ---------------------------------------------------------------------------

$wallpaper = Get-Setting $System 'wallpaper' ''
$lockScreen = Get-Setting $System 'lockScreen' ''
if ($wallpaper -or $lockScreen) {
    Invoke-Step 'Applying wallpaper and lock screen' {
        $assetDirectory = 'C:\ProgramData\ImageHub\Assets'
        New-Item -ItemType Directory -Path $assetDirectory -Force | Out-Null
        $policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization'

        if ($wallpaper) {
            $source = Join-Path $Root $wallpaper
            if (Test-Path -LiteralPath $source) {
                $target = Join-Path $assetDirectory ([System.IO.Path]::GetFileName($source))
                Copy-Item -LiteralPath $source -Destination $target -Force
                # Policy value applies to every user; the HKCU pair updates the
                # session that's running right now.
                Set-RegistryValue -Path $policy -Name 'DesktopImagePath' -Value $target -Type String
                Set-RegistryValue -Path $policy -Name 'DesktopImageUrl' -Value $target -Type String
                Set-RegistryValue -Path $policy -Name 'DesktopImageStatus' -Value 1
                Set-RegistryValue -Path 'HKCU:\Control Panel\Desktop' -Name 'Wallpaper' `
                    -Value $target -Type String
                & rundll32.exe 'user32.dll,UpdatePerUserSystemParameters'
                Write-Log -Level OK -Message "Wallpaper set to $target."
            } else {
                Write-Log -Level WARN -Message "Wallpaper asset missing: $source"
            }
        }

        if ($lockScreen) {
            $source = Join-Path $Root $lockScreen
            if (Test-Path -LiteralPath $source) {
                $target = Join-Path $assetDirectory ([System.IO.Path]::GetFileName($source))
                Copy-Item -LiteralPath $source -Destination $target -Force
                Set-RegistryValue -Path $policy -Name 'LockScreenImage' -Value $target -Type String
                Write-Log -Level OK -Message "Lock screen set to $target."
            } else {
                Write-Log -Level WARN -Message "Lock screen asset missing: $source"
            }
        }
    }
}

$organization = Get-Setting $System 'organizationName' ''
if ($organization -or (Get-Setting $System 'supportPhone' '') -or (Get-Setting $System 'supportURL' '')) {
    Invoke-Step 'Writing OEM support information' {
        # Shows up in Settings -> About and the classic System control panel.
        $oem = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation'
        if ($organization) {
            Set-RegistryValue -Path $oem -Name 'Manufacturer' -Value $organization -Type String
        }
        $phone = Get-Setting $System 'supportPhone' ''
        if ($phone) {
            Set-RegistryValue -Path $oem -Name 'SupportPhone' -Value $phone -Type String
        }
        $url = Get-Setting $System 'supportURL' ''
        if ($url) {
            Set-RegistryValue -Path $oem -Name 'SupportURL' -Value $url -Type String
        }

        $logoRelativePath = [string](Get-Setting $System 'logo' '')
        if ($logoRelativePath) {
            $source = Join-Path $Root $logoRelativePath
            if (Test-Path -LiteralPath $source) {
                New-Item -ItemType Directory -Path 'C:\ProgramData\ImageHub\Assets' -Force | Out-Null
                $target = Join-Path 'C:\ProgramData\ImageHub\Assets' ([System.IO.Path]::GetFileName($source))
                Copy-Item -LiteralPath $source -Destination $target -Force
                # Settings -> About wants a bitmap; anything else is ignored
                # silently, so convert rather than hope.
                try {
                    Add-Type -AssemblyName System.Drawing
                    $bitmapPath = [System.IO.Path]::ChangeExtension($target, '.bmp')
                    $image = [System.Drawing.Image]::FromFile($target)
                    try {
                        $image.Save($bitmapPath, [System.Drawing.Imaging.ImageFormat]::Bmp)
                    } finally {
                        $image.Dispose()
                    }
                    Set-RegistryValue -Path $oem -Name 'Logo' -Value $bitmapPath -Type String
                } catch {
                    Write-Log -Level WARN -Message "Couldn't convert the logo to a bitmap: $($_.Exception.Message)"
                }
            }
        }
        Write-Log -Level OK -Message "OEM information written."
    }
}

$startLayout = Get-Setting $System 'startLayout' ''
if ($startLayout) {
    Invoke-Step 'Applying the Start menu layout' {
        $source = Join-Path $Root $startLayout
        if (-not (Test-Path -LiteralPath $source)) { throw "Layout file missing at $source" }
        $target = 'C:\Users\Default\AppData\Local\Microsoft\Windows\Shell\LayoutModification.json'
        New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $target -Force
        Write-Log -Level OK -Message "Start layout staged for new profiles."
    }
}

# ---------------------------------------------------------------------------
# 13. Windows Update policy
# ---------------------------------------------------------------------------

Invoke-Step 'Applying the Windows Update policy' {
    $policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    switch (Get-Setting $System 'windowsUpdate' 'automatic') {
        'notifyBeforeDownload' {
            Set-RegistryValue -Path $policy -Name 'NoAutoUpdate' -Value 0
            Set-RegistryValue -Path $policy -Name 'AUOptions' -Value 2
        }
        'disableAutomaticRestart' {
            Set-RegistryValue -Path $policy -Name 'NoAutoUpdate' -Value 0
            Set-RegistryValue -Path $policy -Name 'AUOptions' -Value 4
            Set-RegistryValue -Path $policy -Name 'NoAutoRebootWithLoggedOnUsers' -Value 1
        }
        default {
            Set-RegistryValue -Path $policy -Name 'NoAutoUpdate' -Value 0
            Set-RegistryValue -Path $policy -Name 'AUOptions' -Value 4
        }
    }
    Write-Log -Level OK -Message "Update policy applied."
}

if (Get-Setting $System 'installUpdates' $false) {
    Invoke-Step 'Installing available Windows updates (this can take a while)' {
        if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
            Install-PackageProvider -Name NuGet -Force -Scope AllUsers -ErrorAction SilentlyContinue | Out-Null
            Install-Module -Name PSWindowsUpdate -Force -Scope AllUsers -AllowClobber -ErrorAction Stop
        }
        Import-Module PSWindowsUpdate -ErrorAction Stop
        Get-WindowsUpdate -AcceptAll -Install -IgnoreReboot -ErrorAction Stop |
            ForEach-Object { Write-Log "Update: $($_.Title)" }
        Write-Log -Level OK -Message "Windows updates installed (a restart may be pending)."
    }
}

# ---------------------------------------------------------------------------
# 14. Accounts
# ---------------------------------------------------------------------------

$endUserMode = Get-Setting $EndUser 'mode' 'leaveOOBE'

if ($endUserMode -eq 'createLocalAccount') {
    $username = Get-Setting $EndUser 'username' ''
    if ($username -and (Get-Setting $EndUser 'mustChangePassword' $true)) {
        Invoke-Step "Requiring $username to change their password at first sign-in" {
            # The account itself is created by the answer file; this only sets
            # the "must change at next logon" flag the answer file can't express.
            & net.exe user $username /logonpasswordchg:yes | Out-Null
            Write-Log -Level OK -Message "$username must change their password at first sign-in."
        }
    }
} elseif ($endUserMode -eq 'promptAtFirstBoot') {
    <#
        The fields are asked for on the progress screen itself, not in a dialog
        of our own.

        Read-Host was the first attempt and could not work: provisioning runs as
        a scheduled task, so its console is not the window the technician is
        looking at. A WinForms dialog was the second, and it worked -- but only
        by making the progress screen stand down while it was up, at which point
        every Lenovo and installer popup on the machine came forward and covered
        the dialog instead. Splash.ps1 owns the fields now, so the screen can
        stay in front the whole way through and there is nothing to fight.

        The contract is one file: Splash.ps1 writes answer.json, this waits for
        it, reads it once and deletes it.
    #>
    Invoke-Step 'Creating the end-user account' {
        $answerPath = Join-Path $Root 'answer.json'
        Remove-Item -LiteralPath $answerPath -Force -ErrorAction SilentlyContinue

        if (-not $script:SplashProcess) {
            throw ('The progress screen is turned off for this template, so there is ' +
                'nowhere to ask for the account. Turn the screen on, or set the ' +
                'account in the template instead of asking at first boot.')
        }

        $timeoutMinutes = [int](Get-Setting $EndUser 'promptTimeoutMinutes' 15)
        if ($timeoutMinutes -lt 1) { $timeoutMinutes = 15 }
        $deadline = (Get-Date).AddMinutes($timeoutMinutes)

        $answer = $null
        try {
            while ((Get-Date) -lt $deadline) {
                if (Test-Path -LiteralPath $answerPath) {
                    # Give the writer a moment to finish flushing before parsing.
                    Start-Sleep -Milliseconds 250
                    try {
                        $answer = Get-Content -LiteralPath $answerPath -Raw | ConvertFrom-Json
                    } catch {
                        Write-Log -Level WARN -Message "Couldn't read the account details: $($_.Exception.Message)"
                    }
                    break
                }

                # The countdown belongs on the screen, so it is recomputed here and
                # handed over with every status write.
                $remaining = [int][Math]::Ceiling((($deadline - (Get-Date)).TotalSeconds))
                Set-Status -Step 'Waiting for the end-user account details' `
                    -Prompting -PromptRemaining $remaining

                # If the screen has died there is no one left to answer.
                try {
                    if ($script:SplashProcess.HasExited) {
                        throw 'The progress screen closed before the account details were entered.'
                    }
                } catch [System.InvalidOperationException] { }

                Start-Sleep -Seconds 1
            }
        } finally {
            Remove-Item -LiteralPath $answerPath -Force -ErrorAction SilentlyContinue
            Set-Status -Step 'Creating the end-user account'
        }

        if ($null -eq $answer) {
            throw ("Nobody entered the account details within $timeoutMinutes minute(s), " +
                'so no account was created. Create one in Settings, or set the account ' +
                'in the template instead of asking at first boot.')
        }

        $username = [string](Get-Setting $answer 'username' '')
        if ([string]::IsNullOrWhiteSpace($username)) {
            throw 'The account details came through without a username.'
        }
        $plainPassword = [string](Get-Setting $answer 'password' '')

        $parameters = @{ Name = $username }
        if ([string]::IsNullOrEmpty($plainPassword)) {
            $parameters['NoPassword'] = $true
        } else {
            $parameters['Password'] = (ConvertTo-SecureString $plainPassword -AsPlainText -Force)
        }
        $fullName = [string](Get-Setting $answer 'fullName' '')
        if ($fullName) { $parameters['FullName'] = $fullName }
        New-LocalUser @parameters -ErrorAction Stop | Out-Null

        $group = if ([bool](Get-Setting $answer 'admin' $false)) { 'Administrators' } else { 'Users' }
        Add-LocalGroupMember -Group $group -Member $username -ErrorAction SilentlyContinue
        if ([bool](Get-Setting $answer 'mustChange' $true) -and $plainPassword) {
            & net.exe user $username /logonpasswordchg:yes | Out-Null
        }
        $script:AccountCreated = $username
        Write-Log -Level OK -Message "Created $username in $group."
    }
}

if (Get-Setting $Admin 'passwordNeverExpires' $true) {
    $adminName = Get-Setting $Admin 'username' ''
    if ($adminName) {
        Invoke-Step "Setting the password on $adminName to never expire" {
            Set-LocalUser -Name $adminName -PasswordNeverExpires $true -ErrorAction Stop
            Write-Log -Level OK -Message "Password expiry disabled for $adminName."
        }
    }
}

# ---------------------------------------------------------------------------
# 15. Encryption
# ---------------------------------------------------------------------------

$bitLocker = Get-Setting $System 'bitLocker' 'off'
if ($bitLocker -ne 'off') {
    Invoke-Step "Enabling BitLocker ($bitLocker)" {
        $tpm = Get-Tpm -ErrorAction SilentlyContinue
        if (-not $tpm -or -not $tpm.TpmReady) {
            throw 'No usable TPM found, so BitLocker was not enabled.'
        }

        $parameters = @{
            MountPoint       = 'C:'
            EncryptionMethod = 'XtsAes256'
            UsedSpaceOnly    = $true
            SkipHardwareTest = $true
        }
        if ($bitLocker -eq 'tpmWithPin') {
            $pin = Read-Host '  BitLocker startup PIN (6-20 digits)' -AsSecureString
            Enable-BitLocker @parameters -TpmAndPinProtector -Pin $pin -ErrorAction Stop | Out-Null
        } else {
            Enable-BitLocker @parameters -TpmProtector -ErrorAction Stop | Out-Null
        }

        $recovery = Add-BitLockerKeyProtector -MountPoint 'C:' -RecoveryPasswordProtector `
            -ErrorAction Stop
        $key = ($recovery.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' } |
            Select-Object -Last 1)

        if ($key) {
            $keyFile = Join-Path $LogDirectory 'bitlocker-recovery-key.txt'
            Set-Content -LiteralPath $keyFile -Encoding UTF8 -Value @"
BitLocker recovery key for $env:COMPUTERNAME
Generated $(Get-Date -Format 'u') by ImageHub

Key ID:       $($key.KeyProtectorId)
Recovery key: $($key.RecoveryPassword)

Move this into your key escrow and delete this file.
"@
            Write-Log -Level OK -Message "Recovery key written to $keyFile - escrow it and delete the file."
            $script:Warnings += "A BitLocker recovery key is sitting in $keyFile. Escrow it and delete the file."

            if (Get-Setting $System 'bitLockerRecoveryToAD' $false) {
                try {
                    Backup-BitLockerKeyProtector -MountPoint 'C:' `
                        -KeyProtectorId $key.KeyProtectorId -ErrorAction Stop
                    Write-Log -Level OK -Message "Recovery key backed up to Active Directory."
                } catch {
                    Write-Log -Level WARN -Message "AD backup failed: $($_.Exception.Message)"
                }
            }
        }
    }
}

if (Get-Setting $System 'disableRecoveryEnvironment' $false) {
    Invoke-Step 'Disabling the Windows recovery environment' {
        & reagentc.exe /disable | Out-Null
        Write-Log -Level OK -Message "WinRE disabled."
    }
}

# ---------------------------------------------------------------------------
# 16. Registry tweaks from the template
# ---------------------------------------------------------------------------

$tweaks = @(Get-Setting $System 'registryTweaks' @())
if ($tweaks.Count -gt 0) {
    Invoke-Step "Applying $($tweaks.Count) registry value(s)" {
        foreach ($tweak in $tweaks) {
            try {
                $value = $tweak.value
                if ($tweak.type -in @('DWord', 'QWord')) { $value = [int64]$value }
                Set-RegistryValue -Path $tweak.path -Name $tweak.name -Value $value -Type $tweak.type
                Write-Log -Level OK -Message "$($tweak.path)\$($tweak.name) = $($tweak.value)"
            } catch {
                Write-Log -Level WARN -Message "Couldn't set $($tweak.path)\$($tweak.name): $($_.Exception.Message)"
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 17. Custom scripts
# ---------------------------------------------------------------------------

function Invoke-CustomScripts {
    param([string]$Phase)
    $scripts = @(Get-Setting $Config 'scripts' @() | Where-Object { $_.phase -eq $Phase })
    foreach ($script in $scripts) {
        $file = Join-Path $Root $script.file
        $name = Get-Setting $script 'name' $script.file
        if (-not (Test-Path -LiteralPath $file)) {
            Write-Log -Level WARN -Message "Custom script missing: $file"
            continue
        }
        Write-Log -Level STEP -Message "Custom script: $name ($Phase)"
        try {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $file 2>&1 |
                ForEach-Object {
                    Add-Content -LiteralPath $LogFile -Value "      $_"
                    Write-Host "      $_" -ForegroundColor DarkGray
                }
            if ($LASTEXITCODE -ne 0) { throw "exited with $LASTEXITCODE" }
            Write-Log -Level OK -Message "$name completed."
        } catch {
            $message = "Custom script '$name' failed: $($_.Exception.Message)"
            Write-Log -Level FAIL -Message $message
            if (Get-Setting $script 'continueOnError' $true) {
                $script:Warnings += $message
            } else {
                $script:Failures += $message
            }
        }
    }
}

Invoke-CustomScripts -Phase 'provision'

# ---------------------------------------------------------------------------
# 18. Hide the admin account, if asked
# ---------------------------------------------------------------------------

if (Get-Setting $Admin 'hideFromLoginScreen' $false) {
    $adminName = Get-Setting $Admin 'username' ''
    if ($adminName) {
        Invoke-Step "Hiding $adminName from the sign-in screen" {
            Set-RegistryValue `
                -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList' `
                -Name $adminName -Value 0
            Write-Log -Level OK -Message "$adminName hidden (still reachable with .\$adminName)."
        }
    }
}

Invoke-CustomScripts -Phase 'finalize'

# ---------------------------------------------------------------------------
# 19. Clean up secrets and report
# ---------------------------------------------------------------------------

Invoke-Step 'Clearing staged credentials' {
    # config.json can hold a Wi-Fi passphrase, and the answer file holds account
    # passwords in clear text. Both are removed now that they've been consumed.
    foreach ($path in @(
        (Join-Path $Root 'config.json'),
        # Normally consumed and deleted the moment it is read; listed here in case
        # a run was interrupted between the write and the read.
        (Join-Path $Root 'answer.json'),
        'C:\Windows\Panther\unattend.xml',
        'C:\Windows\Panther\unattend\unattend.xml',
        'C:\Windows\System32\Sysprep\unattend.xml'
    )) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            Write-Log -Level OK -Message "Removed $path."
        }
    }
}

$stamp = Join-Path $Root 'provisioned.json'
@{
    templateName = $Config.templateName
    templateId   = $Config.templateID
    generatedBy  = $Config.generatedBy
    completedAt  = (Get-Date).ToString('o')
    computerName = $env:COMPUTERNAME
    failures     = $script:Failures
    warnings     = $script:Warnings
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $stamp -Encoding UTF8

Write-Host ''
Write-Host '  ---------------------------------------------' -ForegroundColor DarkGray
if ($script:Failures.Count -eq 0) {
    Write-Host '  Provisioning finished.' -ForegroundColor Green
} else {
    Write-Host "  Provisioning finished with $($script:Failures.Count) failure(s)." -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
}
if ($script:Warnings.Count -gt 0) {
    Write-Host "  $($script:Warnings.Count) warning(s):" -ForegroundColor Yellow
    $script:Warnings | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }
}

$note = Get-Setting $EndUser 'welcomeNote' ''
if ($note) {
    Write-Host ''
    Write-Host '  Note from IT:' -ForegroundColor White
    Write-Host "  $note" -ForegroundColor Gray
}

Write-Host ''
Write-Host "  Full log: $LogFile" -ForegroundColor DarkGray
if ($desiredName -and $desiredName -ne $env:COMPUTERNAME) {
    Write-Host "  Restart to finish renaming this machine to $desiredName." -ForegroundColor DarkGray
}
Write-Host ''

Write-Log "Provisioning complete. Failures: $($script:Failures.Count), warnings: $($script:Warnings.Count)."

<#
    What the finish screen shows. Deliberately the handful of facts a technician
    would otherwise go digging in the log for before handing a machine over.
#>
$summaryLines = @()
$summaryLines += "Computer name: " + $(if ($desiredName) { "$desiredName (after restart)" } else { $env:COMPUTERNAME })
if ($script:AppsTotal -gt 0) {
    $summaryLines += "Applications: $($script:AppsInstalled) of $($script:AppsTotal) installed"
}
if ($script:AccountCreated) {
    $summaryLines += "Account created: $($script:AccountCreated)"
} elseif ($endUserMode -eq 'promptAtFirstBoot') {
    $summaryLines += 'Account created: none'
}
if ($script:Warnings.Count -gt 0) {
    $summaryLines += "$($script:Warnings.Count) warning(s) - full detail in C:\ImageHub\logs"
}

$script:StepIndex = $script:StepTotal
Set-Status `
    -Step 'Finished' `
    -State $(if ($script:Failures.Count -gt 0) { 'failed' } else { 'done' }) `
    -Summary $summaryLines `
    -Note ([string](Get-Setting $EndUser 'welcomeNote' ''))

# The progress screen is full-screen and on top, so a console prompt behind it
# would just look like a hang. It has its own Close button.
$splashRunning = $false
if ($script:SplashProcess) {
    try { $splashRunning = -not $script:SplashProcess.HasExited } catch { $splashRunning = $false }
}

if (-not $NoPause -and -not $splashRunning) {
    Write-Host '  Press any key to close this window...' -ForegroundColor DarkGray
    try {
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    } catch {
        Start-Sleep -Seconds 20
    }
}

exit ($(if ($script:Failures.Count -gt 0) { 1 } else { 0 }))
