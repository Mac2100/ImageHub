<#
.SYNOPSIS
    ImageHub for Windows - builds a bootable Windows golden-image USB drive from
    an ImageHub deployment template.

.DESCRIPTION
    The Windows counterpart to the macOS app. It reads the same template JSON,
    generates the same autounattend.xml, and writes the same ImageHub\ payload,
    so a drive built on Windows is interchangeable with one built on a Mac.

    Where the Mac uses diskutil / hdiutil / rsync / wimlib, this uses
    diskpart / Mount-DiskImage / robocopy / DISM - no extra tools to install.

.PARAMETER Template
    Path to a template JSON file (exported from the macOS app, or hand-written).

.PARAMETER Iso
    Path to the Windows ISO to build from.

.PARAMETER DiskNumber
    Physical disk number of the USB drive to erase. Omit to be shown a list.

.PARAMETER ListDisks
    Print the removable disks this script is willing to write to, then exit.

.EXAMPLE
    .\ImageHub.ps1 -ListDisks

.EXAMPLE
    .\ImageHub.ps1 -Template .\StandardWorkstation.json -Iso D:\iso\Win11_24H2.iso -DiskNumber 3

.NOTES
    Requires an elevated PowerShell 5.1+ session.

    Secrets: the macOS app keeps passwords in the Keychain and injects them at
    build time. Here they are read from a sidecar file next to the template
    (<template>.secrets.json) or prompted for interactively - they are never
    stored inside the template itself.
#>

[CmdletBinding(DefaultParameterSetName = 'Build')]
param(
    [Parameter(ParameterSetName = 'Build', Mandatory)]
    [string]$Template,

    [Parameter(ParameterSetName = 'Build', Mandatory)]
    [string]$Iso,

    [Parameter(ParameterSetName = 'Build')]
    [int]$DiskNumber = -1,

    [Parameter(ParameterSetName = 'Build')]
    [string]$VolumeLabel = 'IMAGEHUB',

    [Parameter(ParameterSetName = 'Build')]
    [switch]$Force,

    [Parameter(ParameterSetName = 'List', Mandatory)]
    [switch]$ListDisks
)

$ErrorActionPreference = 'Stop'

$PayloadSource = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Shared\payload'

