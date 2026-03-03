#!/bin/bash
# OMC Hooks Uninstaller for macOS
# Usage: ./uninstall.sh

echo ""
echo "============================================"
echo "  OMC Hooks Uninstaller"
echo "============================================"
echo ""

# ---------------------------------------------------------------------------
# 1. Confirm
# ---------------------------------------------------------------------------
read -p "Remove OMC Hooks from Claude Code? (y/N) " CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
  echo "Aborted."
  exit 0
fi

HOOKS_DIR="$HOME/.claude/hooks"
HUD_DIR="$HOME/.claude/hud"
CLAUDE_DIR="$HOME/.claude"
SETTINGS_PATH="$CLAUDE_DIR/settings.json"

# ---------------------------------------------------------------------------
# 2. settings.json cleanup FIRST (before removing files)
# ---------------------------------------------------------------------------
echo ""
if [ -f "$SETTINGS_PATH" ]; then
  CLEANUP_SCRIPT="$(mktemp "${TMPDIR:-/tmp}/omc-cleanup-XXXXXX.mjs")"
  cat > "$CLEANUP_SCRIPT" <<'CLEANJS'
import { readFileSync, writeFileSync } from 'fs';

const settingsPath = process.argv[2];

try {
  const settings = JSON.parse(readFileSync(settingsPath, 'utf-8'));

  const hookFiles = [
    'permission-gui.mjs',
    'keyword-detector.mjs',
    'input-notify.mjs',
    'pre-tool-use.mjs',
    'post-tool-use.mjs',
    'session-start.mjs'
  ];

  const norm = p => p.replace(/\\/g, '/');
  const fname = p => {
    const parts = norm(p).split('/');
    return parts[parts.length - 1] || '';
  };

  // Remove hook entries that reference our hook files
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

      if (settings.hooks[event].length === 0) {
        delete settings.hooks[event];
      }
    }

    if (Object.keys(settings.hooks).length === 0) {
      delete settings.hooks;
    }
  }

  // Remove statusLine if it references omc-hud.mjs
  if (settings.statusLine) {
    const cmd = typeof settings.statusLine === 'string'
      ? settings.statusLine
      : (settings.statusLine.command || '');
    if (fname(cmd) === 'omc-hud.mjs') {
      delete settings.statusLine;
    }
  }

  writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + '\n', 'utf-8');
  console.log('OK');
} catch (e) {
  console.log('SKIP: ' + e.message);
}
CLEANJS

  RESULT="$(node "$CLEANUP_SCRIPT" "$SETTINGS_PATH" 2>&1)" || true
  rm -f "$CLEANUP_SCRIPT"

  if [ "$RESULT" = "OK" ]; then
    echo "[+] settings.json cleaned"
  else
    echo "[i] settings.json: $RESULT"
  fi
else
  echo "[i] settings.json not found, skipping cleanup"
fi

# ---------------------------------------------------------------------------
# 3. Define files to remove
# ---------------------------------------------------------------------------
HOOK_FILES=(
  "permission-gui.mjs"
  "keyword-detector.mjs"
  "input-notify.mjs"
  "pre-tool-use.mjs"
  "post-tool-use.mjs"
  "session-start.mjs"
)

UI_FILES=(
  "ui/mac/approval-dialog.sh"
  "ui/mac/question-dialog.sh"
)

HUD_FILES=(
  "omc-hud.mjs"
)

# ---------------------------------------------------------------------------
# 4. Remove hook files
# ---------------------------------------------------------------------------
REMOVED_HOOKS=0
for f in "${HOOK_FILES[@]}"; do
  TARGET="$HOOKS_DIR/$f"
  if [ -f "$TARGET" ]; then
    rm -f "$TARGET"
    REMOVED_HOOKS=$((REMOVED_HOOKS + 1))
  fi
done

# ---------------------------------------------------------------------------
# 5. Remove UI files
# ---------------------------------------------------------------------------
REMOVED_UI=0
for f in "${UI_FILES[@]}"; do
  TARGET="$HOOKS_DIR/$f"
  if [ -f "$TARGET" ]; then
    rm -f "$TARGET"
    REMOVED_UI=$((REMOVED_UI + 1))
  fi
done

# ---------------------------------------------------------------------------
# 6. Remove HUD files
# ---------------------------------------------------------------------------
REMOVED_HUD=0
for f in "${HUD_FILES[@]}"; do
  TARGET="$HUD_DIR/$f"
  if [ -f "$TARGET" ]; then
    rm -f "$TARGET"
    REMOVED_HUD=$((REMOVED_HUD + 1))
  fi
done

# ---------------------------------------------------------------------------
# 7. Clean up empty directories
# ---------------------------------------------------------------------------
MAC_DIR="$HOOKS_DIR/ui/mac"
UI_DIR="$HOOKS_DIR/ui"

# ui/mac/ — remove only if empty
if [ -d "$MAC_DIR" ] && [ -z "$(ls -A "$MAC_DIR" 2>/dev/null)" ]; then
  rmdir "$MAC_DIR" 2>/dev/null || true
fi

# ui/ — remove only if empty
if [ -d "$UI_DIR" ] && [ -z "$(ls -A "$UI_DIR" 2>/dev/null)" ]; then
  rmdir "$UI_DIR" 2>/dev/null || true
fi

# Do NOT remove $HOOKS_DIR — user may have other hooks

# hud/ — remove only if empty
if [ -d "$HUD_DIR" ] && [ -z "$(ls -A "$HUD_DIR" 2>/dev/null)" ]; then
  rmdir "$HUD_DIR" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 8. gui-approvals.json handling
# ---------------------------------------------------------------------------
APPROVALS_PATH="$CLAUDE_DIR/gui-approvals.json"
APPROVALS_REMOVED=false

if [ -f "$APPROVALS_PATH" ]; then
  read -p "Keep gui-approvals.json (your approval rules)? (Y/n) " KEEP_CHOICE
  if [ "$KEEP_CHOICE" = "n" ] || [ "$KEEP_CHOICE" = "N" ]; then
    rm -f "$APPROVALS_PATH"
    APPROVALS_REMOVED=true
  fi
fi

# ---------------------------------------------------------------------------
# 9. Summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================"
echo "  OMC Hooks Uninstaller — Summary"
echo "============================================"

if [ "$REMOVED_HOOKS" -gt 0 ]; then
  echo "[+] Removed $REMOVED_HOOKS hook file(s)"
else
  echo "[i] No hook files found to remove"
fi

if [ "$REMOVED_UI" -gt 0 ]; then
  echo "[+] Removed $REMOVED_UI UI file(s)"
else
  echo "[i] No UI files found to remove"
fi

if [ "$REMOVED_HUD" -gt 0 ]; then
  echo "[+] Removed $REMOVED_HUD HUD file(s)"
else
  echo "[i] No HUD files found to remove"
fi

echo "[+] settings.json cleaned"

if [ "$APPROVALS_REMOVED" = true ]; then
  echo "[+] gui-approvals.json removed"
elif [ -f "$APPROVALS_PATH" ]; then
  echo "[i] gui-approvals.json preserved"
fi

echo ""
echo "Uninstallation complete! Restart Claude Code."
echo ""
