#!/bin/bash
# OMC Hooks Installer for macOS
# Usage:
#   Local:  ./install.sh
#   Remote: curl -fsSL <url>/install.sh | bash
#           curl -fsSL <url>/install.sh | bash -s -- "https://github.com/user/omc-hooks"

set -e

echo ""
echo "============================================"
echo "  OMC Hooks Installer for macOS"
echo "============================================"
echo ""

# ---------------------------------------------------------------------------
# 1. Detect mode: LOCAL vs REMOTE
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" 2>/dev/null)" && pwd 2>/dev/null)" || SCRIPT_DIR=""

IS_LOCAL=false
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/hooks/permission-gui.mjs" ]; then
  IS_LOCAL=true
fi

# ---------------------------------------------------------------------------
# 2. Check Node.js (required)
# ---------------------------------------------------------------------------
if ! command -v node &>/dev/null; then
  echo "[ERROR] Node.js is required but was not found."
  echo "        Install from https://nodejs.org/ or via 'brew install node'"
  exit 1
fi
NODE_VERSION="$(node --version)"
echo "[OK] Node.js found: $NODE_VERSION"

# ---------------------------------------------------------------------------
# 3. Resolve source directory
# ---------------------------------------------------------------------------
TEMP_DIR=""
SOURCE_DIR=""

if [ "$IS_LOCAL" = true ]; then
  echo "[INFO] Local mode detected."
  SOURCE_DIR="$SCRIPT_DIR"
else
  echo "[INFO] Remote mode: downloading repo..."
  REPO_URL="${1:-https://github.com/user/omc-hooks}"
  TEMP_DIR="$(mktemp -d)"

  # Ensure cleanup on exit in remote mode
  cleanup_temp() {
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
      rm -rf "$TEMP_DIR"
    fi
  }
  trap cleanup_temp EXIT

  if command -v git &>/dev/null; then
    echo "[INFO] Cloning repo with git..."
    if git clone "$REPO_URL" "$TEMP_DIR/repo" 2>/dev/null; then
      SOURCE_DIR="$TEMP_DIR/repo"
    else
      echo "[ERROR] git clone failed for: $REPO_URL"
      exit 1
    fi
  else
    echo "[INFO] git not found; downloading zip..."
    ZIP_URL="${REPO_URL%/}/archive/refs/heads/main.zip"
    ZIP_PATH="$TEMP_DIR/omc-hooks.zip"

    if ! curl -fsSL "$ZIP_URL" -o "$ZIP_PATH"; then
      echo "[ERROR] Failed to download zip from: $ZIP_URL"
      exit 1
    fi

    unzip -q "$ZIP_PATH" -d "$TEMP_DIR"
    rm -f "$ZIP_PATH"

    # Zip extracts into a sub-folder like omc-hooks-main/
    EXTRACTED="$(find "$TEMP_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)"
    SOURCE_DIR="${EXTRACTED:-$TEMP_DIR}"
  fi

  if [ -z "$SOURCE_DIR" ]; then
    SOURCE_DIR="$TEMP_DIR"
  fi
fi

# ---------------------------------------------------------------------------
# 4. Create target directories
# ---------------------------------------------------------------------------
HOOKS_DIR="$HOME/.claude/hooks"
UI_MAC_DIR="$HOME/.claude/hooks/ui/mac"
HUD_DIR="$HOME/.claude/hud"
CLAUDE_DIR="$HOME/.claude"

mkdir -p "$HOOKS_DIR" "$UI_MAC_DIR" "$HUD_DIR"
echo "[OK] Target directory: $HOOKS_DIR"

# ---------------------------------------------------------------------------
# 5. Copy files
# ---------------------------------------------------------------------------

# hooks/*.mjs
HOOK_COUNT=0
if [ -d "$SOURCE_DIR/hooks" ]; then
  for f in "$SOURCE_DIR/hooks/"*.mjs; do
    [ -f "$f" ] || continue
    cp "$f" "$HOOKS_DIR/"
    HOOK_COUNT=$((HOOK_COUNT + 1))
  done
fi
echo "[OK] Copied $HOOK_COUNT hook files"

