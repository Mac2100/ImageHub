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

    It also collects the end-user account details when the template asks for
    them at first boot. That used to be a separate dialog owned by
    Provision.ps1, which meant this screen had to stand down while the dialog
    was up -- and every Lenovo and installer popup on the machine took the
    opportunity to cover it. Asking inside this window instead means the screen
    never has to yield.

    The layout is computed from the screen it lands on rather than being a fixed
    card, so there is no floating box on a large display, and the process is
    marked DPI-aware so Windows renders the text rather than bitmap-stretching a
    smaller window.

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

<#
    The Start menu, the taskbar and third-party popups all render above a plain
    TopMost form, and setting TopMost once at creation does not survive another
    process taking the foreground. Re-asserting the Z-order through SetWindowPos
    every tick does, and it does so without stealing activation from our own text
    boxes.

    SetProcessDPIAware has to run before any window exists. Without it Windows
    hands PowerShell a virtualised, smaller desktop and stretches the result,
    which is why the screen looked soft on a high-DPI laptop panel.
#>
Add-Type -Namespace ImageHub -Name Win -UsingNamespace System.Text -MemberDefinition @'
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter,
        int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
'@

try { [void][ImageHub.Win]::SetProcessDPIAware() } catch { }
[System.Windows.Forms.Application]::EnableVisualStyles()

$HWND_TOPMOST = [IntPtr](-1)
# NOSIZE | NOMOVE | NOACTIVATE
$SWP_KEEP = 0x0001 -bor 0x0002 -bor 0x0010
$OurProcessID = [uint32][System.Diagnostics.Process]::GetCurrentProcess().Id

# Window classes belonging to the shell's own flyouts. These sit above every
# TopMost window by design, so the only way past them is to close them -- an
# Escape keystroke does that without touching anything else.
$ShellClasses = @(
    'Windows.UI.Core.CoreWindow',
    'XamlExplorerHostIslandWindow',
    'Shell_TrayWnd',
    'Shell_SecondaryTrayWnd',
    'MultitaskingViewFrame'
)

# --- Palette -----------------------------------------------------------------
# One flat backdrop, no card. A second slightly-lighter panel read as a box
# floating in the middle of a large display.
$background = [System.Drawing.Color]::FromArgb(18, 20, 24)
$primary    = [System.Drawing.Color]::FromArgb(41, 102, 235)
$textMain   = [System.Drawing.Color]::FromArgb(240, 242, 245)
$textDim    = [System.Drawing.Color]::FromArgb(158, 164, 174)
$fieldBack  = [System.Drawing.Color]::FromArgb(44, 48, 56)
# Full-screen banner colours for the finished state - dark enough for white text,
# saturated enough to read as a state change from across a room.
$bannerGood = [System.Drawing.Color]::FromArgb(24, 118, 62)
$bannerBad  = [System.Drawing.Color]::FromArgb(140, 32, 32)

$confettiColours = @(
    [System.Drawing.Color]::FromArgb(255, 214, 79),
    [System.Drawing.Color]::FromArgb(255, 122, 89),
    [System.Drawing.Color]::FromArgb(120, 214, 255),
    [System.Drawing.Color]::FromArgb(167, 139, 250),
    [System.Drawing.Color]::FromArgb(94, 234, 152),
    [System.Drawing.Color]::FromArgb(255, 255, 255)
)

$AnswerPath = Join-Path (Split-Path -Parent $StatusPath) 'answer.json'

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
# Every bound is computed in Set-Layout, so WinForms must not also scale them.
$form.AutoScaleMode = 'None'
# Confetti is painted straight onto the form, so the background needs to
# double-buffer or it tears.
$form.GetType().GetProperty('DoubleBuffered',
    [System.Reflection.BindingFlags]'Instance,NonPublic').SetValue($form, $true, $null)

$script:Mode = 'running'
$script:Prompting = $false

# Escape is a deliberate escape hatch for a technician who needs the desktop --
# but not while we are the only thing asking a question.
$form.add_KeyDown({
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape -and -not $script:Prompting) {
        $form.Close()
    }
})

