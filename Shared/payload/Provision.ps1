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
        [string]$Note = ''
    )
    try {
        [ordered]@{
            state            = $State
            step             = $Step
            detail           = $Detail
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

# ---------------------------------------------------------------------------
# 0. Drivers - before the network, because on many machines the Wi-Fi adapter
#    does not exist until its driver is installed. Windows' stock image has no
#    driver for a lot of current Lenovo/Dell wireless chipsets, which leaves the
#    machine with Ethernet only and makes every winget install fail for want of
#    internet. Drop the vendor's extracted driver pack in <media>\ImageHub\Drivers
#    and it is installed here.
# ---------------------------------------------------------------------------

# Say plainly whether this run has the privileges it needs. Half the settings
# here write to HKLM or load the default user hive, and without elevation they
# fail one by one with "Attempted to perform an unauthorized operation" -- which
# is what happened on a real machine when FirstLogonCommands handed provisioning
# a filtered admin token.
$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
$script:IsElevated = $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($script:IsElevated) {
    Write-Log -Level OK -Message "Running elevated as $($identity.Identity.Name)."
} else {
    Write-Log -Level WARN -Message ("Not elevated (running as $($identity.Identity.Name)). " +
        "Settings that write to HKLM or the default user profile will fail. " +
        "Launch.cmd normally registers an elevated scheduled task for this.")
    $script:Warnings += 'Provisioning ran without administrator rights, so machine-wide settings were skipped.'
}

$driverRoot = Join-Path $PayloadRoot 'Drivers'
if (Test-Path -LiteralPath $driverRoot) {
    $infCount = @(Get-ChildItem -LiteralPath $driverRoot -Recurse -Filter *.inf -ErrorAction SilentlyContinue).Count
    if ($infCount -gt 0) {
        Set-Status -Step 'Installing drivers...'
        Invoke-Step "Installing $infCount driver package(s)" {
            $output = & pnputil.exe /add-driver (Join-Path $driverRoot '*.inf') /subdirs /install 2>&1
            $output | ForEach-Object { if ($_) { Write-Log "  $_" } }
            # pnputil returns non-zero when *some* packages are skipped, which is
            # normal for a mixed pack, so the INF count is what gets reported.
            $added = @($output | Select-String -SimpleMatch 'successfully' -ErrorAction SilentlyContinue).Count
            Write-Log -Level OK -Message "pnputil processed the driver folder ($added success line(s))."
        }
    }
}

# ---------------------------------------------------------------------------
# 1. Network - first, because everything else may need it
# ---------------------------------------------------------------------------

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
        $profilePath = Join-Path $env:TEMP 'imagehub-wifi.xml'
        Set-Content -LiteralPath $profilePath -Value $profileXml -Encoding UTF8
        & netsh.exe wlan add profile filename="$profilePath" user=all | Out-Null
        Remove-Item -LiteralPath $profilePath -Force -ErrorAction SilentlyContinue
        & netsh.exe wlan connect name="$ssid" | Out-Null
        Write-Log -Level OK -Message "Wi-Fi profile added and connection requested."
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
# 3. Regional and power settings
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

# ---------------------------------------------------------------------------
# 4. Remote access
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
# 5. Desktop defaults - written into the default user hive so every account
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

    try {
        foreach ($base in $targets) {
            $advanced = "$base\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
            if (Get-Setting $System 'showFileExtensions' $true) {
                Set-RegistryValue -Path $advanced -Name 'HideFileExt' -Value 0
            }
            if (Get-Setting $System 'showHiddenFiles' $false) {
                Set-RegistryValue -Path $advanced -Name 'Hidden' -Value 1
            }
            if (Get-Setting $System 'taskbarAlignLeft' $false) {
                Set-RegistryValue -Path $advanced -Name 'TaskbarAl' -Value 0
            }
            if (Get-Setting $System 'disableWidgets' $false) {
                Set-RegistryValue -Path $advanced -Name 'TaskbarDa' -Value 0
            }
            if (Get-Setting $System 'classicContextMenu' $false) {
                $clsid = "$base\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32"
                Set-RegistryValue -Path $clsid -Name '(Default)' -Value '' -Type String
            }
            if (Get-Setting $System 'disableWebSearch' $false) {
                Set-RegistryValue -Path "$base\Software\Policies\Microsoft\Windows\Explorer" `
                    -Name 'DisableSearchBoxSuggestions' -Value 1
            }
        }
        Write-Log -Level OK -Message "Shell defaults applied to the current and default profiles."
    } finally {
        if ($loaded) {
            [gc]::Collect()
            & reg.exe unload 'HKU\ImageHubDefault' 2>$null | Out-Null
        }
    }
}

# ---------------------------------------------------------------------------
# 6. Telemetry and consumer features
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
# 7. Debloat
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
# 8. Optional Windows features
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
# 9. Applications
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
                    $arguments = @(
                        'install', '--id', (Get-Setting $app 'packageID'),
                        '--exact', '--silent',
                        '--accept-package-agreements', '--accept-source-agreements',
                        '--disable-interactivity'
                    )
                    $version = Get-Setting $app 'version' ''
                    if ($version) { $arguments += @('--version', $version) }

                    Write-Log "Installing $name via winget..."
                    $output = & $winget @arguments 2>&1
                    $output | ForEach-Object { Add-Content -LiteralPath $LogFile -Value "      $_" }

                    # winget uses 0 for success and 0x8A150061 for "already installed".
                    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335135) {
                        throw "winget exited with $LASTEXITCODE"
                    }
                    Write-Log -Level OK -Message "$name installed."
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
        } catch {
            $message = "$name did not install: $($_.Exception.Message)"
            Write-Log -Level FAIL -Message $message
            if ($required) { $script:Failures += $message } else { $script:Warnings += $message }
        }
    }
}

# ---------------------------------------------------------------------------
# 10. Branding
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
# 11. Windows Update policy
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
# 12. Accounts
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
    Invoke-Step 'Creating the end-user account' {
        Write-Host ''
        Write-Host '  End-user account' -ForegroundColor White
        $username = Read-Host '  Username for the person receiving this machine'
        if ([string]::IsNullOrWhiteSpace($username)) {
            throw 'No username entered; skipping account creation.'
        }
        $fullName = Read-Host '  Full name (optional)'
        $password = Read-Host '  Password' -AsSecureString

        $parameters = @{
            Name     = $username
            Password = $password
        }
        if ($fullName) { $parameters['FullName'] = $fullName }
        New-LocalUser @parameters -ErrorAction Stop | Out-Null

        $group = if (Get-Setting $EndUser 'administrator' $false) { 'Administrators' } else { 'Users' }
        Add-LocalGroupMember -Group $group -Member $username -ErrorAction SilentlyContinue
        if (Get-Setting $EndUser 'mustChangePassword' $true) {
            & net.exe user $username /logonpasswordchg:yes | Out-Null
        }
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
# 13. Encryption
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
# 14. Registry tweaks from the template
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
# 15. Custom scripts
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
# 16. Hide the admin account, if asked
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
# 17. Clean up secrets and report
# ---------------------------------------------------------------------------

Invoke-Step 'Clearing staged credentials' {
    # config.json can hold a Wi-Fi passphrase, and the answer file holds account
    # passwords in clear text. Both are removed now that they've been consumed.
    foreach ($path in @(
        (Join-Path $Root 'config.json'),
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

$script:StepIndex = $script:StepTotal
Set-Status `
    -Step 'Finished' `
    -State $(if ($script:Failures.Count -gt 0) { 'failed' } else { 'done' }) `
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
