<#
.SYNOPSIS
    Full-screen branded progress screen shown while ImageHub provisions a machine.

.DESCRIPTION
    Runs as its own process and polls a status file that Provision.ps1 writes.
    That separation is deliberate: provisioning does long synchronous work (a
    single winget install can take minutes), so a window living in the same
    thread would sit there greyed out and "Not Responding". Here the UI stays
    responsive no matter how long a step takes, and nothing the UI does can
    block or fail the provisioning run.

    Launched automatically by Provision.ps1 unless the template turns it off.
    Closing this window does not affect provisioning.

.PARAMETER StatusPath
    JSON file to poll. Written by Provision.ps1.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$StatusPath
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

# --- Palette -----------------------------------------------------------------
$background = [System.Drawing.Color]::FromArgb(18, 20, 24)
$card       = [System.Drawing.Color]::FromArgb(28, 31, 37)
$primary    = [System.Drawing.Color]::FromArgb(41, 102, 235)
$textMain   = [System.Drawing.Color]::FromArgb(240, 242, 245)
$textDim    = [System.Drawing.Color]::FromArgb(150, 156, 166)
$good       = [System.Drawing.Color]::FromArgb(52, 199, 89)
$bad        = [System.Drawing.Color]::FromArgb(255, 92, 92)

function Read-Status {
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        try {
            if (-not (Test-Path -LiteralPath $StatusPath)) { return $null }
            $raw = Get-Content -LiteralPath $StatusPath -Raw -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
            return $raw | ConvertFrom-Json
        } catch {
            # Provision.ps1 may be mid-write; a brief retry is cheaper than
            # guarding every write with a lock.
            Start-Sleep -Milliseconds 120
        }
    }
    return $null
}

function Get-Field {
    param($Object, [string]$Name, $Default = '')
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

$status = Read-Status

# --- Window ------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Setting up this computer'
$form.FormBorderStyle = 'None'
$form.WindowState = 'Maximized'
$form.BackColor = $background
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.KeyPreview = $true

# Escape is a deliberate escape hatch for a technician who needs the desktop.
$form.add_KeyDown({
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $form.Close() }
})

$panel = New-Object System.Windows.Forms.Panel
$panel.BackColor = $card
$panel.Size = New-Object System.Drawing.Size(760, 420)
$form.Controls.Add($panel)

function Set-PanelCentre {
    $panel.Left = [int](($form.ClientSize.Width - $panel.Width) / 2)
    $panel.Top = [int](($form.ClientSize.Height - $panel.Height) / 2)
}
$form.add_Resize({ Set-PanelCentre })

# Logo, or a neutral placeholder when the template has none.
$logoBox = New-Object System.Windows.Forms.PictureBox
$logoBox.SizeMode = 'Zoom'
$logoBox.Size = New-Object System.Drawing.Size(180, 90)
$logoBox.Location = New-Object System.Drawing.Point(290, 40)
$logoBox.BackColor = [System.Drawing.Color]::Transparent
$logoPath = Get-Field $status 'logo' ''
if ($logoPath -and (Test-Path -LiteralPath $logoPath)) {
    try {
        $logoBox.Image = [System.Drawing.Image]::FromFile($logoPath)
    } catch { }
}
$panel.Controls.Add($logoBox)

$title = New-Object System.Windows.Forms.Label
$title.AutoSize = $false
$title.Size = New-Object System.Drawing.Size(700, 34)
$title.Location = New-Object System.Drawing.Point(30, 148)
$title.TextAlign = 'MiddleCenter'
$title.ForeColor = $textMain
$title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 17)
$organization = Get-Field $status 'organizationName' ''
$title.Text = if ($organization) {
    "Setting up this computer for $organization"
} else {
    'Setting up this computer'
}
$panel.Controls.Add($title)

$stepLabel = New-Object System.Windows.Forms.Label
$stepLabel.AutoSize = $false
$stepLabel.Size = New-Object System.Drawing.Size(700, 28)
$stepLabel.Location = New-Object System.Drawing.Point(30, 196)
$stepLabel.TextAlign = 'MiddleCenter'
$stepLabel.ForeColor = $textMain
$stepLabel.Font = New-Object System.Drawing.Font('Segoe UI', 12)
$stepLabel.Text = 'Starting...'
$panel.Controls.Add($stepLabel)

