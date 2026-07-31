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

<#
    The Start menu, the taskbar and third-party popups all render above a plain
    TopMost form, and setting TopMost once at creation does not survive another
    process taking the foreground. Re-asserting the Z-order through
    SetWindowPos every tick does, and it does so without stealing activation
    from our own text boxes.
#>
Add-Type -Namespace ImageHub -Name Win -UsingNamespace System.Text -MemberDefinition @'
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
$background = [System.Drawing.Color]::FromArgb(18, 20, 24)
$card       = [System.Drawing.Color]::FromArgb(28, 31, 37)
$primary    = [System.Drawing.Color]::FromArgb(41, 102, 235)
$textMain   = [System.Drawing.Color]::FromArgb(240, 242, 245)
$textDim    = [System.Drawing.Color]::FromArgb(150, 156, 166)
$fieldBack  = [System.Drawing.Color]::FromArgb(44, 48, 56)
# Full-panel banner colours for the finished state - dark enough for white text,
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
# Confetti is painted straight onto the form behind the card, so the background
# needs to double-buffer or it tears.
$form.GetType().GetProperty('DoubleBuffered',
    [System.Reflection.BindingFlags]'Instance,NonPublic').SetValue($form, $true, $null)

$script:Prompting = $false

# Escape is a deliberate escape hatch for a technician who needs the desktop --
# but not while we are the only thing asking a question.
$form.add_KeyDown({
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape -and -not $script:Prompting) {
        $form.Close()
    }
})

$panel = New-Object System.Windows.Forms.Panel
$panel.BackColor = $card
$panel.Size = New-Object System.Drawing.Size(780, 560)
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
$logoBox.Location = New-Object System.Drawing.Point(300, 34)
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
$panel.Controls.Add($logoBox)

$title = New-Object System.Windows.Forms.Label
$title.AutoSize = $false
$title.Size = New-Object System.Drawing.Size(720, 34)
$title.Location = New-Object System.Drawing.Point(30, 136)
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

<#
    The finish badge: a filled disc with a hand-drawn tick or exclamation. Drawn
    rather than set from a glyph font, because the payload scripts are held to
    plain ASCII (Windows PowerShell 5.1 decodes a BOM-less file as ANSI, so a
    stray non-ASCII character has broken this script before).
#>
$script:BadgeMode = 'good'
$badge = New-Object System.Windows.Forms.Panel
$badge.Size = New-Object System.Drawing.Size(104, 104)
$badge.Location = New-Object System.Drawing.Point(338, 132)
$badge.BackColor = [System.Drawing.Color]::Transparent
$badge.Visible = $false
$badge.add_Paint({
    $g = $_.Graphics
    $g.SmoothingMode = 'AntiAlias'
    $disc = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
    $g.FillEllipse($disc, 2, 2, 100, 100)
    $disc.Dispose()

    $ink = if ($script:BadgeMode -eq 'good') { $bannerGood } else { $bannerBad }
    $pen = New-Object System.Drawing.Pen ($ink, 11)
    $pen.StartCap = 'Round'
    $pen.EndCap = 'Round'
    if ($script:BadgeMode -eq 'good') {
        $g.DrawLines($pen, [System.Drawing.Point[]]@(
            (New-Object System.Drawing.Point(28, 55)),
            (New-Object System.Drawing.Point(45, 73)),
            (New-Object System.Drawing.Point(77, 33))
        ))
    } else {
        $g.DrawLine($pen, 52, 26, 52, 62)
        $g.DrawLine($pen, 52, 78, 52, 79)
    }
    $pen.Dispose()
})
$panel.Controls.Add($badge)

# Hidden during the run; revealed at the end so "finished" is the largest thing
# on the screen rather than a reworded status line.
$headingLabel = New-Object System.Windows.Forms.Label
$headingLabel.AutoSize = $false
$headingLabel.Size = New-Object System.Drawing.Size(720, 58)
$headingLabel.Location = New-Object System.Drawing.Point(30, 248)
$headingLabel.TextAlign = 'MiddleCenter'
$headingLabel.Font = New-Object System.Drawing.Font('Segoe UI', 34, [System.Drawing.FontStyle]::Bold)
$headingLabel.Visible = $false
$panel.Controls.Add($headingLabel)

