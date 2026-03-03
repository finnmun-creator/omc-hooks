# OMC Hooks Installer for Windows
# Usage: .\install.ps1 [-RepoUrl "https://github.com/user/omc-hooks"]

param(
    [string]$RepoUrl = ""
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  OMC Hooks Installer for Windows" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# 1. Detect mode: LOCAL vs REMOTE
# ---------------------------------------------------------------------------
$scriptDir = $PSScriptRoot
if (-not $scriptDir) {
    # Invoked via iex (piped) - PSScriptRoot is empty
    $scriptDir = $null
}

$isLocal = $false
if ($scriptDir -and (Test-Path (Join-Path $scriptDir "hooks/permission-gui.mjs"))) {
    $isLocal = $true
}

# ---------------------------------------------------------------------------
# 2. Check Node.js (required)
# ---------------------------------------------------------------------------
try {
    $nodeVersion = & node --version 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Node.js not found" }
    Write-Host "[OK] Node.js found: $nodeVersion" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] Node.js is required but was not found." -ForegroundColor Red
    Write-Host "        Install from https://nodejs.org/ and re-run." -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# 3. Resolve source directory
# ---------------------------------------------------------------------------
$tempDir = $null

if ($isLocal) {
    Write-Host "[INFO] Local mode detected." -ForegroundColor DarkGray
    $sourceDir = $scriptDir
} else {
    Write-Host "[INFO] Remote mode: downloading repo..." -ForegroundColor DarkGray

    if (-not $RepoUrl) {
        # Default repo URL when run via one-liner
        $RepoUrl = "https://github.com/user/omc-hooks"
    }

    $tempDir = Join-Path $env:TEMP ("omc-hooks-install-" + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    $gitAvailable = $false
    try {
        & git --version 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $gitAvailable = $true }
    } catch {}

    if ($gitAvailable) {
        Write-Host "[INFO] Cloning repo with git..." -ForegroundColor DarkGray
        & git clone $RepoUrl $tempDir 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[ERROR] git clone failed for: $RepoUrl" -ForegroundColor Red
            exit 1
        }
        $sourceDir = $tempDir
    } else {
        Write-Host "[INFO] git not found; downloading zip..." -ForegroundColor DarkGray
        # Convert GitHub repo URL to zip download URL
        $zipUrl = $RepoUrl.TrimEnd("/") + "/archive/refs/heads/main.zip"
        $zipPath = Join-Path $env:TEMP ("omc-hooks-" + [System.IO.Path]::GetRandomFileName() + ".zip")
        try {
            Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
        } catch {
            Write-Host "[ERROR] Failed to download zip from: $zipUrl" -ForegroundColor Red
            exit 1
        }
        Expand-Archive -Path $zipPath -DestinationPath $tempDir -Force
        Remove-Item $zipPath -Force

        # Zip extracts into a sub-folder like omc-hooks-main/
        $extracted = Get-ChildItem -Path $tempDir -Directory | Select-Object -First 1
        if ($extracted) {
            $sourceDir = $extracted.FullName
        } else {
            $sourceDir = $tempDir
        }
    }

    if (-not $sourceDir) { $sourceDir = $tempDir }
}

# ---------------------------------------------------------------------------
# 4. Create target directories
# ---------------------------------------------------------------------------
$home = $env:USERPROFILE
$hooksDir   = Join-Path $home ".claude\hooks"
$uiWinDir   = Join-Path $home ".claude\hooks\ui\win"
$hudDir     = Join-Path $home ".claude\hud"
$claudeDir  = Join-Path $home ".claude"