function New-Caption {
    param([System.Drawing.Color]$Colour, [string]$Align = 'MiddleCenter')
    $label = New-Object System.Windows.Forms.Label
    $label.AutoSize = $false
    $label.TextAlign = $Align
    $label.ForeColor = $Colour
    # BackColor is left unset on purpose: it is an ambient property, so every
    # label follows the form when the finish state repaints it green or red.
    $form.Controls.Add($label)
    return $label
}

# Logo, or nothing at all when the template has none.
$logoBox = New-Object System.Windows.Forms.PictureBox
$logoBox.SizeMode = 'Zoom'
$logoBox.BackColor = [System.Drawing.Color]::Transparent
$logoPath = Get-Field $status 'logo' ''
if ($logoPath -and (Test-Path -LiteralPath $logoPath)) {
    try {
        # Not Image::FromFile - that holds the file open for the life of the
        # Image, and the OEM information step later needs to read the same file.
        # On a real run it failed with "being used by another process".
        $logoBytes = [System.IO.File]::ReadAllBytes($logoPath)
        $logoStream = New-Object System.IO.MemoryStream(,$logoBytes)
        $logoBox.Image = [System.Drawing.Image]::FromStream($logoStream)
    } catch { }
}
$form.Controls.Add($logoBox)

$title = New-Caption $textMain
$organization = Get-Field $status 'organizationName' ''
$title.Text = if ($organization) {
    "Setting up this computer for $organization"
} else {
    'Setting up this computer'
}

<#
    The finish badge: a filled disc with a hand-drawn tick or exclamation. Drawn
    rather than set from a glyph font, because the payload scripts are held to
    plain ASCII (Windows PowerShell 5.1 decodes a BOM-less file as ANSI, so a
    stray non-ASCII character has broken this script before).
#>
$script:BadgeMode = 'good'
$badge = New-Object System.Windows.Forms.Panel
$badge.BackColor = [System.Drawing.Color]::Transparent
$badge.Visible = $false
$badge.add_Paint({
    $g = $_.Graphics
    $g.SmoothingMode = 'AntiAlias'
    $side = [Math]::Min($badge.Width, $badge.Height)
    $inset = [int]($side * 0.02)
    $disc = [int]($side - $inset * 2)

    $fill = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
    $g.FillEllipse($fill, $inset, $inset, $disc, $disc)
    $fill.Dispose()

    $ink = if ($script:BadgeMode -eq 'good') { $bannerGood } else { $bannerBad }
    $pen = New-Object System.Drawing.Pen ($ink, [float]($side * 0.105))
    $pen.StartCap = 'Round'
    $pen.EndCap = 'Round'
    if ($script:BadgeMode -eq 'good') {
        $g.DrawLines($pen, [System.Drawing.Point[]]@(
            (New-Object System.Drawing.Point([int]($side * 0.27), [int]($side * 0.53))),
            (New-Object System.Drawing.Point([int]($side * 0.44), [int]($side * 0.71))),
            (New-Object System.Drawing.Point([int]($side * 0.75), [int]($side * 0.32)))
        ))
    } else {
        $g.DrawLine($pen, [int]($side * 0.5), [int]($side * 0.25),
                          [int]($side * 0.5), [int]($side * 0.60))
        $g.DrawLine($pen, [int]($side * 0.5), [int]($side * 0.76),
                          [int]($side * 0.5), [int]($side * 0.77))
    }
    $pen.Dispose()
})
$form.Controls.Add($badge)

# Hidden during the run; revealed at the end so "finished" is the largest thing
# on the screen rather than a reworded status line.
$headingLabel = New-Caption ([System.Drawing.Color]::White)
$headingLabel.Visible = $false

$stepLabel = New-Caption $textMain
$stepLabel.Text = 'Starting...'

$detailLabel = New-Caption $textDim

$bar = New-Object System.Windows.Forms.ProgressBar
$bar.Style = 'Marquee'
$bar.MarqueeAnimationSpeed = 30
$form.Controls.Add($bar)

# Finish-state summary: what actually happened, in plain lines, so a technician
# can hand the machine over without opening a log.
$summaryLabel = New-Caption ([System.Drawing.Color]::FromArgb(232, 244, 236)) 'TopCenter'
$summaryLabel.Visible = $false

