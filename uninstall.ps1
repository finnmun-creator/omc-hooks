# OMC Hooks Uninstaller for Windows
param(
    [switch]$KeepApprovals  # Keep gui-approvals.json (default: keep)
)

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  OMC Hooks Uninstaller" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# 1. Confirm
$confirm = Read-Host "Remove OMC Hooks from Claude Code? (y/N)"
if ($confirm -ne 'y' -and $confirm -ne 'Y') {
    Write-Host "Aborted." -ForegroundColor Yellow
    exit 0
}

$hooksDir = "$env:USERPROFILE\.claude\hooks"
$hudDir   = "$env:USERPROFILE\.claude\hud"
$settingsPath = "$env:USERPROFILE\.claude\settings.json"

# 2. settings.json cleanup FIRST (before removing files)
Write-Host ""
if (Test-Path $settingsPath) {
    $cleanupScript = @"
import { readFileSync, writeFileSync } from 'fs';
const settingsPath = process.argv[2];
try {
  const settings = JSON.parse(readFileSync(settingsPath, 'utf-8'));
  const hookFiles = ['permission-gui.mjs', 'keyword-detector.mjs', 'input-notify.mjs', 'pre-tool-use.mjs', 'post-tool-use.mjs', 'session-start.mjs'];
  const norm = p => p.replace(/\\\\/g, '/');
  const fname = p => { const parts = norm(p).split('/'); return parts[parts.length - 1] || ''; };
  if (settings.hooks) {
    for (const [event, entries] of Object.entries(settings.hooks)) {
      if (!Array.isArray(entries)) continue;
      settings.hooks[event] = entries
        .map(entry => {
          if (!entry.hooks || !Array.isArray(entry.hooks)) return entry;
          const filtered = entry.hooks.filter(h => {
            if (!h.command) return true;
            const f = fname(h.command);
            return !hookFiles.includes(f);
          });
          return filtered.length === 0 ? null : { ...entry, hooks: filtered };
        })
        .filter(e => e !== null);
      if (settings.hooks[event].length === 0) delete settings.hooks[event];
    }
    if (Object.keys(settings.hooks).length === 0) delete settings.hooks;
  }
  if (settings.statusLine) {
    const cmd = typeof settings.statusLine === 'string' ? settings.statusLine : (settings.statusLine.command || '');
    if (fname(cmd) === 'omc-hud.mjs') delete settings.statusLine;
  }
  writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + '\\n', 'utf-8');
  console.log('OK');
} catch (e) { console.log('SKIP: ' + e.message); }
"@

    $tmpScript = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.mjs'
    Set-Content -Path $tmpScript -Value $cleanupScript -Encoding UTF8
    $result = node --input-type=module $tmpScript $settingsPath 2>&1
    Remove-Item $tmpScript -ErrorAction SilentlyContinue

    if ($result -eq 'OK') {
        Write-Host "[+] settings.json cleaned" -ForegroundColor Green
    } else {
        Write-Host "[i] settings.json: $result" -ForegroundColor Yellow
    }
} else {
    Write-Host "[i] settings.json not found, skipping cleanup" -ForegroundColor Yellow
}

# 3. Define files to remove
$hookFiles = @(
    "permission-gui.mjs",
    "keyword-detector.mjs",
    "input-notify.mjs",
    "pre-tool-use.mjs",
    "post-tool-use.mjs",
    "session-start.mjs"
)

$uiFiles = @(
    "ui\win\approval-dialog.ps1",
    "ui\win\question-dialog.ps1"
)

$hudFiles = @(
    "omc-hud.mjs"
)

# 4. Remove hook files
$removedHooks = 0
foreach ($f in $hookFiles) {
    $path = Join-Path $hooksDir $f
    if (Test-Path $path) {
        Remove-Item $path -Force -ErrorAction SilentlyContinue
        $removedHooks++
    }
}

# Remove UI files
$removedUi = 0
foreach ($f in $uiFiles) {
    $path = Join-Path $hooksDir $f
    if (Test-Path $path) {
        Remove-Item $path -Force -ErrorAction SilentlyContinue
        $removedUi++
    }
}

# Remove HUD files
$removedHud = 0
foreach ($f in $hudFiles) {
    $path = Join-Path $hudDir $f
    if (Test-Path $path) {
        Remove-Item $path -Force -ErrorAction SilentlyContinue
        $removedHud++
    }
}

# 5. Clean up empty directories
$winDir = Join-Path $hooksDir "ui\win"
$uiDirPath = Join-Path $hooksDir "ui"

if (Test-Path $winDir) {
    $winContents = Get-ChildItem $winDir -ErrorAction SilentlyContinue
    if (-not $winContents) {
        Remove-Item $winDir -Force -ErrorAction SilentlyContinue
    }
}

if (Test-Path $uiDirPath) {
    $uiContents = Get-ChildItem $uiDirPath -ErrorAction SilentlyContinue
    if (-not $uiContents) {
        Remove-Item $uiDirPath -Force -ErrorAction SilentlyContinue
    }
}

# Do NOT remove $hooksDir — user may have other hooks

if (Test-Path $hudDir) {
    $hudContents = Get-ChildItem $hudDir -ErrorAction SilentlyContinue
    if (-not $hudContents) {
        Remove-Item $hudDir -Force -ErrorAction SilentlyContinue
    }
}

# 6. gui-approvals.json handling
$approvalsPath = "$env:USERPROFILE\.claude\gui-approvals.json"
$approvalsRemoved = $false

if (Test-Path $approvalsPath) {
    if ($KeepApprovals) {
        # -KeepApprovals switch passed — skip prompt, keep file
    } else {
        $keepChoice = Read-Host "Keep gui-approvals.json (your approval rules)? (Y/n)"
        if ($keepChoice -eq 'n' -or $keepChoice -eq 'N') {
            Remove-Item $approvalsPath -Force -ErrorAction SilentlyContinue
            $approvalsRemoved = $true
        }
    }
}

# 7. Success message
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  OMC Hooks Uninstaller" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

if ($removedHooks -gt 0) {
    Write-Host "[+] Removed $removedHooks hook file(s)" -ForegroundColor Green
} else {
    Write-Host "[i] No hook files found to remove" -ForegroundColor Yellow
}

if ($removedUi -gt 0) {
    Write-Host "[+] Removed $removedUi UI file(s)" -ForegroundColor Green
} else {
    Write-Host "[i] No UI files found to remove" -ForegroundColor Yellow
}

if ($removedHud -gt 0) {
    Write-Host "[+] Removed $removedHud HUD file(s)" -ForegroundColor Green
} else {
    Write-Host "[i] No HUD files found to remove" -ForegroundColor Yellow
}

Write-Host "[+] settings.json cleaned" -ForegroundColor Green

if ($approvalsRemoved) {
    Write-Host "[+] gui-approvals.json removed" -ForegroundColor Green
} elseif (Test-Path $approvalsPath) {
    Write-Host "[i] gui-approvals.json preserved" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "Uninstallation complete! Restart Claude Code." -ForegroundColor Green
Write-Host ""
