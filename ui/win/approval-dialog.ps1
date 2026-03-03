# Claude Code Tool Approval Dialog (IPC V2)
# Windows Forms popup for approving/denying tool execution
# Supports risk tiers, 4-level approval scope, burst mode, diff coloring
param(
    [string]$ToolName = "Unknown Tool",
    [string]$Detail = "",
    [string]$DetailBase64 = "",
    [int]$RiskTier = 1,
    [string]$ContextBase64 = "",
    [string]$ProjectName = "",
    [string]$IntentBase64 = ""
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Win32 SetForegroundWindow (MemberDefinition syntax — most reliable)
try {
    Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);' -Name FgWin -Namespace User32 -ErrorAction SilentlyContinue
} catch {}

# Decode base64 detail if provided (avoids shell escaping issues)
if ($DetailBase64 -ne "") {
    try {
        $Detail = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($DetailBase64))
    } catch {
        $Detail = "(Failed to decode detail)"
    }
}

# Decode context if provided
$contextText = ""
if ($ContextBase64 -ne "") {
    try {
        $contextText = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ContextBase64))
    } catch {
        $contextText = ""
    }
}

# Decode intent (Claude's reasoning) if provided
$intentText = ""
if ($IntentBase64 -ne "") {
    try {
        $intentText = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($IntentBase64))
    } catch {
        $intentText = ""
    }
}

# Named Mutex for serialization (multiple agents may trigger simultaneously)
$mutexName = "Global\ClaudeCodeApprovalDialog"
$mutex = $null
try {
    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    $mutex.WaitOne(30000) | Out-Null
} catch {}

