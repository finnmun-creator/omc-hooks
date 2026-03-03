# Claude Code Question Dialog
# Two modes:
#   popup   — Windows Forms dialog with option buttons (for simple questions)
#   complex — Windows Forms dialog with "VS Code로 이동" button (for complex questions)
# No mutex — can coexist with approval-dialog.ps1
param(
    [string]$Mode = "popup",
    [string]$QuestionBase64 = "",
    [string]$OptionsBase64 = "",
    [string]$ReasonText = ""
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Win32 SetForegroundWindow
try {
    Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);' -Name FgWin -Namespace User32 -ErrorAction SilentlyContinue
} catch {}

# --- Base64 decoding ---
$questionText = ""
if ($QuestionBase64 -ne "") {
    try {
        $questionText = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($QuestionBase64))
    } catch {
        $questionText = "(Failed to decode question)"
    }
}
if ($questionText -eq "") { $questionText = "입력이 필요합니다" }

$optionLabels = @()
if ($OptionsBase64 -ne "") {
    try {
        $optionsJson = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($OptionsBase64))
        # Parse JSON array manually (avoid dependency on external modules)
        Add-Type -AssemblyName System.Web.Extensions -ErrorAction SilentlyContinue
        try {
            $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
            $optionLabels = $serializer.DeserializeObject($optionsJson)
        } catch {
            # Fallback: simple regex parse for JSON string array
            $optionLabels = @()
            $matches_ = [regex]::Matches($optionsJson, '"([^"]*)"')
            foreach ($m in $matches_) {
                $optionLabels += $m.Groups[1].Value
            }
        }
    } catch {
        $optionLabels = @()
    }
}

# --- Log file path ---
$logFile = Join-Path $env:TEMP "claude-question-log.jsonl"

function Write-QuestionLog($entry) {
    try {
        $json = ConvertTo-Json $entry -Compress -Depth 3
        Add-Content -Path $logFile -Value $json -Encoding UTF8
    } catch {}
}

function Activate-VSCode {
    try {
        $vscodeProcs = Get-Process -Name "Code" -ErrorAction SilentlyContinue
        foreach ($p in $vscodeProcs) {
            if ($p.MainWindowHandle -ne [IntPtr]::Zero) {
                [User32.FgWin]::SetForegroundWindow($p.MainWindowHandle)
                break
            }
        }
    } catch {}
}