# ui/mac/*.sh
UI_COUNT=0
if [ -d "$SOURCE_DIR/ui/mac" ]; then
  for f in "$SOURCE_DIR/ui/mac/"*.sh; do
    [ -f "$f" ] || continue
    cp "$f" "$UI_MAC_DIR/"
    chmod +x "$UI_MAC_DIR/$(basename "$f")"
    UI_COUNT=$((UI_COUNT + 1))
  done
fi
echo "[OK] Copied $UI_COUNT UI files (chmod +x applied)"

# hud/omc-hud.mjs
HUD_COUNT=0
if [ -f "$SOURCE_DIR/hud/omc-hud.mjs" ]; then
  cp "$SOURCE_DIR/hud/omc-hud.mjs" "$HUD_DIR/"
  HUD_COUNT=1
fi
echo "[OK] Copied $HUD_COUNT HUD file"

# ---------------------------------------------------------------------------
# 6. gui-approvals.json — copy only if not already present
# ---------------------------------------------------------------------------
APPROVALS_TARGET="$CLAUDE_DIR/gui-approvals.json"
APPROVALS_SOURCE="$SOURCE_DIR/defaults/gui-approvals.json"

if [ -f "$APPROVALS_TARGET" ]; then
  echo "[OK] gui-approvals.json preserved (existing)"
elif [ -f "$APPROVALS_SOURCE" ]; then
  cp "$APPROVALS_SOURCE" "$APPROVALS_TARGET"
  echo "[OK] gui-approvals.json installed (new)"
else
  echo "[WARN] gui-approvals.json source not found — skipped"
fi

# ---------------------------------------------------------------------------
# 7. settings.json merge via Node.js
# ---------------------------------------------------------------------------
SETTINGS_PATH="$CLAUDE_DIR/settings.json"
TEMPLATE_PATH="$SOURCE_DIR/defaults/settings-hooks.json"
MERGER_PATH="$SOURCE_DIR/lib/settings-merger.mjs"

if [ -f "$MERGER_PATH" ] && [ -f "$TEMPLATE_PATH" ]; then
  # Build a temporary .mjs wrapper that imports the merger
  MERGE_SCRIPT="$(mktemp "${TMPDIR:-/tmp}/omc-merge-XXXXXX.mjs")"
  cat > "$MERGE_SCRIPT" <<MERGEJS
import { mergeSettings } from "file://${MERGER_PATH}";
try {
  const result = await mergeSettings(
    "${SETTINGS_PATH}",
    "${TEMPLATE_PATH}",
    "${HOME}"
  );
  console.log(JSON.stringify(result));
} catch (e) {
  console.error(e.message);
  process.exit(1);
}
MERGEJS

  MERGE_OUTPUT=""
  MERGE_RC=0
  MERGE_OUTPUT="$(node "$MERGE_SCRIPT" 2>&1)" || MERGE_RC=$?
  rm -f "$MERGE_SCRIPT"

  if [ "$MERGE_RC" -eq 0 ]; then
    # Parse the JSON result to extract added/skipped counts
    ADDED="$(echo "$MERGE_OUTPUT" | node -e "
      let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{
        try { const o=JSON.parse(d); console.log(o.added||0); }
        catch { console.log('?'); }
      });" 2>/dev/null)" || ADDED="?"
    SKIPPED="$(echo "$MERGE_OUTPUT" | node -e "
      let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{
        try { const o=JSON.parse(d); console.log(o.skipped||0); }
        catch { console.log('?'); }
      });" 2>/dev/null)" || SKIPPED="?"
    echo "[OK] settings.json merged (added: $ADDED, skipped: $SKIPPED)"
  else
    echo "[WARN] settings.json merge error: $MERGE_OUTPUT"
  fi
else
  echo "[WARN] settings-merger.mjs or settings-hooks.json not found — settings merge skipped"
fi

# ---------------------------------------------------------------------------
# 8. Cleanup temp directory (remote mode)
#    Handled by the EXIT trap set in step 3.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 9. Done
# ---------------------------------------------------------------------------
echo ""
echo "Installation complete! Restart Claude Code to activate."
echo ""