$noteLabel = New-Caption $textDim
$footer = New-Caption $textDim
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

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = 'Close this screen'
$closeButton.FlatStyle = 'Flat'
$closeButton.BackColor = [System.Drawing.Color]::White
$closeButton.ForeColor = [System.Drawing.Color]::Black
$closeButton.Visible = $false
$closeButton.add_Click({ $form.Close() })
$form.Controls.Add($closeButton)

# --- End-user account, asked inside this window -------------------------------
$accountPanel = New-Object System.Windows.Forms.Panel
$accountPanel.BackColor = $background
$accountPanel.Visible = $false
$form.Controls.Add($accountPanel)

function New-FieldLabel {
    $label = New-Object System.Windows.Forms.Label
    $label.AutoSize = $false
    $label.ForeColor = $textDim
    $accountPanel.Controls.Add($label)
    return $label
}

function New-FieldBox {
    param([switch]$Secret)
    $box = New-Object System.Windows.Forms.TextBox
    $box.BackColor = $fieldBack
    $box.ForeColor = $textMain
    $box.BorderStyle = 'FixedSingle'
    if ($Secret) { $box.UseSystemPasswordChar = $true }
    $accountPanel.Controls.Add($box)
    return $box
}

$accountHeading = New-Object System.Windows.Forms.Label
$accountHeading.AutoSize = $false
$accountHeading.TextAlign = 'MiddleCenter'
$accountHeading.ForeColor = $textMain
$accountHeading.Text = 'Set up the account for whoever receives this machine'
$accountPanel.Controls.Add($accountHeading)

$userLabel = New-FieldLabel
$userLabel.Text = 'Username'
$userBox = New-FieldBox
$nameLabel = New-FieldLabel
$nameLabel.Text = 'Full name (optional)'
$nameBox = New-FieldBox
$passLabel = New-FieldLabel
$passLabel.Text = 'Password'
$passBox = New-FieldBox -Secret
$confirmLabel = New-FieldLabel
$confirmLabel.Text = 'Confirm password'
$confirmBox = New-FieldBox -Secret

$adminBox = New-Object System.Windows.Forms.CheckBox
$adminBox.Text = 'Make this account an administrator'
$adminBox.ForeColor = $textMain
$accountPanel.Controls.Add($adminBox)

$changeBox = New-Object System.Windows.Forms.CheckBox
$changeBox.Text = 'Must change password at first sign-in'
$changeBox.ForeColor = $textMain
$changeBox.Checked = $true
$accountPanel.Controls.Add($changeBox)

$accountError = New-Object System.Windows.Forms.Label
$accountError.AutoSize = $false
$accountError.ForeColor = [System.Drawing.Color]::FromArgb(255, 140, 140)
$accountPanel.Controls.Add($accountError)

$accountCountdown = New-Object System.Windows.Forms.Label
$accountCountdown.AutoSize = $false
$accountCountdown.TextAlign = 'MiddleLeft'
$accountCountdown.ForeColor = $textDim
$accountPanel.Controls.Add($accountCountdown)

$createButton = New-Object System.Windows.Forms.Button
$createButton.Text = 'Create account'
$createButton.FlatStyle = 'Flat'
$createButton.BackColor = $primary
$createButton.ForeColor = [System.Drawing.Color]::White
$accountPanel.Controls.Add($createButton)

$script:AnswerSent = $false
$createButton.add_Click({
    $accountError.Text = ''
    if ([string]::IsNullOrWhiteSpace($userBox.Text)) {
        $accountError.Text = 'A username is required.'
        return
    }
    if ($passBox.Text -ne $confirmBox.Text) {
        $accountError.Text = 'The passwords do not match.'
        return
    }
    try {
        [ordered]@{
            username   = $userBox.Text.Trim()
            fullName   = $nameBox.Text.Trim()
            password   = $passBox.Text
            admin      = [bool]$adminBox.Checked
            mustChange = [bool]$changeBox.Checked
        } | ConvertTo-Json | Set-Content -LiteralPath $AnswerPath -Encoding UTF8
        $script:AnswerSent = $true
        $script:Prompting = $false
        $script:Mode = 'running'
        Set-Layout
        $stepLabel.Text = 'Creating the account...'
        # Nothing should linger in the boxes once it is on its way.
        $passBox.Clear()
        $confirmBox.Clear()
    } catch {
        $accountError.Text = "Couldn't hand those details to provisioning: $($_.Exception.Message)"
    }
})