try {
    [System.Media.SystemSounds]::Exclamation.Play()

    $state = @{
        Result = "DENY"
        Scope  = "User denied"
        Burst  = $false
    }

    # --- Risk tier config ---
    switch ($RiskTier) {
        1 {
            $headerBg    = [System.Drawing.Color]::FromArgb(232, 245, 233)
            $headerFg    = [System.Drawing.Color]::FromArgb(27, 94, 32)
            $headerText  = [char]0x2713 + " 안전"
            $focusAllow  = $true
        }
        2 {
            $headerBg    = [System.Drawing.Color]::FromArgb(255, 243, 224)
            $headerFg    = [System.Drawing.Color]::FromArgb(230, 81, 0)
            $headerText  = [char]0x26A0 + " 주의"
            $focusAllow  = $true
        }
        3 {
            $headerBg    = [System.Drawing.Color]::FromArgb(255, 235, 238)
            $headerFg    = [System.Drawing.Color]::FromArgb(183, 28, 28)
            $headerText  = [char]0x2715 + " 위험"
            $focusAllow  = $false
        }
        default {
            $headerBg    = [System.Drawing.Color]::FromArgb(232, 245, 233)
            $headerFg    = [System.Drawing.Color]::FromArgb(27, 94, 32)
            $headerText  = [char]0x2713 + " 안전"
            $focusAllow  = $true
        }
    }

    # --- Enable visual styles BEFORE creating controls ---
    [System.Windows.Forms.Application]::EnableVisualStyles()

    # --- Form ---
    $form = New-Object System.Windows.Forms.Form
    $projDisplay = if ($ProjectName -ne "") { " [$ProjectName]" } else { "" }
    $form.Text = "Claude Code - Tool Approval$projDisplay"
    $form.Size = New-Object System.Drawing.Size(520, 464)  # base size, adjusted below for dynamic panels
    $form.StartPosition = "CenterScreen"
    $form.TopMost = $true
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ShowInTaskbar = $true
    $form.Icon = [System.Drawing.SystemIcons]::Shield
    $form.KeyPreview = $true

    # --- 1. Risk header panel ---
    $headerPanel = New-Object System.Windows.Forms.Panel
    $headerPanel.Location = New-Object System.Drawing.Point(0, 0)
    $headerPanel.Size = New-Object System.Drawing.Size(512, 36)
    $headerPanel.BackColor = $headerBg

    $tierLabel = New-Object System.Windows.Forms.Label
    $tierLabel.Text = $headerText
    $tierLabel.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $tierLabel.ForeColor = $headerFg
    $tierLabel.Location = New-Object System.Drawing.Point(12, 6)
    $tierLabel.Size = New-Object System.Drawing.Size(120, 24)
    $tierLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $headerPanel.Controls.Add($tierLabel)

    # Project name badge + tool label (conditional layout)
    $toolLabel = New-Object System.Windows.Forms.Label
    $toolLabel.Text = $ToolName
    $toolLabel.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $toolLabel.ForeColor = $headerFg
    $toolLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight

    if ($ProjectName -ne "") {
        $projBadge = New-Object System.Windows.Forms.Label
        $projBadge.Text = $ProjectName
        $projBadge.Font = New-Object System.Drawing.Font("Segoe UI", 9)
        $projBadge.ForeColor = [System.Drawing.Color]::FromArgb(117, 117, 117)
        $projBadge.BackColor = [System.Drawing.Color]::FromArgb(238, 238, 238)
        $projBadge.Location = New-Object System.Drawing.Point(140, 8)
        $projBadge.Size = New-Object System.Drawing.Size(200, 20)
        $projBadge.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
        $headerPanel.Controls.Add($projBadge)

        $toolLabel.Location = New-Object System.Drawing.Point(340, 6)
        $toolLabel.Size = New-Object System.Drawing.Size(160, 24)
    } else {
        $toolLabel.Location = New-Object System.Drawing.Point(140, 6)
        $toolLabel.Size = New-Object System.Drawing.Size(360, 24)
    }
    $headerPanel.Controls.Add($toolLabel)

    $form.Controls.Add($headerPanel)

    # --- Context panel (shows current user request) ---
    $contextPanelHeight = 0
    if ($contextText -ne "") {
        $contextPanel = New-Object System.Windows.Forms.Panel
        $contextPanel.Location = New-Object System.Drawing.Point(0, 36)
        $contextPanel.Size = New-Object System.Drawing.Size(512, 28)
        $contextPanel.BackColor = [System.Drawing.Color]::FromArgb(245, 245, 245)

        $contextIcon = New-Object System.Windows.Forms.Label
        $contextIcon.Text = [char]0x25B8
        $contextIcon.Font = New-Object System.Drawing.Font("Segoe UI", 9)
        $contextIcon.Location = New-Object System.Drawing.Point(12, 4)
        $contextIcon.Size = New-Object System.Drawing.Size(20, 20)
        $contextPanel.Controls.Add($contextIcon)

        $contextLabel = New-Object System.Windows.Forms.Label
        $contextLabel.Text = $contextText
        $contextLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
        $contextLabel.ForeColor = [System.Drawing.Color]::FromArgb(97, 97, 97)
        $contextLabel.Location = New-Object System.Drawing.Point(32, 5)
        $contextLabel.Size = New-Object System.Drawing.Size(475, 18)
        $contextLabel.AutoEllipsis = $true
        $contextPanel.Controls.Add($contextLabel)

        $form.Controls.Add($contextPanel)
        $contextPanelHeight = 28
    }

    # --- Intent panel (Claude's reasoning — why this tool is being called) ---
    $intentPanelHeight = 0
    if ($intentText -ne "") {
        $intentPanel = New-Object System.Windows.Forms.Panel
        $intentPanel.Location = New-Object System.Drawing.Point(0, (36 + $contextPanelHeight))
        $intentPanel.Size = New-Object System.Drawing.Size(512, 30)
        $intentPanel.BackColor = [System.Drawing.Color]::FromArgb(232, 240, 254)

        $intentIcon = New-Object System.Windows.Forms.Label
        $intentIcon.Text = [char]0x2192  # →
        $intentIcon.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
        $intentIcon.ForeColor = [System.Drawing.Color]::FromArgb(21, 101, 192)
        $intentIcon.Location = New-Object System.Drawing.Point(10, 4)
        $intentIcon.Size = New-Object System.Drawing.Size(20, 22)
        $intentPanel.Controls.Add($intentIcon)

        $intentLabel = New-Object System.Windows.Forms.Label
        $intentLabel.Text = $intentText
        $intentLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10)
        $intentLabel.ForeColor = [System.Drawing.Color]::FromArgb(21, 101, 192)
        $intentLabel.Location = New-Object System.Drawing.Point(30, 5)
        $intentLabel.Size = New-Object System.Drawing.Size(478, 20)
        $intentLabel.AutoEllipsis = $true
        $intentPanel.Controls.Add($intentLabel)

        $form.Controls.Add($intentPanel)
        $intentPanelHeight = 30
    }

    # --- 2. RichTextBox with diff coloring ---
    $totalTopOffset = $contextPanelHeight + $intentPanelHeight
    $richBox = New-Object System.Windows.Forms.RichTextBox
    $richBox.Location = New-Object System.Drawing.Point(15, (44 + $totalTopOffset))
    $richBox.Size = New-Object System.Drawing.Size(475, 155)
    $richBox.ReadOnly = $true
    $richBox.Font = New-Object System.Drawing.Font("Consolas", 10)
    $richBox.BackColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
    $richBox.WordWrap = $false
    $richBox.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Both
    $richBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

    # Colorize line by line
    $lines = $Detail -split "`n"
    $richBox.Text = ""
    $defaultColor = [System.Drawing.Color]::Black
    $redColor = [System.Drawing.Color]::FromArgb(211, 47, 47)
    $greenColor = [System.Drawing.Color]::FromArgb(56, 142, 60)
    $blueColor = [System.Drawing.Color]::FromArgb(21, 101, 192)
    $defaultFont = New-Object System.Drawing.Font("Consolas", 10)
    $boldFont = New-Object System.Drawing.Font("Consolas", 10, [System.Drawing.FontStyle]::Bold)

    foreach ($line in $lines) {
        $startPos = $richBox.TextLength
        $richBox.AppendText("$line`n")
        $richBox.Select($startPos, $line.Length)
        if ($line -match '^File:') {
            $richBox.SelectionColor = $blueColor
            $richBox.SelectionFont = $boldFont
        } elseif ($line -match '^\-\-\- old' -or ($line -match '^\-' -and $line -notmatch '^\-\-\-')) {
            $richBox.SelectionColor = $redColor
        } elseif ($line -match '^\+\+\+ new' -or ($line -match '^\+' -and $line -notmatch '^\+\+\+')) {
            $richBox.SelectionColor = $greenColor
        } else {
            $richBox.SelectionColor = $defaultColor
        }
    }
    $richBox.Select(0, 0)
    $form.Controls.Add($richBox)

    # --- 3. Radio button group (4-level approval scope) ---
    $groupBox = New-Object System.Windows.Forms.GroupBox
    $groupBox.Text = "승인 범위"
    $groupBox.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $groupBox.Location = New-Object System.Drawing.Point(15, (205 + $totalTopOffset))
    $groupBox.Size = New-Object System.Drawing.Size(475, 105)

    $radioFont = New-Object System.Drawing.Font("Segoe UI", 9)

    $radio1 = New-Object System.Windows.Forms.RadioButton
    $radio1.Text = "이번만 허용 [1]"
    $radio1.Font = $radioFont
    $radio1.Location = New-Object System.Drawing.Point(12, 20)
    $radio1.Size = New-Object System.Drawing.Size(210, 20)
    $radio1.Checked = $true
    $groupBox.Controls.Add($radio1)

    $radio2 = New-Object System.Windows.Forms.RadioButton
    $radio2.Text = "이 세션 동안 허용 [2]"
    $radio2.Font = $radioFont
    $radio2.Location = New-Object System.Drawing.Point(240, 20)
    $radio2.Size = New-Object System.Drawing.Size(220, 20)
    $groupBox.Controls.Add($radio2)

    $radio3 = New-Object System.Windows.Forms.RadioButton
    $radio3.Text = "항상 허용 (이 패턴) [3]"
    $radio3.Font = $radioFont
    $radio3.Location = New-Object System.Drawing.Point(12, 50)
    $radio3.Size = New-Object System.Drawing.Size(210, 20)
    $groupBox.Controls.Add($radio3)

    $radio4 = New-Object System.Windows.Forms.RadioButton
    $radio4.Text = "이 도구 전체 항상 허용 [4]"
    $radio4.Font = $radioFont
    $radio4.Location = New-Object System.Drawing.Point(240, 50)
    $radio4.Size = New-Object System.Drawing.Size(220, 20)
    $groupBox.Controls.Add($radio4)

    # Disable radios 3 and 4 for TIER 3 (dangerous)
    if ($RiskTier -eq 3) {
        $radio3.Enabled = $false
        $radio4.Enabled = $false
    }

    $form.Controls.Add($groupBox)

    # --- 4. Burst checkbox ---
    $burstCheck = New-Object System.Windows.Forms.CheckBox
    $burstCheck.Text = "대기 중인 동일 도구도 허용 (5초)"
    $burstCheck.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $burstCheck.Location = New-Object System.Drawing.Point(15, (316 + $totalTopOffset))
    $burstCheck.Size = New-Object System.Drawing.Size(300, 24)
    $form.Controls.Add($burstCheck)

    # --- 5. Status label ---
    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Text = "응답 대기 중... [1]이번만 [2]세션 [3]항상 [4]도구전체 [Esc]거부"
    $statusLabel.Location = New-Object System.Drawing.Point(15, (346 + $totalTopOffset))
    $statusLabel.Size = New-Object System.Drawing.Size(475, 20)
    $statusLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $statusLabel.ForeColor = [System.Drawing.Color]::Gray
    $form.Controls.Add($statusLabel)

    # --- 6. Allow button ---
    $allowBtn = New-Object System.Windows.Forms.Button
    $allowBtn.Text = "허용 (Allow)"
    $allowBtn.Location = New-Object System.Drawing.Point(265, (372 + $totalTopOffset))
    $allowBtn.Size = New-Object System.Drawing.Size(115, 38)
    $allowBtn.BackColor = [System.Drawing.Color]::FromArgb(76, 175, 80)
    $allowBtn.ForeColor = [System.Drawing.Color]::White
    $allowBtn.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $allowBtn.FlatStyle = "Flat"
    $allowBtn.FlatAppearance.BorderSize = 0
    $allowBtn.Cursor = [System.Windows.Forms.Cursors]::Hand
    $form.Controls.Add($allowBtn)

    # --- 7. Deny button ---
    $denyBtn = New-Object System.Windows.Forms.Button
    $denyBtn.Text = "거부 (Deny)"
    $denyBtn.Location = New-Object System.Drawing.Point(390, (372 + $totalTopOffset))
    $denyBtn.Size = New-Object System.Drawing.Size(105, 38)
    $denyBtn.BackColor = [System.Drawing.Color]::FromArgb(224, 224, 224)
    $denyBtn.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $denyBtn.FlatStyle = "Flat"
    $denyBtn.FlatAppearance.BorderSize = 0
    $denyBtn.Cursor = [System.Windows.Forms.Cursors]::Hand
    $form.Controls.Add($denyBtn)

    # --- Button click handlers ---
    $allowBtn.Add_Click({
        $state.Result = "ALLOW"
        if ($radio1.Checked) { $state.Scope = "ONCE" }
        elseif ($radio2.Checked) { $state.Scope = "SESSION" }
        elseif ($radio3.Checked) { $state.Scope = "ALWAYS" }
        elseif ($radio4.Checked) { $state.Scope = "TOOL_WILDCARD" }
        $state.Burst = $burstCheck.Checked
        $form.Close()
    })
    $denyBtn.Add_Click({
        $state.Result = "DENY"
        $state.Scope = "User denied"
        $state.Burst = $false
        $form.Close()
    })

    # --- Keyboard shortcuts ---
    $form.Add_KeyDown({
        param($sender, $e)
        switch ($e.KeyCode) {
            ([System.Windows.Forms.Keys]::D1) {
                $radio1.Checked = $true
                $allowBtn.PerformClick()
            }
            ([System.Windows.Forms.Keys]::D2) {
                $radio2.Checked = $true
                $allowBtn.PerformClick()
            }
            ([System.Windows.Forms.Keys]::D3) {
                if ($radio3.Enabled) {
                    $radio3.Checked = $true
                    $allowBtn.PerformClick()
                }
            }
            ([System.Windows.Forms.Keys]::D4) {
                if ($radio4.Enabled) {
                    $radio4.Checked = $true
                    $allowBtn.PerformClick()
                }
            }
            ([System.Windows.Forms.Keys]::Enter) {
                $allowBtn.PerformClick()
            }
            ([System.Windows.Forms.Keys]::Escape) {
                $denyBtn.PerformClick()
            }
        }
    })

    # --- Force foreground on shown + set default focus ---
    $form.Add_Shown({
        $form.Activate()
        $form.BringToFront()
        $form.Focus()
        try { [User32.FgWin]::SetForegroundWindow($form.Handle) } catch {}
        if ($focusAllow) {
            $allowBtn.Focus()
        } else {
            $denyBtn.Focus()
        }
    })

    # --- Adjust form height for dynamic panels ---
    if ($totalTopOffset -gt 0) {
        $form.Size = New-Object System.Drawing.Size(520, (464 + $totalTopOffset))
    }

    # --- Show dialog ---
    $form.ShowDialog() | Out-Null

    # --- Output (IPC V2) ---
    $output = "$($state.Result)|$($state.Scope)"
    if ($state.Burst) { $output += "|BURST" }
    Write-Output $output

} finally {
    try { if ($mutex) { $mutex.ReleaseMutex() } } catch {}
    try { if ($mutex) { $mutex.Dispose() } } catch {}
}