$stepLabel = New-Object System.Windows.Forms.Label
$stepLabel.AutoSize = $false
$stepLabel.Size = New-Object System.Drawing.Size(720, 28)
$stepLabel.Location = New-Object System.Drawing.Point(30, 182)
$stepLabel.TextAlign = 'MiddleCenter'
$stepLabel.ForeColor = $textMain
$stepLabel.Font = New-Object System.Drawing.Font('Segoe UI', 12)
$stepLabel.Text = 'Starting...'
$panel.Controls.Add($stepLabel)

$detailLabel = New-Object System.Windows.Forms.Label
$detailLabel.AutoSize = $false
$detailLabel.Size = New-Object System.Drawing.Size(720, 24)
$detailLabel.Location = New-Object System.Drawing.Point(30, 212)
$detailLabel.TextAlign = 'MiddleCenter'
$detailLabel.ForeColor = $textDim
$detailLabel.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$panel.Controls.Add($detailLabel)

$bar = New-Object System.Windows.Forms.ProgressBar
$bar.Size = New-Object System.Drawing.Size(660, 8)
$bar.Location = New-Object System.Drawing.Point(60, 254)
$bar.Style = 'Marquee'
$bar.MarqueeAnimationSpeed = 30
$panel.Controls.Add($bar)

# Finish-state summary: what actually happened, in plain lines, so a technician
# can hand the machine over without opening a log.
$summaryLabel = New-Object System.Windows.Forms.Label
$summaryLabel.AutoSize = $false
$summaryLabel.Size = New-Object System.Drawing.Size(660, 104)
$summaryLabel.Location = New-Object System.Drawing.Point(60, 342)
$summaryLabel.TextAlign = 'TopCenter'
$summaryLabel.Font = New-Object System.Drawing.Font('Segoe UI', 11)
$summaryLabel.Visible = $false
$panel.Controls.Add($summaryLabel)

$noteLabel = New-Object System.Windows.Forms.Label
$noteLabel.AutoSize = $false
$noteLabel.Size = New-Object System.Drawing.Size(660, 44)
$noteLabel.Location = New-Object System.Drawing.Point(60, 282)
$noteLabel.TextAlign = 'MiddleCenter'
$noteLabel.ForeColor = $textDim
$noteLabel.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$panel.Controls.Add($noteLabel)

$footer = New-Object System.Windows.Forms.Label
$footer.AutoSize = $false
$footer.Size = New-Object System.Drawing.Size(720, 22)
$footer.Location = New-Object System.Drawing.Point(30, 516)
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
$closeButton.Location = New-Object System.Drawing.Point(330, 452)
$closeButton.FlatStyle = 'Flat'
$closeButton.BackColor = $primary
$closeButton.ForeColor = [System.Drawing.Color]::White
$closeButton.Visible = $false
$closeButton.add_Click({ $form.Close() })
$panel.Controls.Add($closeButton)

# --- End-user account, asked inside this window -------------------------------
$accountPanel = New-Object System.Windows.Forms.Panel
$accountPanel.Size = New-Object System.Drawing.Size(720, 296)
$accountPanel.Location = New-Object System.Drawing.Point(30, 176)
$accountPanel.BackColor = $card
$accountPanel.Visible = $false
$panel.Controls.Add($accountPanel)

function New-FieldLabel {
    param([string]$Text, [int]$X, [int]$Y)
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.AutoSize = $false
    $label.Size = New-Object System.Drawing.Size(340, 20)
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.ForeColor = $textDim
    $label.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $accountPanel.Controls.Add($label)
}

function New-FieldBox {
    param([int]$X, [int]$Y, [switch]$Secret)
    $box = New-Object System.Windows.Forms.TextBox
    $box.Size = New-Object System.Drawing.Size(340, 26)
    $box.Location = New-Object System.Drawing.Point($X, $Y)
    $box.BackColor = $fieldBack
    $box.ForeColor = $textMain
    $box.BorderStyle = 'FixedSingle'
    $box.Font = New-Object System.Drawing.Font('Segoe UI', 11)
    if ($Secret) { $box.UseSystemPasswordChar = $true }
    $accountPanel.Controls.Add($box)
    return $box
}