# --- Layout -------------------------------------------------------------------
<#
    Everything is positioned from the screen it actually lands on. Fonts are
    given in points and therefore scale themselves with the display's DPI now
    that the process is DPI-aware; pixel geometry is scaled here, and label
    heights come from the font rather than being guessed, so a 4K panel and a
    1080p panel both look deliberate.
#>
function Set-Layout {
    $w = $form.ClientSize.Width
    $h = $form.ClientSize.Height
    if ($w -le 0 -or $h -le 0) { return }

    $u = [double]$h / 1080.0
    if ($u -lt 0.75) { $u = 0.75 }

    $contentW = [int][Math]::Min($w * 0.78, 1600 * $u)
    $left = [int](($w - $contentW) / 2)

    $titleFont   = New-Object System.Drawing.Font('Segoe UI Semibold', [float](19 * $u))
    $headingFont = New-Object System.Drawing.Font('Segoe UI', [float](40 * $u), [System.Drawing.FontStyle]::Bold)
    $stepFont    = New-Object System.Drawing.Font('Segoe UI', [float](14 * $u))
    $detailFont  = New-Object System.Drawing.Font('Segoe UI', [float](11.5 * $u))
    $smallFont   = New-Object System.Drawing.Font('Segoe UI', [float](10 * $u))
    $buttonFont  = New-Object System.Drawing.Font('Segoe UI', [float](13 * $u), [System.Drawing.FontStyle]::Bold)

    $title.Font = $titleFont
    $headingLabel.Font = $headingFont
    $stepLabel.Font = $stepFont
    $detailLabel.Font = $detailFont
    $summaryLabel.Font = $detailFont
    $noteLabel.Font = $smallFont
    $footer.Font = $smallFont
    $closeButton.Font = $buttonFont

    function Line { param($Control, [double]$Multiple = 1.6) return [int]($Control.Font.Height * $Multiple) }

    $gap = [int](26 * $u)
    $logoH = [int](130 * $u)
    $logoW = [int](340 * $u)
    $badgeSide = [int](150 * $u)

    # Measure the block first so it can be centred vertically as a whole.
    $blocks = @()
    switch ($script:Mode) {
        'prompt' {
            $blocks = @($logoH, (Line $title), (Line $accountHeading 1.8), [int](330 * $u))
        }
        'finished' {
            $blocks = @($logoH, $badgeSide, (Line $headingLabel 1.25), (Line $stepLabel),
                        [int]((Line $summaryLabel) * 5), (Line $closeButton 2.6))
        }
        default {
            $blocks = @($logoH, (Line $title), (Line $stepLabel), (Line $detailLabel),
                        [int](12 * $u), (Line $noteLabel 2.4))
        }
    }
    $blockH = 0
    foreach ($part in $blocks) { $blockH += $part + $gap }
    $y = [int](($h - $blockH) / 2)
    if ($y -lt [int](40 * $u)) { $y = [int](40 * $u) }

    $logoBox.SetBounds([int](($w - $logoW) / 2), $y, $logoW, $logoH)
    $logoBox.Visible = ($null -ne $logoBox.Image)
    if ($logoBox.Visible) { $y += $logoH + $gap }

    if ($script:Mode -eq 'finished') {
        $badge.SetBounds([int](($w - $badgeSide) / 2), $y, $badgeSide, $badgeSide)
        $y += $badgeSide + $gap
        $headingLabel.SetBounds($left, $y, $contentW, (Line $headingLabel 1.25))
        $y += (Line $headingLabel 1.25) + [int]($gap / 2)
        $stepLabel.SetBounds($left, $y, $contentW, (Line $stepLabel))
        $y += (Line $stepLabel) + $gap
        $summaryLabel.SetBounds($left, $y, $contentW, [int]((Line $summaryLabel) * 5))
        $y += [int]((Line $summaryLabel) * 5) + $gap
        $closeButton.SetBounds([int](($w - [int](340 * $u)) / 2), $y,
                               [int](340 * $u), (Line $closeButton 2.2))
    } else {
        $title.SetBounds($left, $y, $contentW, (Line $title))
        $y += (Line $title) + [int]($gap / 2)

        if ($script:Mode -eq 'prompt') {
            $accountPanel.SetBounds($left, $y, $contentW, [int](400 * $u))
            Set-AccountLayout $contentW $u $detailFont $smallFont $buttonFont
        } else {
            $stepLabel.SetBounds($left, $y, $contentW, (Line $stepLabel))
            $y += (Line $stepLabel)
            $detailLabel.SetBounds($left, $y, $contentW, (Line $detailLabel))
            $y += (Line $detailLabel) + $gap
            $bar.SetBounds($left, $y, $contentW, [int](12 * $u))
            $y += [int](12 * $u) + $gap
            $noteLabel.SetBounds($left, $y, $contentW, (Line $noteLabel 2.4))
        }
    }

    $footer.SetBounds($left, $h - [int](70 * $u), $contentW, (Line $footer 1.8))

    # Visibility by mode, so nothing can paint over anything else. This is the
    # bug that put a dark rectangle over the password fields: the note label was
    # still visible and, having been added to the form first, sat in front of the
    # account panel.
    $running = ($script:Mode -eq 'running')
    $prompting = ($script:Mode -eq 'prompt')
    $finished = ($script:Mode -eq 'finished')

    $title.Visible = -not $finished
    $stepLabel.Visible = ($running -or $finished)
    $detailLabel.Visible = $running
    $bar.Visible = $running
    $noteLabel.Visible = $running
    $accountPanel.Visible = $prompting
    $badge.Visible = $finished
    $headingLabel.Visible = $finished
    $summaryLabel.Visible = $finished
    $closeButton.Visible = $finished

    # WinForms z-order runs front-to-back with index 0 at the front, and
    # Controls.Add appends to the back -- so whatever is meant to be on top has
    # to say so.
    if ($prompting) { $accountPanel.BringToFront() }
    if ($finished) {
        $badge.BringToFront()
        $closeButton.BringToFront()
    }
}

