#!/bin/bash
# macOS Question Dialog for Claude Code (osascript)
# Fire-and-forget — spawned detached by input-notify.mjs
# No stdout output required (caller does not read it).
#
# Two modes:
#   popup   — display dialog with buttons (2-3 options) or choose from list (4+)
#   complex — display notification + activate VS Code

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Argument parsing (long-opt)
# ─────────────────────────────────────────────────────────────────────────────

MODE="popup"
QUESTION_B64=""
OPTIONS_B64=""
REASON_TEXT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)            MODE="$2";          shift 2 ;;
    --question-base64) QUESTION_B64="$2";  shift 2 ;;
    --options-base64)  OPTIONS_B64="$2";   shift 2 ;;
    --reason-text)     REASON_TEXT="$2";   shift 2 ;;
    *)                 shift ;;
  esac
done

# ─────────────────────────────────────────────────────────────────────────────
# Base64 decoding (macOS -D, fallback -d)
# ─────────────────────────────────────────────────────────────────────────────

decode_b64() {
  local input="$1"
  if [[ -z "$input" ]]; then
    echo ""
    return
  fi
  echo "$input" | base64 -D 2>/dev/null \
    || echo "$input" | base64 -d 2>/dev/null \
    || echo "(decode failed)"
}

QUESTION=$(decode_b64 "$QUESTION_B64")
if [[ -z "$QUESTION" ]]; then
  QUESTION="입력이 필요합니다"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Log file (same location/format as Windows PS1)
# ─────────────────────────────────────────────────────────────────────────────

LOG_FILE="${TMPDIR:-/tmp}/claude-question-log.jsonl"

write_log() {
  local selected_index="$1"
  local selected_label="$2"
  local method="$3"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  # Use python3 for reliable JSON escaping
  python3 -c "
import json, sys
entry = {
    'timestamp': '$ts',
    'question': $(python3 -c "import json; print(json.dumps('''$QUESTION'''))" 2>/dev/null || echo '""'),
    'selectedOption': $selected_index,
    'selectedLabel': $(python3 -c "import json; print(json.dumps('''$selected_label'''))" 2>/dev/null || echo '""'),
    'method': '$method'
}
print(json.dumps(entry))
" >> "$LOG_FILE" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# Activate VS Code after interaction
# ─────────────────────────────────────────────────────────────────────────────

activate_vscode() {
  osascript -e 'tell application "Visual Studio Code" to activate' 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# AppleScript string escaping
# ─────────────────────────────────────────────────────────────────────────────

escape_applescript() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  echo "$s"
}

# ─────────────────────────────────────────────────────────────────────────────
# POPUP MODE
# ─────────────────────────────────────────────────────────────────────────────

if [[ "$MODE" == "popup" ]]; then

  # Parse options JSON array using python3 (available on all macOS)
  OPTIONS_JSON=$(decode_b64 "$OPTIONS_B64")
  if [[ -z "$OPTIONS_JSON" ]]; then
    OPTIONS_JSON="[]"
  fi

  # Extract labels into bash array
  OPTIONS=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && OPTIONS+=("$line")
  done < <(echo "$OPTIONS_JSON" | python3 -c "import sys,json; [print(x) for x in json.load(sys.stdin)]" 2>/dev/null)

  NUM_OPTIONS=${#OPTIONS[@]}
  ESCAPED_Q=$(escape_applescript "$QUESTION")

  if [[ $NUM_OPTIONS -le 3 && $NUM_OPTIONS -ge 1 ]]; then
    # ── display dialog with buttons (max 3) ──
    BUTTON_LIST=""
    for opt in "${OPTIONS[@]}"; do
      escaped_opt=$(escape_applescript "$opt")
      if [[ -n "$BUTTON_LIST" ]]; then
        BUTTON_LIST="$BUTTON_LIST, \"$escaped_opt\""
      else
        BUTTON_LIST="\"$escaped_opt\""
      fi
    done

    RESULT=$(osascript -e "
      try
        set dialogResult to display dialog \"$ESCAPED_Q\" with title \"Claude Code\" buttons {$BUTTON_LIST} default button 1 with icon note
        return button returned of dialogResult
      on error number -128
        return \"__CANCELLED__\"
      end try
    " 2>/dev/null) || true

    if [[ -n "$RESULT" && "$RESULT" != "__CANCELLED__" ]]; then
      # Find the index of the selected option
      for i in "${!OPTIONS[@]}"; do
        if [[ "${OPTIONS[$i]}" == "$RESULT" ]]; then
          write_log "$((i + 1))" "$RESULT" "popup"
          break
        fi
      done
    fi

  elif [[ $NUM_OPTIONS -ge 4 ]]; then
    # ── choose from list for 4+ options ──
    LIST_ITEMS=""
    for opt in "${OPTIONS[@]}"; do
      escaped_opt=$(escape_applescript "$opt")
      if [[ -n "$LIST_ITEMS" ]]; then
        LIST_ITEMS="$LIST_ITEMS, \"$escaped_opt\""
      else
        LIST_ITEMS="\"$escaped_opt\""
      fi
    done

    RESULT=$(osascript -e "
      try
        set chosenItem to choose from list {$LIST_ITEMS} with title \"Claude Code\" with prompt \"$ESCAPED_Q\" default items {\"$(escape_applescript "${OPTIONS[0]}")\"}
        if chosenItem is false then
          return \"__CANCELLED__\"
        else
          return item 1 of chosenItem
        end if
      on error number -128
        return \"__CANCELLED__\"
      end try
    " 2>/dev/null) || true

    if [[ -n "$RESULT" && "$RESULT" != "__CANCELLED__" ]]; then
      for i in "${!OPTIONS[@]}"; do
        if [[ "${OPTIONS[$i]}" == "$RESULT" ]]; then
          write_log "$((i + 1))" "$RESULT" "popup_list"
          break
        fi
      done
    fi
  fi

  activate_vscode

# ─────────────────────────────────────────────────────────────────────────────
# COMPLEX MODE
# ─────────────────────────────────────────────────────────────────────────────

elif [[ "$MODE" == "complex" ]]; then

  if [[ -z "$REASON_TEXT" ]]; then
    REASON_TEXT="터미널에서 직접 확인하세요"
  fi

  ESCAPED_Q=$(escape_applescript "$QUESTION")
  ESCAPED_REASON=$(escape_applescript "$REASON_TEXT")

  # Show notification
  osascript -e "display notification \"$ESCAPED_Q\" with title \"Claude Code\" subtitle \"$ESCAPED_REASON\"" 2>/dev/null || true

  # Activate VS Code
  activate_vscode
fi

exit 0