# ============================================================
# POPUP MODE
# ============================================================
if ($Mode -eq "popup") {

    [System.Media.SystemSounds]::Asterisk.Play()

    $numOptions = $optionLabels.Count
    if ($numOptions -lt 1) { $numOptions = 1 }
    $formHeight = 200 + 42 * $numOptions

    # --- Form ---
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Claude Code - Question"
    $form.Size = New-Object System.Drawing.Size(520, $formHeight)
    $form.StartPosition = "CenterScreen"
    $form.TopMost = $true
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ShowInTaskbar = $true
    $form.Icon = [System.Drawing.SystemIcons]::Question
    $form.KeyPreview = $true

    # --- 1. Header panel ---
    $headerPanel = New-Object System.Windows.Forms.Panel
    $headerPanel.Location = New-Object System.Drawing.Point(0, 0)
    $headerPanel.Size = New-Object System.Drawing.Size(520, 36)
    $headerPanel.BackColor = [System.Drawing.Color]::FromArgb(227, 242, 253)

    $headerLabel = New-Object System.Windows.Forms.Label
    $headerLabel.Text = [char]0x25B6 + " Claude Code 질문"
    $headerLabel.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $headerLabel.ForeColor = [System.Drawing.Color]::FromArgb(13, 71, 161)
    $headerLabel.Location = New-Object System.Drawing.Point(12, 6)
    $headerLabel.Size = New-Object System.Drawing.Size(490, 24)
    $headerLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $headerPanel.Controls.Add($headerLabel)
    $form.Controls.Add($headerPanel)

    # --- 2. Question label ---
    $questionLabel = New-Object System.Windows.Forms.Label
    $questionLabel.Text = $questionText
    $questionLabel.Font = New-Object System.Drawing.Font("Segoe UI", 11)
    $questionLabel.ForeColor = [System.Drawing.Color]::FromArgb(33, 33, 33)
    $questionLabel.Location = New-Object System.Drawing.Point(20, 46)
    $questionLabel.Size = New-Object System.Drawing.Size(460, 60)
    $questionLabel.AutoSize = $false
    $questionLabel.MaximumSize = New-Object System.Drawing.Size(460, 0)
    $questionLabel.AutoSize = $true
    $form.Controls.Add($questionLabel)

    # --- 3. Option buttons ---
    $buttonTop = 46 + $questionLabel.PreferredHeight + 10
    $buttons = @()

    for ($i = 0; $i -lt $optionLabels.Count; $i++) {
        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = "[$($i + 1)] $($optionLabels[$i])"
        $btn.Font = New-Object System.Drawing.Font("Segoe UI", 10)
        $btn.Location = New-Object System.Drawing.Point(20, $buttonTop)
        $btn.Size = New-Object System.Drawing.Size(460, 36)
        $btn.FlatStyle = "Flat"
        $btn.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(187, 222, 251)
        $btn.FlatAppearance.BorderSize = 1
        $btn.BackColor = [System.Drawing.Color]::FromArgb(227, 242, 253)
        $btn.ForeColor = [System.Drawing.Color]::FromArgb(33, 33, 33)
        $btn.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        $btn.Padding = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
        $btn.Cursor = [System.Windows.Forms.Cursors]::Hand

        # Capture index for closure
        $idx = $i
        $label = $optionLabels[$i]
        $btn.Tag = @{ Index = $idx; Label = $label }

        $btn.Add_Click({
            param($sender, $e)
            $tag = $sender.Tag
            Write-QuestionLog @{
                timestamp      = (Get-Date).ToString("o")
                question       = $questionText
                selectedOption = $tag.Index + 1
                selectedLabel  = $tag.Label
                method         = "popup"
            }
            Activate-VSCode
            $form.Close()
        }.GetNewClosure())

        $form.Controls.Add($btn)
        $buttons += $btn
        $buttonTop += 42
    }

    # --- 4. Footer link label ---
    $footerLabel = New-Object System.Windows.Forms.Label
    $footerLabel.Text = "터미널에서 직접 응답하려면 이 창을 닫으세요"
    $footerLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
    $footerLabel.ForeColor = [System.Drawing.Color]::Gray
    $footerLabel.Location = New-Object System.Drawing.Point(20, $buttonTop + 6)
    $footerLabel.Size = New-Object System.Drawing.Size(460, 20)
    $footerLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $form.Controls.Add($footerLabel)

    # Recalculate form height based on actual content
    $actualHeight = $buttonTop + 6 + 20 + 50
    $form.ClientSize = New-Object System.Drawing.Size(500, $actualHeight)

    # --- Keyboard shortcuts ---
    $form.Add_KeyDown({
        param($sender, $e)
        $keyIndex = -1
        switch ($e.KeyCode) {
            ([System.Windows.Forms.Keys]::D1) { $keyIndex = 0 }
            ([System.Windows.Forms.Keys]::D2) { $keyIndex = 1 }
            ([System.Windows.Forms.Keys]::D3) { $keyIndex = 2 }
            ([System.Windows.Forms.Keys]::D4) { $keyIndex = 3 }
            ([System.Windows.Forms.Keys]::NumPad1) { $keyIndex = 0 }
            ([System.Windows.Forms.Keys]::NumPad2) { $keyIndex = 1 }
            ([System.Windows.Forms.Keys]::NumPad3) { $keyIndex = 2 }
            ([System.Windows.Forms.Keys]::NumPad4) { $keyIndex = 3 }
            ([System.Windows.Forms.Keys]::Escape) {
                $form.Close()
                return
            }
        }
        if ($keyIndex -ge 0 -and $keyIndex -lt $buttons.Count) {
            $buttons[$keyIndex].PerformClick()
        }
    })

    # --- Auto-close timer (60 seconds) ---
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 60000
    $timer.Add_Tick({
        $timer.Stop()
        $form.Close()
    })
    $timer.Start()

    # --- Force foreground on shown ---
    $form.Add_Shown({
        $form.Activate()
        $form.BringToFront()
        $form.Focus()
        try { [User32.FgWin]::SetForegroundWindow($form.Handle) } catch {}
        if ($buttons.Count -gt 0) { $buttons[0].Focus() }
    })

    # --- Show dialog ---
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $form.ShowDialog() | Out-Null

    # Cleanup
    $timer.Stop()
    $timer.Dispose()
    $form.Dispose()
}