function Set-AccountLayout {
    param([int]$Width, [double]$U, $FieldFont, $SmallFont, $ButtonFont)

    $accountHeading.Font = New-Object System.Drawing.Font('Segoe UI Semibold', [float](15 * $U))
    foreach ($label in @($userLabel, $nameLabel, $passLabel, $confirmLabel)) {
        $label.Font = $SmallFont
    }
    foreach ($box in @($userBox, $nameBox, $passBox, $confirmBox)) { $box.Font = $FieldFont }
    $adminBox.Font = $SmallFont
    $changeBox.Font = $SmallFont
    $accountError.Font = $SmallFont
    $accountCountdown.Font = $SmallFont
    $createButton.Font = $ButtonFont

    $columnGap = [int](40 * $U)
    $columnW = [int](($Width - $columnGap) / 2)
    $labelH = [int]($SmallFont.Height * 1.5)
    # A single-line TextBox sizes its own height from the font; ask for a
    # generous one and let it settle rather than clipping the text.
    $boxH = [int]($FieldFont.Height * 1.8)
    $rowGap = [int](22 * $U)

    $y = 0
    $accountHeading.SetBounds(0, $y, $Width, [int]($accountHeading.Font.Height * 1.7))
    $y += [int]($accountHeading.Font.Height * 1.7) + [int](18 * $U)

    $userLabel.SetBounds(0, $y, $columnW, $labelH)
    $nameLabel.SetBounds($columnW + $columnGap, $y, $columnW, $labelH)
    $y += $labelH
    $userBox.SetBounds(0, $y, $columnW, $boxH)
    $nameBox.SetBounds($columnW + $columnGap, $y, $columnW, $boxH)
    $y += $userBox.Height + $rowGap

    $passLabel.SetBounds(0, $y, $columnW, $labelH)
    $confirmLabel.SetBounds($columnW + $columnGap, $y, $columnW, $labelH)
    $y += $labelH
    $passBox.SetBounds(0, $y, $columnW, $boxH)
    $confirmBox.SetBounds($columnW + $columnGap, $y, $columnW, $boxH)
    $y += $passBox.Height + $rowGap

    $checkH = [int]($SmallFont.Height * 1.8)
    $adminBox.SetBounds(0, $y, $columnW, $checkH)
    $changeBox.SetBounds($columnW + $columnGap, $y, $columnW, $checkH)
    $y += $checkH + [int](8 * $U)

    $accountError.SetBounds(0, $y, $Width, $labelH)
    $y += $labelH + [int](12 * $U)

    $buttonW = [int](300 * $U)
    $buttonH = [int]($ButtonFont.Height * 2.2)
    $accountCountdown.SetBounds(0, $y, $Width - $buttonW - $columnGap, $buttonH)
    $createButton.SetBounds($Width - $buttonW, $y, $buttonW, $buttonH)

    $accountPanel.Height = $y + $buttonH
}