$detailLabel = New-Object System.Windows.Forms.Label
$detailLabel.AutoSize = $false
$detailLabel.Size = New-Object System.Drawing.Size(700, 24)
$detailLabel.Location = New-Object System.Drawing.Point(30, 224)
$detailLabel.TextAlign = 'MiddleCenter'
$detailLabel.ForeColor = $textDim
$detailLabel.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$panel.Controls.Add($detailLabel)

$bar = New-Object System.Windows.Forms.ProgressBar
$bar.Size = New-Object System.Drawing.Size(640, 8)
$bar.Location = New-Object System.Drawing.Point(60, 268)
$bar.Style = 'Marquee'
$bar.MarqueeAnimationSpeed = 30
$panel.Controls.Add($bar)

$noteLabel = New-Object System.Windows.Forms.Label
$noteLabel.AutoSize = $false
$noteLabel.Size = New-Object System.Drawing.Size(640, 44)
$noteLabel.Location = New-Object System.Drawing.Point(60, 296)
$noteLabel.TextAlign = 'MiddleCenter'
$noteLabel.ForeColor = $textDim
$noteLabel.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$panel.Controls.Add($noteLabel)

$footer = New-Object System.Windows.Forms.Label
$footer.AutoSize = $false
$footer.Size = New-Object System.Drawing.Size(700, 22)
$footer.Location = New-Object System.Drawing.Point(30, 352)
$footer.TextAlign = 'MiddleCenter'
$footer.ForeColor = $textDim
$footer.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$supportParts = @()
$phone = Get-Field $status 'supportPhone' ''
$url = Get-Field $status 'supportUrl' ''
if ($phone) { $supportParts += $phone }
if ($url) { $supportParts += $url }
$footer.Text = if ($supportParts.Count -gt 0) {
    'Need help? ' + ($supportParts -join '   -   ')
} else {
    'Please leave this computer switched on.'
}
$panel.Controls.Add($footer)

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = 'Close'
$closeButton.Size = New-Object System.Drawing.Size(120, 32)
$closeButton.Location = New-Object System.Drawing.Point(320, 316)
$closeButton.FlatStyle = 'Flat'
$closeButton.BackColor = $primary
$closeButton.ForeColor = [System.Drawing.Color]::White
$closeButton.Visible = $false
$closeButton.add_Click({ $form.Close() })
$panel.Controls.Add($closeButton)

# --- Polling -----------------------------------------------------------------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 700
$timer.add_Tick({
    $current = Read-Status
    if ($null -eq $current) { return }

    $state = Get-Field $current 'state' 'running'
    $stepLabel.Text = Get-Field $current 'step' 'Working...'
    $detailLabel.Text = Get-Field $current 'detail' ''

    $index = [int](Get-Field $current 'index' 0)
    $total = [int](Get-Field $current 'total' 0)
    if ($total -gt 0 -and $index -ge 0) {
        if ($bar.Style -ne 'Continuous') {
            $bar.Style = 'Continuous'
            $bar.Maximum = 100
        }
        $bar.Value = [Math]::Min(100, [int](($index / [double]$total) * 100))
    }

    if ($state -eq 'done' -or $state -eq 'failed') {
        $timer.Stop()
        $bar.Style = 'Continuous'
        $bar.Maximum = 100
        $bar.Value = 100

        $failures = @(Get-Field $current 'failures' @())
        $warnings = @(Get-Field $current 'warnings' @())

        if ($state -eq 'failed' -or $failures.Count -gt 0) {
            $stepLabel.ForeColor = $bad
            $stepLabel.Text = 'Setup finished with problems'
            $detailLabel.Text = "$($failures.Count) step(s) failed - see C:\ImageHub\logs"
        } else {
            $stepLabel.ForeColor = $good
            $stepLabel.Text = 'This computer is ready'
            $detailLabel.Text = if ($warnings.Count -gt 0) {
                "Finished with $($warnings.Count) warning(s) - see C:\ImageHub\logs"
            } else {
                'Provisioning completed successfully.'
            }
        }

        $note = Get-Field $current 'note' ''
        if ($note) { $noteLabel.Text = $note }
        $closeButton.Visible = $true
    }
})

$form.add_Shown({
    Set-PanelCentre
    $timer.Start()
})

[System.Windows.Forms.Application]::Run($form)