$accountHeading = New-Object System.Windows.Forms.Label
$accountHeading.Text = 'Set up the account for whoever receives this machine'
$accountHeading.AutoSize = $false
$accountHeading.Size = New-Object System.Drawing.Size(720, 26)
$accountHeading.Location = New-Object System.Drawing.Point(0, 0)
$accountHeading.TextAlign = 'MiddleCenter'
$accountHeading.ForeColor = $textMain
$accountHeading.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 13)
$accountPanel.Controls.Add($accountHeading)

New-FieldLabel 'Username' 10 40
$userBox = New-FieldBox 10 62
New-FieldLabel 'Full name (optional)' 370 40
$nameBox = New-FieldBox 370 62
New-FieldLabel 'Password' 10 100
$passBox = New-FieldBox 10 122 -Secret
New-FieldLabel 'Confirm password' 370 100
$confirmBox = New-FieldBox 370 122 -Secret

$adminBox = New-Object System.Windows.Forms.CheckBox
$adminBox.Text = 'Make this account an administrator'
$adminBox.Location = New-Object System.Drawing.Point(10, 162)
$adminBox.Size = New-Object System.Drawing.Size(340, 24)
$adminBox.ForeColor = $textMain
$adminBox.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$accountPanel.Controls.Add($adminBox)

$changeBox = New-Object System.Windows.Forms.CheckBox
$changeBox.Text = 'Must change password at first sign-in'
$changeBox.Location = New-Object System.Drawing.Point(370, 162)
$changeBox.Size = New-Object System.Drawing.Size(340, 24)
$changeBox.ForeColor = $textMain
$changeBox.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$changeBox.Checked = $true
$accountPanel.Controls.Add($changeBox)

$accountError = New-Object System.Windows.Forms.Label
$accountError.AutoSize = $false
$accountError.Size = New-Object System.Drawing.Size(720, 22)
$accountError.Location = New-Object System.Drawing.Point(10, 196)
$accountError.ForeColor = [System.Drawing.Color]::FromArgb(255, 140, 140)
$accountError.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$accountPanel.Controls.Add($accountError)

$accountCountdown = New-Object System.Windows.Forms.Label
$accountCountdown.AutoSize = $false
$accountCountdown.Size = New-Object System.Drawing.Size(420, 40)
$accountCountdown.Location = New-Object System.Drawing.Point(10, 232)
$accountCountdown.TextAlign = 'MiddleLeft'
$accountCountdown.ForeColor = $textDim
$accountCountdown.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$accountPanel.Controls.Add($accountCountdown)

$createButton = New-Object System.Windows.Forms.Button
$createButton.Text = 'Create account'
$createButton.Size = New-Object System.Drawing.Size(210, 40)
$createButton.Location = New-Object System.Drawing.Point(500, 232)
$createButton.FlatStyle = 'Flat'
$createButton.BackColor = $primary
$createButton.ForeColor = [System.Drawing.Color]::White
$createButton.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
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
        $accountPanel.Visible = $false
        $script:Prompting = $false
        $stepLabel.Visible = $true
        $detailLabel.Visible = $true
        $bar.Visible = $true
        $stepLabel.Text = 'Creating the account...'
        # Nothing should linger in the boxes once it is on its way.
        $passBox.Clear()
        $confirmBox.Clear()
    } catch {
        $accountError.Text = "Couldn't hand those details to provisioning: $($_.Exception.Message)"
    }
})

# --- Confetti ----------------------------------------------------------------
# Painted on the form, behind the card, so it falls across the whole screen.
$script:Particles = New-Object System.Collections.ArrayList
$script:ConfettiFrames = 0

function Start-Confetti {
    $width = [Math]::Max(800, $form.ClientSize.Width)
    for ($i = 0; $i -lt 160; $i++) {
        [void]$script:Particles.Add([pscustomobject]@{
            X      = [double](Get-Random -Minimum 0 -Maximum $width)
            Y      = [double](Get-Random -Minimum -700 -Maximum 0)
            VX     = [double]((Get-Random -Minimum -18 -Maximum 18) / 10.0)
            VY     = [double]((Get-Random -Minimum 18 -Maximum 70) / 10.0)
            Angle  = [double](Get-Random -Minimum 0 -Maximum 360)
            Spin   = [double]((Get-Random -Minimum -80 -Maximum 80) / 10.0)
            W      = [int](Get-Random -Minimum 7 -Maximum 15)
            H      = [int](Get-Random -Minimum 12 -Maximum 24)
            Colour = $confettiColours[(Get-Random -Minimum 0 -Maximum $confettiColours.Count)]
        })
    }
    $confettiTimer.Start()
}