function Write-Step { param([string]$Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok { param([string]$Message) Write-Host "    $Message" -ForegroundColor Green }
function Write-Note { param([string]$Message) Write-Host "    $Message" -ForegroundColor Gray }
function Write-Warn { param([string]$Message) Write-Host "    $Message" -ForegroundColor Yellow }

function Assert-Elevated {
    $identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this from an elevated PowerShell session - erasing a disk needs administrator rights.'
    }
}

function Get-EligibleDisk {
    <# Removable/USB disks only. Internal disks are never listed, on purpose. #>
    Get-Disk | Where-Object {
        $_.BusType -eq 'USB' -or $_.IsRemovable -or $_.BusType -eq 'SD'
    } | Select-Object Number, FriendlyName, Size, BusType, PartitionStyle
}

function Show-Disks {
    $disks = @(Get-EligibleDisk)
    if ($disks.Count -eq 0) {
        Write-Warn 'No removable disks found. Plug a USB drive in and try again.'
        return
    }
    Write-Host ''
    $disks | ForEach-Object {
        Write-Host ("  Disk {0}  {1,-34} {2,8:N1} GB  {3}" -f `
            $_.Number, $_.FriendlyName, ($_.Size / 1GB), $_.BusType)
    }
    Write-Host ''
}

function Get-Setting {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Get-Secrets {
    <#
        Passwords come from <template>.secrets.json when present, otherwise the
        operator is prompted. Keeping them out of the template means a template
        is safe to commit to git.
    #>
    param([string]$TemplatePath, $Config)

    $sidecar = [System.IO.Path]::ChangeExtension($TemplatePath, $null) + 'secrets.json'
    $secrets = @{
        adminPassword  = ''
        userPassword   = ''
        domainPassword = ''
        productKey     = ''
        wifiPassword   = ''
    }

    if (Test-Path -LiteralPath $sidecar) {
        Write-Note "Reading secrets from $([System.IO.Path]::GetFileName($sidecar))"
        $loaded = Get-Content -LiteralPath $sidecar -Raw | ConvertFrom-Json
        foreach ($key in @($secrets.Keys)) {
            $value = Get-Setting $loaded $key ''
            if ($value) { $secrets[$key] = $value }
        }
    }

    function Read-Plain {
        param([string]$Prompt)
        $secure = Read-Host "    $Prompt" -AsSecureString
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    }

    $admin = Get-Setting $Config 'admin'
    if ((Get-Setting $admin 'enabled' $true) -and -not $secrets.adminPassword) {
        $secrets.adminPassword = Read-Plain "Password for the IT admin account '$(Get-Setting $admin 'username')'"
    }

    $endUser = Get-Setting $Config 'endUser'
    if ((Get-Setting $endUser 'mode') -eq 'createLocalAccount' -and -not $secrets.userPassword) {
        $secrets.userPassword = Read-Plain "Password for the end-user account '$(Get-Setting $endUser 'username')'"
    }

    $identity = Get-Setting $Config 'identity'
    if ((Get-Setting $identity 'joinMode') -eq 'activeDirectory' -and -not $secrets.domainPassword) {
        $secrets.domainPassword = Read-Plain "Password for domain join account '$(Get-Setting $identity 'domainJoinUser')'"
    }

    $wifi = Get-Setting (Get-Setting $Config 'system') 'wifi'
    if ((Get-Setting $wifi 'enabled' $false) -and (Get-Setting $wifi 'security') -ne 'open' `
            -and -not $secrets.wifiPassword) {
        $secrets.wifiPassword = Read-Plain "Wi-Fi password for '$(Get-Setting $wifi 'ssid')'"
    }

    if ((Get-Setting (Get-Setting $Config 'windows') 'productKeyMode') -eq 'custom' -and -not $secrets.productKey) {
        $secrets.productKey = Read-Plain 'Windows product key'
    }

    return $secrets
}

# ---------------------------------------------------------------------------
# Answer file
# ---------------------------------------------------------------------------

$GenericKeys = @{
    'win11' = @{
        pro = 'W269N-WFGWX-YVC9B-4J6C9-T83GX'
        proWorkstations = 'NRG8B-VKK3Q-CXVCJ-9G2XF-6Q84J'
        enterprise = 'NPPR9-FWDCX-D2C8J-H872K-2YT43'
        education = 'NW6C2-QMPVW-D7KKK-3GKT6-VCFB2'
        proEducation = '6TP4R-GNPTD-KYYHQ-7B7DP-J447Y'
        home = 'TX9XD-98N7V-6WMQ6-BX7FG-H8Q99'
    }
}
$GenericKeys['win10'] = $GenericKeys['win11']

$EditionNames = @{
    pro = 'Pro'
    proWorkstations = 'Pro for Workstations'
    enterprise = 'Enterprise'
    education = 'Education'
    proEducation = 'Pro Education'
    home = 'Home'
}

function ConvertTo-XmlText {
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    return [System.Security.SecurityElement]::Escape($Value)
}

function New-AnswerFile {
    <#
        Mirror of Sources/ImageHub/Services/AnswerFileBuilder.swift. The template
        schema is the contract between the two; if you change one, change both.
    #>
    param($Config, [hashtable]$Secrets)

    $windows = Get-Setting $Config 'windows'
    $disk = Get-Setting $Config 'disk'
    $admin = Get-Setting $Config 'admin'
    $endUser = Get-Setting $Config 'endUser'
    $identity = Get-Setting $Config 'identity'
    $system = Get-Setting $Config 'system'
    $oobe = Get-Setting $Config 'oobe'

    $architecture = if ((Get-Setting $windows 'architecture' 'x64') -eq 'arm64') { 'arm64' } else { 'amd64' }
    $isUEFI = (Get-Setting $disk 'partitionStyle' 'gpt') -eq 'gpt'
    $osPartition = if ($isUEFI) { 3 } else { 1 }
    $locale = Get-Setting $system 'locale' 'en-US'
    $inputLocale = Get-Setting $system 'inputLocale' '0409:00000409'
    $release = Get-Setting $windows 'release' 'win11'
    $edition = Get-Setting $windows 'edition' 'pro'

    # --- windowsPE: disk layout + edition ---------------------------------
    $diskConfiguration = ''
    if (Get-Setting $disk 'wipeTargetDisk' $true) {
        if ($isUEFI) {
            $creates = @"
            <CreatePartition wcm:action="add">
              <Order>1</Order><Type>EFI</Type><Size>$(Get-Setting $disk 'efiSizeMB' 300)</Size>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>2</Order><Type>MSR</Type><Size>$(Get-Setting $disk 'msrSizeMB' 16)</Size>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>3</Order><Type>Primary</Type><Extend>true</Extend>
            </CreatePartition>
"@
            $modifies = @"
            <ModifyPartition wcm:action="add">
              <Order>1</Order><PartitionID>1</PartitionID><Label>System</Label><Format>FAT32</Format>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>2</Order><PartitionID>2</PartitionID>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>3</Order><PartitionID>3</PartitionID><Label>Windows</Label><Letter>C</Letter><Format>NTFS</Format>
            </ModifyPartition>
"@
        } else {
            $creates = @"
            <CreatePartition wcm:action="add">
              <Order>1</Order><Type>Primary</Type><Extend>true</Extend>
            </CreatePartition>
"@
            $modifies = @"
            <ModifyPartition wcm:action="add">
              <Order>1</Order><PartitionID>1</PartitionID><Label>Windows</Label><Letter>C</Letter><Format>NTFS</Format><Active>true</Active>
            </ModifyPartition>
"@
        }

        $diskIDs = if (Get-Setting $disk 'wipeAllDisks' $false) { 0..3 } else { @(Get-Setting $disk 'diskNumber' 0) }
        $diskBlocks = ''
        foreach ($id in $diskIDs) {
            $diskBlocks += "`n        <Disk wcm:action=`"add`">`n          <DiskID>$id</DiskID>`n          <WillWipeDisk>true</WillWipeDisk>"
            if ($id -eq (Get-Setting $disk 'diskNumber' 0)) {
                $diskBlocks += "`n          <CreatePartitions>`n$creates`n          </CreatePartitions>"
                $diskBlocks += "`n          <ModifyPartitions>`n$modifies`n          </ModifyPartitions>"
            }
            $diskBlocks += "`n        </Disk>"
        }

        $diskConfiguration = @"
      <DiskConfiguration>
        <WillShowUI>OnError</WillShowUI>$diskBlocks
      </DiskConfiguration>
"@
    }

    $imageIndex = Get-Setting $windows 'imageIndex'
    if ($imageIndex) {
        $installFrom = @"
          <InstallFrom>
            <MetaData wcm:action="add"><Key>/IMAGE/INDEX</Key><Value>$imageIndex</Value></MetaData>
          </InstallFrom>
"@
    } else {
        $product = if ($release -eq 'win10') { 'Windows 10' } else { 'Windows 11' }
        $imageName = "$product $($EditionNames[$edition])"
        $installFrom = @"
          <InstallFrom>
            <MetaData wcm:action="add"><Key>/IMAGE/NAME</Key><Value>$(ConvertTo-XmlText $imageName)</Value></MetaData>
          </InstallFrom>
"@
    }

    $productKeyBlock = ''
    switch (Get-Setting $windows 'productKeyMode' 'generic') {
        'generic' {
            $key = $GenericKeys[$release][$edition]
            if ($key) {
                $productKeyBlock = "`n        <ProductKey><Key>$key</Key><WillShowUI>OnError</WillShowUI></ProductKey>"
            }
        }
        'custom' {
            if ($Secrets.productKey) {
                $productKeyBlock = "`n        <ProductKey><Key>$(ConvertTo-XmlText $Secrets.productKey)</Key><WillShowUI>OnError</WillShowUI></ProductKey>"
            }
        }
    }

    $bypassCommands = @()
    if (Get-Setting $system 'bypassWin11Requirements' $false) {
        foreach ($name in @('BypassTPMCheck', 'BypassSecureBootCheck', 'BypassRAMCheck', 'BypassCPUCheck', 'BypassStorageCheck')) {
            $bypassCommands += "cmd /c reg add HKLM\SYSTEM\Setup\LabConfig /v $name /t REG_DWORD /d 1 /f"
        }
    }
    if (Get-Setting $system 'bypassNetworkRequirement' $true) {
        $bypassCommands += 'cmd /c reg add HKLM\SYSTEM\Setup\OOBE /v BypassNRO /t REG_DWORD /d 1 /f'
    }
    $bypassBlock = ''
    if ($bypassCommands.Count -gt 0) {
        $bypassBlock = "`n      <RunSynchronous>"
        for ($i = 0; $i -lt $bypassCommands.Count; $i++) {
            $bypassBlock += "`n        <RunSynchronousCommand wcm:action=`"add`"><Order>$($i + 1)</Order><Path>$(ConvertTo-XmlText $bypassCommands[$i])</Path></RunSynchronousCommand>"
        }
        $bypassBlock += "`n      </RunSynchronous>"
    }

    # --- specialize -------------------------------------------------------
    $stageCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "' +
        "`$src = Get-PSDrive -PSProvider FileSystem | ForEach-Object { Join-Path `$_.Root 'ImageHub' } | " +
        "Where-Object { Test-Path (Join-Path `$_ 'Provision.ps1') } | Select-Object -First 1; " +
        "if (`$src) { Copy-Item -LiteralPath `$src -Destination 'C:\ImageHub' -Recurse -Force }" + '"'

    $specializeCommands = @($stageCommand)
    if (Get-Setting $system 'enableRemoteDesktop' $false) {
        $specializeCommands += 'cmd /c reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f'
    }

    $specializeBlock = "`n      <RunSynchronous>"
    for ($i = 0; $i -lt $specializeCommands.Count; $i++) {
        $specializeBlock += "`n        <RunSynchronousCommand wcm:action=`"add`"><Order>$($i + 1)</Order><Path>$(ConvertTo-XmlText $specializeCommands[$i])</Path></RunSynchronousCommand>"
    }
    $specializeBlock += "`n      </RunSynchronous>"

    $joinBlock = ''
    if ((Get-Setting $identity 'joinMode') -eq 'activeDirectory' -and (Get-Setting $identity 'domain')) {
        $ou = Get-Setting $identity 'organizationalUnit' ''
        $ouLine = if ($ou) { "`n        <MachineObjectOU>$(ConvertTo-XmlText $ou)</MachineObjectOU>" } else { '' }
        $joinBlock = @"

    <component name="Microsoft-Windows-UnattendedJoin" processorArchitecture="$architecture" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <Identification>
        <Credentials>
          <Domain>$(ConvertTo-XmlText (Get-Setting $identity 'domain'))</Domain>
          <Username>$(ConvertTo-XmlText (Get-Setting $identity 'domainJoinUser'))</Username>
          <Password>$(ConvertTo-XmlText $Secrets.domainPassword)</Password>
        </Credentials>
        <JoinDomain>$(ConvertTo-XmlText (Get-Setting $identity 'domain'))</JoinDomain>$ouLine
      </Identification>
    </component>
"@
    }

    # --- oobeSystem -------------------------------------------------------
    $localAccounts = ''
    if ((Get-Setting $admin 'enabled' $true) -and (Get-Setting $admin 'username')) {
        $localAccounts += @"

          <LocalAccount wcm:action="add">
            <Name>$(ConvertTo-XmlText (Get-Setting $admin 'username'))</Name>
            <DisplayName>$(ConvertTo-XmlText (Get-Setting $admin 'displayName'))</DisplayName>
            <Description>$(ConvertTo-XmlText (Get-Setting $admin 'accountDescription'))</Description>
            <Group>Administrators</Group>
            <Password><Value>$(ConvertTo-XmlText $Secrets.adminPassword)</Value><PlainText>true</PlainText></Password>
          </LocalAccount>
"@
    }
    if ((Get-Setting $endUser 'mode') -eq 'createLocalAccount' -and (Get-Setting $endUser 'username')) {
        $displayName = Get-Setting $endUser 'displayName' (Get-Setting $endUser 'username')
        $group = if (Get-Setting $endUser 'administrator' $false) { 'Administrators' } else { 'Users' }
        $localAccounts += @"

          <LocalAccount wcm:action="add">
            <Name>$(ConvertTo-XmlText (Get-Setting $endUser 'username'))</Name>
            <DisplayName>$(ConvertTo-XmlText $displayName)</DisplayName>
            <Description>Created by ImageHub</Description>
            <Group>$group</Group>
            <Password><Value>$(ConvertTo-XmlText $Secrets.userPassword)</Value><PlainText>true</PlainText></Password>
          </LocalAccount>
"@
    }
    $userAccountsBlock = ''
    if ($localAccounts) {
        $userAccountsBlock = "`n      <UserAccounts>`n        <LocalAccounts>$localAccounts`n        </LocalAccounts>`n      </UserAccounts>"
    }

    $autoLogonBlock = ''
    $logonCount = [int](Get-Setting $admin 'autoLogonCount' 1)
    if ((Get-Setting $admin 'enabled' $true) -and $logonCount -gt 0 -and $Secrets.adminPassword) {
        $autoLogonBlock = @"

      <AutoLogon>
        <Enabled>true</Enabled>
        <Username>$(ConvertTo-XmlText (Get-Setting $admin 'username'))</Username>
        <LogonCount>$logonCount</LogonCount>
        <Password><Value>$(ConvertTo-XmlText $Secrets.adminPassword)</Value><PlainText>true</PlainText></Password>
      </AutoLogon>
"@
    }

    $launcher = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "' +
        "`$p = 'C:\ImageHub\Provision.ps1'; if (-not (Test-Path `$p)) { " +
        "`$p = Get-PSDrive -PSProvider FileSystem | ForEach-Object { Join-Path `$_.Root 'ImageHub\Provision.ps1' } | " +
        "Where-Object { Test-Path `$_ } | Select-Object -First 1 }; if (`$p) { & `$p }" + '"'

    $firstLogonBlock = @"

      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <CommandLine>$(ConvertTo-XmlText $launcher)</CommandLine>
          <Description>ImageHub provisioning</Description>
          <RequiresUserInput>false</RequiresUserInput>
        </SynchronousCommand>
      </FirstLogonCommands>
"@

    return @"
<?xml version="1.0" encoding="utf-8"?>
<!--
  Generated by ImageHub for Windows from template "$(ConvertTo-XmlText (Get-Setting $Config 'name'))".
  Regenerated on every build - edit the template, not this file.
-->
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">

<settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="$architecture" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SetupUILanguage><UILanguage>$locale</UILanguage></SetupUILanguage>
      <InputLocale>$inputLocale</InputLocale>
      <SystemLocale>$locale</SystemLocale>
      <UILanguage>$locale</UILanguage>
      <UserLocale>$locale</UserLocale>
    </component>

    <component name="Microsoft-Windows-Setup" processorArchitecture="$architecture" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
$diskConfiguration
      <ImageInstall>
        <OSImage>
$installFrom
          <InstallTo><DiskID>$(Get-Setting $disk 'diskNumber' 0)</DiskID><PartitionID>$osPartition</PartitionID></InstallTo>
          <WillShowUI>OnError</WillShowUI>
        </OSImage>
      </ImageInstall>
      <UserData>$productKeyBlock
        <AcceptEula>$(([string](Get-Setting $windows 'acceptEULA' $true)).ToLower())</AcceptEula>
        <FullName>$(ConvertTo-XmlText (Get-Setting $admin 'displayName'))</FullName>
        <Organization>ImageHub</Organization>
      </UserData>$bypassBlock
    </component>
</settings>

<settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="$architecture" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>*</ComputerName>
      <TimeZone>$(ConvertTo-XmlText (Get-Setting $system 'timeZone' 'UTC'))</TimeZone>
    </component>

    <component name="Microsoft-Windows-Deployment" processorArchitecture="$architecture" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">$specializeBlock
    </component>$joinBlock
</settings>

<settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="$architecture" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>$inputLocale</InputLocale>
      <SystemLocale>$locale</SystemLocale>
      <UILanguage>$locale</UILanguage>
      <UserLocale>$locale</UserLocale>
    </component>

    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="$architecture" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <TimeZone>$(ConvertTo-XmlText (Get-Setting $system 'timeZone' 'UTC'))</TimeZone>
      <OOBE>
        <HideEULAPage>$(([string](Get-Setting $oobe 'hideEULA' $true)).ToLower())</HideEULAPage>
        <HideOEMRegistrationScreen>$(([string](Get-Setting $oobe 'hideOEMRegistration' $true)).ToLower())</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>$(([string](Get-Setting $oobe 'hideOnlineAccountScreens' $true)).ToLower())</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>$(([string](Get-Setting $oobe 'hideWirelessSetup' $false)).ToLower())</HideWirelessSetupInOOBE>
        <ProtectYourPC>$(Get-Setting $oobe 'protectYourPC' 3)</ProtectYourPC>
        <SkipMachineOOBE>$(([string](Get-Setting $oobe 'skipMachineOOBE' $true)).ToLower())</SkipMachineOOBE>
        <SkipUserOOBE>$(([string](Get-Setting $oobe 'skipUserOOBE' $false)).ToLower())</SkipUserOOBE>
      </OOBE>$userAccountsBlock$autoLogonBlock$firstLogonBlock
    </component>
</settings>

</unattend>
"@
}

# ---------------------------------------------------------------------------
# Payload
# ---------------------------------------------------------------------------

function New-Payload {
    param($Config, [hashtable]$Secrets, [string]$VolumeRoot, [string]$TemplatePath)

    $root = Join-Path $VolumeRoot 'ImageHub'
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    New-Item -ItemType Directory -Path $root -Force | Out-Null

    if (-not (Test-Path -LiteralPath (Join-Path $PayloadSource 'Provision.ps1'))) {
        throw "Provisioning scripts not found at $PayloadSource. Run this from inside the repository checkout."
    }
    Copy-Item -Path (Join-Path $PayloadSource '*') -Destination $root -Recurse -Force

    $system = Get-Setting $Config 'system'
    $admin = Get-Setting $Config 'admin'
    $endUser = Get-Setting $Config 'endUser'
    $identity = Get-Setting $Config 'identity'
    $disk = Get-Setting $Config 'disk'

    # Applications: copy bundled installers, flatten winget/script entries.
    $apps = @()
    foreach ($app in @(Get-Setting $Config 'apps' @())) {
        if (-not (Get-Setting $app 'enabled' $true)) { continue }
        $relative = ''
        if ((Get-Setting $app 'source') -eq 'installer') {
            $source = Get-Setting $app 'installerPath' ''
            if (-not (Test-Path -LiteralPath $source)) {
                Write-Warn "Installer missing for '$(Get-Setting $app 'name')': $source - skipping."
                continue
            }
            $installers = Join-Path $root 'Installers'
            New-Item -ItemType Directory -Path $installers -Force | Out-Null
            $fileName = [System.IO.Path]::GetFileName($source)
            Copy-Item -LiteralPath $source -Destination (Join-Path $installers $fileName) -Force
            $relative = "Installers\$fileName"
        }
        $apps += [ordered]@{
            name       = Get-Setting $app 'name' ''
            source     = Get-Setting $app 'source' 'winget'
            packageID  = Get-Setting $app 'packageID' ''
            version    = Get-Setting $app 'version' ''
            installer  = $relative
            silentArgs = Get-Setting $app 'silentArgs' ''
            script     = Get-Setting $app 'script' ''
            required   = [bool](Get-Setting $app 'required' $false)
        }
    }

    # Assets.
    function Copy-Asset {
        param([string]$Path, [string]$Name)
        if (-not $Path) { return '' }
        if (-not (Test-Path -LiteralPath $Path)) {
            Write-Warn "Asset not found, skipping: $Path"
            return ''
        }
        $assets = Join-Path $root 'Assets'
        New-Item -ItemType Directory -Path $assets -Force | Out-Null
        $extension = [System.IO.Path]::GetExtension($Path)
        $fileName = "$Name$extension"
        Copy-Item -LiteralPath $Path -Destination (Join-Path $assets $fileName) -Force
        return "Assets\$fileName"
    }

    # Custom scripts.
    $scripts = @()
    foreach ($script in @(Get-Setting $Config 'scripts' @())) {
        if (-not (Get-Setting $script 'enabled' $true)) { continue }
        $body = Get-Setting $script 'body' ''
        if (-not $body) { continue }
        $scriptDirectory = Join-Path $root 'Scripts'
        New-Item -ItemType Directory -Path $scriptDirectory -Force | Out-Null
        $slug = (Get-Setting $script 'name' 'script') -replace '[^A-Za-z0-9\-_]', '-'
        $shortID = ([string](Get-Setting $script 'id' (New-Guid).Guid)).Substring(0, 8)
        $fileName = "$slug-$shortID.ps1"
        Set-Content -LiteralPath (Join-Path $scriptDirectory $fileName) -Value $body -Encoding UTF8
        $scripts += [ordered]@{
            name            = Get-Setting $script 'name' ''
            phase           = Get-Setting $script 'phase' 'provision'
            file            = "Scripts\$fileName"
            continueOnError = [bool](Get-Setting $script 'continueOnError' $true)
        }
    }

    $powerPlans = @{
        balanced = '381b4222-f694-41f0-9685-ff5bb260df2e'
        highPerformance = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
        powerSaver = 'a1841308-3541-4fab-bc81-f71556f20b4a'
    }
    $plan = Get-Setting $system 'powerPlan' 'balanced'

    $wifi = Get-Setting $system 'wifi'
    $removeBloat = [bool](Get-Setting $system 'removeBloatware' $true)

    $payloadConfig = [ordered]@{
        schemaVersion = 1
        generatedBy   = 'ImageHub for Windows'
        generatedAt   = (Get-Date).ToString('o')
        templateID    = [string](Get-Setting $Config 'id' '')
        templateName  = [string](Get-Setting $Config 'name' 'Template')
        admin         = [ordered]@{
            username            = if (Get-Setting $admin 'enabled' $true) { Get-Setting $admin 'username' '' } else { '' }
            displayName         = Get-Setting $admin 'displayName' ''
            accountDescription  = Get-Setting $admin 'accountDescription' ''
            hideFromLoginScreen = [bool](Get-Setting $admin 'hideFromLoginScreen' $false)
            passwordNeverExpires = [bool](Get-Setting $admin 'passwordNeverExpires' $true)
        }
        endUser       = [ordered]@{
            mode               = Get-Setting $endUser 'mode' 'leaveOOBE'
            username           = Get-Setting $endUser 'username' ''
            displayName        = Get-Setting $endUser 'displayName' ''
            administrator      = [bool](Get-Setting $endUser 'administrator' $false)
            mustChangePassword = [bool](Get-Setting $endUser 'mustChangePassword' $true)
            welcomeNote        = Get-Setting $endUser 'welcomeNote' ''
        }
        identity      = [ordered]@{
            joinMode  = Get-Setting $identity 'joinMode' 'workgroup'
            workgroup = Get-Setting $identity 'workgroup' 'WORKGROUP'
            domain    = Get-Setting $identity 'domain' ''
        }
        apps          = $apps
        system        = [ordered]@{
            computerNameTemplate = Get-Setting $system 'computerNameTemplate' 'IT-%SERIAL4%'
            timeZone             = Get-Setting $system 'timeZone' 'UTC'
            enableRemoteDesktop  = [bool](Get-Setting $system 'enableRemoteDesktop' $false)
            allowPing            = [bool](Get-Setting $system 'allowPing' $false)
            powerPlanGUID        = $powerPlans[$plan]
            disableSleepOnAC     = [bool](Get-Setting $system 'disableSleepOnAC' $true)
            disableFastStartup   = [bool](Get-Setting $system 'disableFastStartup' $false)
            disableHibernation   = [bool](Get-Setting $system 'disableHibernation' $false)
            showFileExtensions   = [bool](Get-Setting $system 'showFileExtensions' $true)
            showHiddenFiles      = [bool](Get-Setting $system 'showHiddenFiles' $false)
            classicContextMenu   = [bool](Get-Setting $system 'classicContextMenu' $false)
            taskbarAlignLeft     = [bool](Get-Setting $system 'taskbarAlignLeft' $false)
            disableWidgets       = [bool](Get-Setting $system 'disableWidgets' $false)
            disableWebSearch     = [bool](Get-Setting $system 'disableWebSearch' $false)
            disableTelemetry     = [bool](Get-Setting $system 'disableTelemetry' $true)
            disableConsumerFeatures = [bool](Get-Setting $system 'disableConsumerFeatures' $true)
            removeBloatware      = $removeBloat
            bloatware            = if ($removeBloat) { @(Get-Setting $system 'bloatwareList' @()) } else { @() }
            windowsUpdate        = Get-Setting $system 'windowsUpdate' 'automatic'
            installUpdates       = [bool](Get-Setting $system 'installUpdatesDuringProvisioning' $false)
            optionalFeatures     = @(Get-Setting $system 'optionalFeatures' @())
            bitLocker            = Get-Setting $system 'bitLocker' 'off'
            bitLockerRecoveryToAD = [bool](Get-Setting $system 'enableBitLockerRecoveryToAD' $false)
            disableRecoveryEnvironment = -not [bool](Get-Setting $disk 'recoveryPartition' $true)
            wallpaper            = Copy-Asset (Get-Setting $system 'wallpaperPath' '') 'Wallpaper'
            lockScreen           = Copy-Asset (Get-Setting $system 'lockScreenPath' '') 'LockScreen'
            startLayout          = Copy-Asset (Get-Setting $system 'startLayoutPath' '') 'StartLayout'
            wifi                 = [ordered]@{
                enabled              = [bool](Get-Setting $wifi 'enabled' $false)
                ssid                 = Get-Setting $wifi 'ssid' ''
                password             = if (Get-Setting $wifi 'enabled' $false) { $Secrets.wifiPassword } else { '' }
                security             = Get-Setting $wifi 'security' 'WPA2PSK'
                hidden               = [bool](Get-Setting $wifi 'hidden' $false)
                connectAutomatically = [bool](Get-Setting $wifi 'connectAutomatically' $true)
            }
            registryTweaks       = @(
                @(Get-Setting $system 'registryTweaks' @()) |
                    Where-Object { (Get-Setting $_ 'enabled' $true) -and (Get-Setting $_ 'name' '') } |
                    ForEach-Object {
                        [ordered]@{
                            path  = Get-Setting $_ 'path' ''
                            name  = Get-Setting $_ 'name' ''
                            type  = Get-Setting $_ 'type' 'DWord'
                            value = [string](Get-Setting $_ 'value' '')
                        }
                    }
            )
        }
        scripts       = $scripts
    }

    $payloadConfig | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath (Join-Path $root 'config.json') -Encoding UTF8
    Copy-Item -LiteralPath $TemplatePath -Destination (Join-Path $root 'template.json') -Force

    return $root
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if ($PSCmdlet.ParameterSetName -eq 'List') {
    Show-Disks
    return
}

Assert-Elevated

if (-not (Test-Path -LiteralPath $Template)) { throw "Template not found: $Template" }
if (-not (Test-Path -LiteralPath $Iso)) { throw "ISO not found: $Iso" }

$Config = Get-Content -LiteralPath $Template -Raw | ConvertFrom-Json
Write-Host ''
Write-Host "  ImageHub for Windows" -ForegroundColor White
Write-Host "  Template: $(Get-Setting $Config 'name' 'Untitled')" -ForegroundColor Gray
Write-Host "  ISO:      $Iso" -ForegroundColor Gray

if ($DiskNumber -lt 0) {
    Show-Disks
    $answer = Read-Host '  Disk number to erase'
    if (-not [int]::TryParse($answer, [ref]$DiskNumber)) { throw 'Not a disk number.' }
}

$target = Get-EligibleDisk | Where-Object { $_.Number -eq $DiskNumber }
if (-not $target) {
    throw "Disk $DiskNumber is not a removable disk. ImageHub refuses to write to internal storage."
}

Write-Host ''
Write-Host ("  About to ERASE disk {0}: {1} ({2:N1} GB)" -f `
    $target.Number, $target.FriendlyName, ($target.Size / 1GB)) -ForegroundColor Yellow
if (-not $Force) {
    $confirm = Read-Host '  Type ERASE to continue'
    if ($confirm -ne 'ERASE') { Write-Host '  Cancelled.'; return }
}

$Secrets = Get-Secrets -TemplatePath $Template -Config $Config

# --- Erase and format -------------------------------------------------------
Write-Step "Erasing disk $DiskNumber and creating a FAT32 volume"
# FAT32 because UEFI firmware is only guaranteed to read FAT - the same reason
# the macOS build path splits install.wim.

# The USB stick itself is always MBR - it's the most widely bootable layout for
# Windows Setup media. The template's partitionStyle describes the layout of the
# *target machine's* disk, which the answer file applies during Setup.
Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false
Initialize-Disk -Number $DiskNumber -PartitionStyle MBR -ErrorAction SilentlyContinue
$partition = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -IsActive
$volume = Format-Volume -Partition $partition -FileSystem FAT32 -NewFileSystemLabel $VolumeLabel -Force -Confirm:$false
if (-not $partition.DriveLetter) {
    $partition | Add-PartitionAccessPath -AssignDriveLetter
    $partition = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $partition.PartitionNumber
}
$usbRoot = "$($partition.DriveLetter):\"
Write-Ok "Formatted as $VolumeLabel at $usbRoot"

# --- Mount the ISO ----------------------------------------------------------
Write-Step 'Mounting the ISO'
$mounted = Mount-DiskImage -ImagePath (Resolve-Path $Iso).Path -PassThru
try {
    $isoLetter = ($mounted | Get-Volume).DriveLetter
    $isoRoot = "${isoLetter}:\"
    Write-Ok "Mounted at $isoRoot"

    # --- Copy everything except the install image ---------------------------
    Write-Step 'Copying Windows Setup files'
    & robocopy.exe $isoRoot $usbRoot /E /NFL /NDL /NJH /NJS /NP /XF install.wim install.esd | Out-Null
    # robocopy uses exit codes 0-7 for success.
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE" }
    Write-Ok 'Boot files copied.'

    # --- install.wim, split if needed ---------------------------------------
    Write-Step 'Writing the install image'
    $customWim = Get-Setting (Get-Setting $Config 'windows') 'customWimPath' ''
    if ($customWim -and (Test-Path -LiteralPath $customWim)) {
        $installSource = (Resolve-Path $customWim).Path
        Write-Note "Using the captured image $([System.IO.Path]::GetFileName($installSource))"
    } elseif (Test-Path -LiteralPath (Join-Path $isoRoot 'sources\install.wim')) {
        $installSource = Join-Path $isoRoot 'sources\install.wim'
    } elseif (Test-Path -LiteralPath (Join-Path $isoRoot 'sources\install.esd')) {
        $installSource = Join-Path $isoRoot 'sources\install.esd'
    } else {
        throw 'This ISO has no sources\install.wim or install.esd.'
    }

    $installSize = (Get-Item -LiteralPath $installSource).Length
    $destinationSources = Join-Path $usbRoot 'sources'
    New-Item -ItemType Directory -Path $destinationSources -Force | Out-Null

    if ($installSize -lt 4GB) {
        Copy-Item -LiteralPath $installSource `
            -Destination (Join-Path $destinationSources ([System.IO.Path]::GetFileName($installSource))) -Force
        Write-Ok "Copied $([System.IO.Path]::GetFileName($installSource)) ($([math]::Round($installSize / 1GB, 2)) GB)."
    } else {
        Write-Note "install image is $([math]::Round($installSize / 1GB, 2)) GB - splitting for FAT32."
        & dism.exe /Split-Image /ImageFile:"$installSource" `
            /SWMFile:"$(Join-Path $destinationSources 'install.swm')" /FileSize:3800 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "DISM /Split-Image failed with $LASTEXITCODE" }
        $parts = @(Get-ChildItem -LiteralPath $destinationSources -Filter '*.swm')
        Write-Ok "Wrote $($parts.Count) split part(s)."
    }

    # --- Answer file --------------------------------------------------------
    Write-Step 'Generating autounattend.xml'
    $answerFile = New-AnswerFile -Config $Config -Secrets $Secrets
    Set-Content -LiteralPath (Join-Path $usbRoot 'autounattend.xml') -Value $answerFile -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $destinationSources 'autounattend.xml') -Value $answerFile -Encoding UTF8
    Write-Ok 'Answer file written.'

    # --- Payload ------------------------------------------------------------
    Write-Step 'Writing the provisioning payload'
    $payloadRoot = New-Payload -Config $Config -Secrets $Secrets -VolumeRoot $usbRoot -TemplatePath $Template
    Write-Ok "Payload written to $payloadRoot"

    # --- Verify -------------------------------------------------------------
    Write-Step 'Verifying the media'
    $missing = @()
    foreach ($relative in @('bootmgr', 'boot\bcd', 'sources\boot.wim', 'autounattend.xml', 'ImageHub\Provision.ps1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $usbRoot $relative))) { $missing += $relative }
    }
    $hasInstall = @('install.wim', 'install.esd', 'install.swm') |
        Where-Object { Test-Path -LiteralPath (Join-Path $destinationSources $_) }
    if (-not $hasInstall) { $missing += 'sources\install.wim (or .swm)' }
    if ($missing.Count -gt 0) { throw "The finished drive is missing: $($missing -join ', ')" }
    if (-not (Test-Path -LiteralPath (Join-Path $usbRoot 'efi\boot\bootx64.efi'))) {
        Write-Warn 'No efi\boot\bootx64.efi - this media will only boot in legacy BIOS mode.'
    }
    Write-Ok 'Boot files, install image, answer file, and payload all present.'
} finally {
    Dismount-DiskImage -ImagePath (Resolve-Path $Iso).Path | Out-Null
}

Write-Host ''
Write-Host "  Drive ready at $usbRoot" -ForegroundColor Green
Write-Host '  Boot the target machine from it; Setup runs unattended from there.' -ForegroundColor Gray
Write-Host '  The drive holds the template passwords in clear text - treat it like a key.' -ForegroundColor Yellow
Write-Host ''