foreach ($dir in @($hooksDir, $uiWinDir, $hudDir)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

Write-Host "[OK] Target directory: $hooksDir" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 5. Copy files
# ---------------------------------------------------------------------------

# hooks/*.mjs
$hookFiles = @()
$srcHooks = Join-Path $sourceDir "hooks"
if (Test-Path $srcHooks) {
    $hookFiles = Get-ChildItem -Path $srcHooks -Filter "*.mjs" -File
    foreach ($f in $hookFiles) {
        Copy-Item -Path $f.FullName -Destination $hooksDir -Force
    }
}
Write-Host "[OK] Copied $($hookFiles.Count) hook files" -ForegroundColor Green

# ui/win/*.ps1
$uiFiles = @()
$srcUiWin = Join-Path $sourceDir "ui\win"
if (Test-Path $srcUiWin) {
    $uiFiles = Get-ChildItem -Path $srcUiWin -Filter "*.ps1" -File
    foreach ($f in $uiFiles) {
        Copy-Item -Path $f.FullName -Destination $uiWinDir -Force
    }
}
Write-Host "[OK] Copied $($uiFiles.Count) UI files" -ForegroundColor Green

# hud/omc-hud.mjs
$hudFile = Join-Path $sourceDir "hud\omc-hud.mjs"
$hudCopied = 0
if (Test-Path $hudFile) {
    Copy-Item -Path $hudFile -Destination $hudDir -Force
    $hudCopied = 1
}
Write-Host "[OK] Copied $hudCopied HUD file" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 6. gui-approvals.json — copy only if not already present
# ---------------------------------------------------------------------------
$guiApprovalsTarget = Join-Path $claudeDir "gui-approvals.json"
$guiApprovalsSource = Join-Path $sourceDir "defaults\gui-approvals.json"

if (Test-Path $guiApprovalsTarget) {
    Write-Host "[OK] gui-approvals.json preserved (existing)" -ForegroundColor Green
} elseif (Test-Path $guiApprovalsSource) {
    Copy-Item -Path $guiApprovalsSource -Destination $guiApprovalsTarget -Force
    Write-Host "[OK] gui-approvals.json installed (new)" -ForegroundColor Green
} else {
    Write-Host "[WARN] gui-approvals.json source not found — skipped" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# 7. settings.json merge via Node.js inline module
# ---------------------------------------------------------------------------
$settingsPath  = Join-Path $claudeDir "settings.json"
$templatePath  = Join-Path $sourceDir "defaults\settings-hooks.json"
$mergerPath    = Join-Path $sourceDir "lib\settings-merger.mjs"

if ((Test-Path $mergerPath) -and (Test-Path $templatePath)) {
    # Normalize paths to forward slashes for Node.js
    $escapedMerger   = $mergerPath.Replace("\", "/")
    $escapedSettings = $settingsPath.Replace("\", "/")
    $escapedTemplate = $templatePath.Replace("\", "/")
    $escapedHome     = $home.Replace("\", "/")

    $inlineScript = @"
import { mergeSettings } from 'file:///$escapedMerger';
try {
  const result = await mergeSettings('$escapedSettings', '$escapedTemplate', '$escapedHome');
  console.log(JSON.stringify(result));
} catch (e) {
  console.error(e.message);
  process.exit(1);
}
"@

    try {
        $mergeOutput = $inlineScript | & node --input-type=module 2>&1
        if ($LASTEXITCODE -eq 0) {
            $mergeResult = $mergeOutput | ConvertFrom-Json -ErrorAction SilentlyContinue
            $added   = if ($mergeResult.added)   { $mergeResult.added }   else { 0 }
            $skipped = if ($mergeResult.skipped) { $mergeResult.skipped } else { 0 }
            Write-Host "[OK] settings.json merged (added: $added, skipped: $skipped)" -ForegroundColor Green
        } else {
            Write-Host "[WARN] settings.json merge returned an error: $mergeOutput" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "[WARN] settings.json merge failed: $_" -ForegroundColor Yellow
    }
} else {
    Write-Host "[WARN] settings-merger.mjs or settings-hooks.json not found — settings merge skipped" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# 8. Cleanup temp directory (remote mode)
# ---------------------------------------------------------------------------
if ($tempDir -and (Test-Path $tempDir)) {
    try {
        Remove-Item -Path $tempDir -Recurse -Force
    } catch {
        Write-Host "[WARN] Could not remove temp dir: $tempDir" -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# 9. Done
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "Installation complete! Restart Claude Code to activate." -ForegroundColor Cyan
Write-Host ""