# ============================================================
# COMPLEX MODE — center-screen popup with "VS Code로 이동" button
# ============================================================
elseif ($Mode -eq "complex") {

    [System.Media.SystemSounds]::Asterisk.Play()

    if ($ReasonText -eq "") { $ReasonText = "터미널에서 직접 확인하세요" }

    # --- Form ---
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Claude Code - Question"
    $form.Size = New-Object System.Drawing.Size(520, 280)
    $form.StartPosition = "CenterScreen"
    $form.TopMost = $true
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ShowInTaskbar = $true
    $form.Icon = [System.Drawing.SystemIcons]::Question
    $form.KeyPreview = $true

    # --- 1. Header panel (same as simple) ---
    $headerPanel = New-Object System.Windows.Forms.Panel
    $headerPanel.Location = New-Object System.Drawing.Point(0, 0)
    $headerPanel.Size = New-Object System.Drawing.Size(520, 36)
    $headerPanel.BackColor = [System.Drawing.Color]::FromArgb(227, 242, 253)

    $headerLabel = New-Object System.Windows.Forms.Label
    $headerLabel.Text = [char]0x25B6 + " Claude Code 질문"
    $headerLabel.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $headerLabel.ForeColor = [System.Drawing.Color]::FromArgb(13, 71, 161)
    $headerLabel.Location = New-Object System.Drawing.Point(12, 6)
    $headerLabel.Size = New-Object System.Drawing.Size(490, 24)
    $headerLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $headerPanel.Controls.Add($headerLabel)
    $form.Controls.Add($headerPanel)

    # --- 2. Question label ---
    $questionLabel = New-Object System.Windows.Forms.Label
    $questionLabel.Text = $questionText
    $questionLabel.Font = New-Object System.Drawing.Font("Segoe UI", 11)
    $questionLabel.ForeColor = [System.Drawing.Color]::FromArgb(33, 33, 33)
    $questionLabel.Location = New-Object System.Drawing.Point(20, 46)
    $questionLabel.Size = New-Object System.Drawing.Size(460, 60)
    $questionLabel.AutoSize = $false
    $questionLabel.MaximumSize = New-Object System.Drawing.Size(460, 0)
    $questionLabel.AutoSize = $true
    $form.Controls.Add($questionLabel)

    # --- 3. Reason label (gray italic) ---
    $reasonTop = 46 + $questionLabel.PreferredHeight + 8
    $reasonLabel = New-Object System.Windows.Forms.Label
    $reasonLabel.Text = [char]0x2139 + " " + $ReasonText
    $reasonLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Italic)
    $reasonLabel.ForeColor = [System.Drawing.Color]::Gray
    $reasonLabel.Location = New-Object System.Drawing.Point(20, $reasonTop)
    $reasonLabel.Size = New-Object System.Drawing.Size(460, 20)
    $form.Controls.Add($reasonLabel)

    # --- 4. Info label ---
    $infoTop = $reasonTop + 22
    $infoLabel = New-Object System.Windows.Forms.Label
    $infoLabel.Text = "터미널에서 응답이 필요합니다"
    $infoLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $infoLabel.ForeColor = [System.Drawing.Color]::Gray
    $infoLabel.Location = New-Object System.Drawing.Point(20, $infoTop)
    $infoLabel.Size = New-Object System.Drawing.Size(460, 20)
    $form.Controls.Add($infoLabel)

    # --- 5. "VS Code로 이동" button (blue, centered) ---
    $btnTop = $infoTop + 30
    $vscodeBtn = New-Object System.Windows.Forms.Button
    $vscodeBtn.Text = "VS Code로 이동"
    $vscodeBtn.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $vscodeBtn.Size = New-Object System.Drawing.Size(200, 40)
    $vscodeBtn.Location = New-Object System.Drawing.Point(150, $btnTop)
    $vscodeBtn.FlatStyle = "Flat"
    $vscodeBtn.FlatAppearance.BorderSize = 0
    $vscodeBtn.BackColor = [System.Drawing.Color]::FromArgb(33, 150, 243)
    $vscodeBtn.ForeColor = [System.Drawing.Color]::White
    $vscodeBtn.Cursor = [System.Windows.Forms.Cursors]::Hand

    $vscodeBtn.Add_Click({
        Write-QuestionLog @{
            timestamp = (Get-Date).ToString("o")
            question  = $questionText
            method    = "complex_popup"
            action    = "navigate_to_vscode"
        }
        Activate-VSCode
        $form.Close()
    })
    $form.Controls.Add($vscodeBtn)

    # --- 6. Footer label ---
    $footerTop = $btnTop + 48
    $footerLabel = New-Object System.Windows.Forms.Label
    $footerLabel.Text = "터미널에서 직접 응답하세요"
    $footerLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
    $footerLabel.ForeColor = [System.Drawing.Color]::Gray
    $footerLabel.Location = New-Object System.Drawing.Point(20, $footerTop)
    $footerLabel.Size = New-Object System.Drawing.Size(460, 20)
    $footerLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $form.Controls.Add($footerLabel)

    # Recalculate form height
    $actualHeight = $footerTop + 20 + 20
    $form.ClientSize = New-Object System.Drawing.Size(500, $actualHeight)

    # --- Keyboard shortcuts: Enter = click button, Esc = close ---
    $form.Add_KeyDown({
        param($sender, $e)
        switch ($e.KeyCode) {
            ([System.Windows.Forms.Keys]::Enter) {
                $vscodeBtn.PerformClick()
            }
            ([System.Windows.Forms.Keys]::Escape) {
                $form.Close()
            }
        }
    })

    # --- Auto-close timer (60 seconds) ---
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 60000
    $timer.Add_Tick({
        $timer.Stop()
        $form.Close()
    })
    $timer.Start()

    # --- Force foreground on shown ---
    $form.Add_Shown({
        $form.Activate()
        $form.BringToFront()
        $form.Focus()
        try { [User32.FgWin]::SetForegroundWindow($form.Handle) } catch {}
        $vscodeBtn.Focus()
    })

    # --- Show dialog ---
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $form.ShowDialog() | Out-Null

    # Cleanup
    $timer.Stop()
    $timer.Dispose()
    $form.Dispose()
}