$confettiTimer = New-Object System.Windows.Forms.Timer
$confettiTimer.Interval = 33
$confettiTimer.add_Tick({
    $script:ConfettiFrames++
    $floor = $form.ClientSize.Height + 60
    foreach ($p in $script:Particles) {
        $p.X += $p.VX
        $p.Y += $p.VY
        $p.VY += 0.22
        $p.Angle += $p.Spin
    }
    $form.Invalidate()
    # About seven seconds, or as soon as the last piece is off the bottom.
    $airborne = @($script:Particles | Where-Object { $_.Y -lt $floor }).Count
    if ($script:ConfettiFrames -gt 210 -or $airborne -eq 0) {
        $confettiTimer.Stop()
        $script:Particles.Clear()
        $form.Invalidate()
    }
})

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
        # The Start menu and taskbar flyouts outrank every TopMost window, so
        # being in front is not enough - they have to be closed.
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

    # Asking for the account happens in this window now, so there is no longer a
    # dialog of our own to stand aside for. The screen stays in front the whole
    # way through.
    $wantsPrompt = [bool](Get-Field $current 'prompting' $false) -and -not $script:AnswerSent
    if ($wantsPrompt -ne $script:Prompting) {
        $script:Prompting = $wantsPrompt
        $accountPanel.Visible = $wantsPrompt
        $stepLabel.Visible = -not $wantsPrompt
        $detailLabel.Visible = -not $wantsPrompt
        $bar.Visible = -not $wantsPrompt
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
    }

    if (-not $script:Prompting) {
        $stepLabel.Text = Get-Field $current 'step' 'Working...'
        $detailLabel.Text = Get-Field $current 'detail' ''
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

    if ($state -eq 'done' -or $state -eq 'failed') {
        $timer.Stop()

        $failures = @(Get-Field $current 'failures' @())
        $warnings = @(Get-Field $current 'warnings' @())
        $bad = ($state -eq 'failed' -or $failures.Count -gt 0)

        # Deliberately loud. A technician walked away from a finished machine and
        # closed this by hand because a changed line of small text did not read as
        # "done" - the whole screen now changes colour, grows a badge, and throws
        # confetti.
        $accountPanel.Visible = $false
        $bar.Visible = $false
        $noteLabel.Visible = $false
        $title.Visible = $false
        $stepLabel.Visible = $true
        $detailLabel.Visible = $false

        $script:BadgeMode = if ($bad) { 'bad' } else { 'good' }
        $badge.Visible = $true
        $headingLabel.Visible = $true
        $summaryLabel.Visible = $true

        $panel.BackColor = if ($bad) { $bannerBad } else { $bannerGood }
        $headingLabel.ForeColor = [System.Drawing.Color]::White
        $stepLabel.ForeColor = [System.Drawing.Color]::White
        $summaryLabel.ForeColor = [System.Drawing.Color]::FromArgb(232, 244, 236)

        $stepLabel.Location = New-Object System.Drawing.Point(30, 306)
        $stepLabel.Font = New-Object System.Drawing.Font('Segoe UI', 13)

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
            Start-Confetti
        }
        $summaryLabel.Text = ($lines -join "`r`n")

        # The close button is the one thing to act on now, so make it read that way
        # against the banner rather than staying the same small accent button.
        $closeButton.Text = 'Close this screen'
        $closeButton.Size = New-Object System.Drawing.Size(240, 44)
        $closeButton.Location = New-Object System.Drawing.Point(270, 452)
        $closeButton.BackColor = [System.Drawing.Color]::White
        $closeButton.ForeColor = [System.Drawing.Color]::Black
        $closeButton.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
        $closeButton.Visible = $true
        $closeButton.Focus() | Out-Null

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
    Set-PanelCentre
    Assert-OnTop
    $timer.Start()
})

[System.Windows.Forms.Application]::Run($form)