$form.add_Resize({ Set-Layout })

# --- Confetti ----------------------------------------------------------------
# Painted on the form itself, so it falls across the whole screen.
$script:Particles = New-Object System.Collections.ArrayList
$script:ConfettiFrames = 0

$confettiTimer = New-Object System.Windows.Forms.Timer
$confettiTimer.Interval = 33
$confettiTimer.add_Tick({
    $script:ConfettiFrames++
    $floor = $form.ClientSize.Height + 80
    foreach ($p in $script:Particles) {
        $p.X += $p.VX
        $p.Y += $p.VY
        $p.VY += 0.22
        $p.Angle += $p.Spin
    }
    $form.Invalidate()
    $airborne = @($script:Particles | Where-Object { $_.Y -lt $floor }).Count
    if ($script:ConfettiFrames -gt 240 -or $airborne -eq 0) {
        $confettiTimer.Stop()
        $script:Particles.Clear()
        $form.Invalidate()
    }
})

function Start-Confetti {
    $width = [Math]::Max(800, $form.ClientSize.Width)
    $scale = [Math]::Max(1.0, $form.ClientSize.Height / 1080.0)
    for ($i = 0; $i -lt 200; $i++) {
        [void]$script:Particles.Add([pscustomobject]@{
            X      = [double](Get-Random -Minimum 0 -Maximum $width)
            Y      = [double](Get-Random -Minimum -900 -Maximum 0)
            VX     = [double]((Get-Random -Minimum -20 -Maximum 20) / 10.0)
            VY     = [double]((Get-Random -Minimum 18 -Maximum 75) / 10.0)
            Angle  = [double](Get-Random -Minimum 0 -Maximum 360)
            Spin   = [double]((Get-Random -Minimum -80 -Maximum 80) / 10.0)
            W      = [int]((Get-Random -Minimum 8 -Maximum 16) * $scale)
            H      = [int]((Get-Random -Minimum 14 -Maximum 26) * $scale)
            Colour = $confettiColours[(Get-Random -Minimum 0 -Maximum $confettiColours.Count)]
        })
    }
    $script:ConfettiFrames = 0
    $confettiTimer.Start()
}

$form.add_Paint({
    if ($script:Particles.Count -eq 0) { return }
    $g = $_.Graphics
    $g.SmoothingMode = 'AntiAlias'
    foreach ($p in $script:Particles) {
        $brush = New-Object System.Drawing.SolidBrush ($p.Colour)
        $state = $g.Save()
        $g.TranslateTransform([float]$p.X, [float]$p.Y)
        $g.RotateTransform([float]$p.Angle)
        $g.FillRectangle($brush, [int](-$p.W / 2), [int](-$p.H / 2), $p.W, $p.H)
        $g.Restore($state)
        $brush.Dispose()
    }
})

# --- Keeping this screen in front ---------------------------------------------
function Assert-OnTop {
    [void][ImageHub.Win]::SetWindowPos($form.Handle, $HWND_TOPMOST, 0, 0, 0, 0, $SWP_KEEP)

    $foreground = [ImageHub.Win]::GetForegroundWindow()
    if ($foreground -eq $form.Handle) { return }

    $owner = [uint32]0
    [void][ImageHub.Win]::GetWindowThreadProcessId($foreground, [ref]$owner)
    # Our own windows are welcome in front - that is how typing works.
    if ($owner -eq $OurProcessID) { return }

    $className = New-Object System.Text.StringBuilder 256
    [void][ImageHub.Win]::GetClassName($foreground, $className, $className.Capacity)
    if ($ShellClasses -contains $className.ToString()) {
        # The Start menu and taskbar flyouts outrank every TopMost window by
        # design, so being in front is not enough - they have to be closed.
        try { [System.Windows.Forms.SendKeys]::SendWait('{ESC}') } catch { }
    }

    [void][ImageHub.Win]::SetForegroundWindow($form.Handle)
}

# --- Polling -----------------------------------------------------------------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 700
$timer.add_Tick({
    $current = Read-Status
    if ($null -eq $current) { return }

    $state = Get-Field $current 'state' 'running'
    $finished = ($state -eq 'done' -or $state -eq 'failed')

    # Asking for the account happens in this window now, so there is no longer a
    # dialog of our own to stand aside for. The screen stays in front throughout.
    $wantsPrompt = (-not $finished) -and
        [bool](Get-Field $current 'prompting' $false) -and
        (-not $script:AnswerSent)
    if ($wantsPrompt -ne $script:Prompting) {
        $script:Prompting = $wantsPrompt
        $script:Mode = if ($wantsPrompt) { 'prompt' } else { 'running' }
        Set-Layout
        if ($wantsPrompt) {
            $userBox.Focus() | Out-Null
            try { [System.Media.SystemSounds]::Question.Play() } catch { }
        }
    }

    if ($script:Prompting) {
        $left = [int](Get-Field $current 'promptRemaining' 0)
        $accountCountdown.Text = if ($left -gt 0) {
            "Continues without an account in {0}:{1:D2}" -f [int]($left / 60), ($left % 60)
        } else { '' }
    } else {
        $stepLabel.Text = Get-Field $current 'step' 'Working...'
        $detailLabel.Text = Get-Field $current 'detail' ''
        $noteLabel.Text = ''
    }

    $index = [int](Get-Field $current 'index' 0)
    $total = [int](Get-Field $current 'total' 0)
    if ($total -gt 0 -and $index -ge 0) {
        if ($bar.Style -ne 'Continuous') {
            $bar.Style = 'Continuous'
            $bar.Maximum = 100
        }
        $bar.Value = [Math]::Min(100, [int](($index / [double]$total) * 100))
    }

    Assert-OnTop

    if ($finished) {
        $timer.Stop()

        $failures = @(Get-Field $current 'failures' @())
        $warnings = @(Get-Field $current 'warnings' @())
        $bad = ($state -eq 'failed' -or $failures.Count -gt 0)

        # Deliberately loud. A technician walked away from a finished machine and
        # closed this by hand because a changed line of small text did not read as
        # "done" - the whole screen changes colour, grows a badge, and throws
        # confetti.
        $script:Prompting = $false
        $script:BadgeMode = if ($bad) { 'bad' } else { 'good' }
        $script:Mode = 'finished'

        $form.BackColor = if ($bad) { $bannerBad } else { $bannerGood }
        $stepLabel.ForeColor = [System.Drawing.Color]::White
        $footer.ForeColor = [System.Drawing.Color]::FromArgb(224, 236, 228)

        $lines = @(Get-Field $current 'summary' @())
        $note = Get-Field $current 'note' ''
        if ($note) { $lines += "Note from IT: $note" }

        if ($bad) {
            $headingLabel.Text = 'FINISHED WITH PROBLEMS'
            $stepLabel.Text = "$($failures.Count) step(s) failed"
            $lines += 'See C:\ImageHub\logs before handing this machine over.'
        } else {
            $headingLabel.Text = 'ALL DONE'
            $stepLabel.Text = if ($warnings.Count -gt 0) {
                "This computer is ready - $($warnings.Count) warning(s) worth a look"
            } else {
                'This computer is ready'
            }
        }
        $summaryLabel.Text = ($lines -join "`r`n")

        Set-Layout
        $closeButton.Focus() | Out-Null
        if (-not $bad) { Start-Confetti }

        # Audible too: the machine is usually across the room by this point.
        try {
            if ($bad) {
                [System.Media.SystemSounds]::Hand.Play()
            } else {
                [System.Media.SystemSounds]::Asterisk.Play()
            }
        } catch { }
    }
})

$form.add_Shown({
    Set-Layout
    Assert-OnTop
    $timer.Start()
})

[System.Windows.Forms.Application]::Run($form)
