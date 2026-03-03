#!/bin/bash
# macOS Approval Dialog for Claude Code (osascript)
# IPC V2 compatible — outputs ALLOW|SCOPE or DENY|reason to stdout
#
# 2-stage dialog design (osascript max 3 buttons):
#   Stage 1: Allow/Deny/More → DENY|reason, ALLOW|ONCE, or proceed to stage 2
#   Stage 2: Scope selection  → ALLOW|SESSION, ALLOW|ALWAYS, ALLOW|TOOL_WILDCARD
#
# No burst mode on macOS (osascript has no checkbox control).

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Argument parsing (long-opt)
# ─────────────────────────────────────────────────────────────────────────────

TOOL_NAME=""
DETAIL_B64=""
RISK_TIER=1
PROJECT_NAME=""
INTENT_B64=""
CONTEXT_B64=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tool-name)      TOOL_NAME="$2";      shift 2 ;;
    --detail-base64)  DETAIL_B64="$2";     shift 2 ;;
    --risk-tier)      RISK_TIER="$2";      shift 2 ;;
    --project-name)   PROJECT_NAME="$2";   shift 2 ;;
    --intent-base64)  INTENT_B64="$2";     shift 2 ;;
    --context-base64) CONTEXT_B64="$2";    shift 2 ;;
    *)                shift ;;
  esac
done

if [[ -z "$TOOL_NAME" ]]; then
  TOOL_NAME="Unknown Tool"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Base64 decoding (macOS uses -D, GNU/Linux uses -d)
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

DETAIL=$(decode_b64 "$DETAIL_B64")
INTENT=$(decode_b64 "$INTENT_B64")
CONTEXT=$(decode_b64 "$CONTEXT_B64")

# ─────────────────────────────────────────────────────────────────────────────
# Risk tier configuration
# ─────────────────────────────────────────────────────────────────────────────

case "$RISK_TIER" in
  1) ICON="note";    DEFAULT_BTN="이번만 허용"; TIER_LABEL="[안전]"    ;;
  2) ICON="caution"; DEFAULT_BTN="이번만 허용"; TIER_LABEL="[주의]"    ;;
  3) ICON="stop";    DEFAULT_BTN="거부";        TIER_LABEL="[위험]"    ;;
  *)  ICON="note";   DEFAULT_BTN="이번만 허용"; TIER_LABEL="[안전]"    ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# Dialog text construction
# ─────────────────────────────────────────────────────────────────────────────

# Title bar
if [[ -n "$PROJECT_NAME" ]]; then
  TITLE="Claude Code - Tool Approval [$PROJECT_NAME]"
else
  TITLE="Claude Code - Tool Approval"
fi

# Body text: tier label + tool name + intent + detail (truncated)
DIALOG_TEXT="$TIER_LABEL $TOOL_NAME"

if [[ -n "$INTENT" ]]; then
  DIALOG_TEXT="$DIALOG_TEXT

→ $INTENT"
fi

# Truncate detail to 500 chars for display
if [[ ${#DETAIL} -gt 500 ]]; then
  DETAIL_DISPLAY="${DETAIL:0:500}..."
else
  DETAIL_DISPLAY="$DETAIL"
fi

if [[ -n "$DETAIL_DISPLAY" ]]; then
  DIALOG_TEXT="$DIALOG_TEXT

$DETAIL_DISPLAY"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Escape double quotes and backslashes for AppleScript string literal
# ─────────────────────────────────────────────────────────────────────────────

escape_applescript() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  echo "$s"
}

ESCAPED_TEXT=$(escape_applescript "$DIALOG_TEXT")
ESCAPED_TITLE=$(escape_applescript "$TITLE")

# ─────────────────────────────────────────────────────────────────────────────
# Stage 1: Allow / Deny / More scope
# ─────────────────────────────────────────────────────────────────────────────

STAGE1_RESULT=""
STAGE1_RESULT=$(osascript -e "
  try
    set dialogResult to display dialog \"$ESCAPED_TEXT\" with title \"$ESCAPED_TITLE\" buttons {\"거부\", \"이번만 허용\", \"더 넓은 범위...\"} default button \"$(escape_applescript "$DEFAULT_BTN")\" with icon $ICON
    return button returned of dialogResult
  on error number -128
    return \"__CANCELLED__\"
  end try
" 2>/dev/null) || true

# Handle cancel (red X or Esc) or osascript failure
if [[ -z "$STAGE1_RESULT" || "$STAGE1_RESULT" == "__CANCELLED__" ]]; then
  echo "DENY|User cancelled"
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# Stage 1 result routing
# ─────────────────────────────────────────────────────────────────────────────

case "$STAGE1_RESULT" in
  "거부")
    echo "DENY|User denied"
    exit 0
    ;;
  "이번만 허용")
    echo "ALLOW|ONCE"
    exit 0
    ;;
  "더 넓은 범위..."*)
    # Proceed to stage 2
    ;;
  *)
    # Unexpected value — treat as deny
    echo "DENY|User cancelled"
    exit 0
    ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2: Scope selection
# ─────────────────────────────────────────────────────────────────────────────

STAGE2_RESULT=""

if [[ "$RISK_TIER" == "3" ]]; then
  # TIER 3 restriction: only session scope allowed
  STAGE2_RESULT=$(osascript -e "
    try
      set dialogResult to display dialog \"승인 범위를 선택하세요\n(위험 도구: 세션 허용만 가능)\" with title \"$ESCAPED_TITLE\" buttons {\"세션 허용\"} default button \"세션 허용\" with icon stop
      return button returned of dialogResult
    on error number -128
      return \"__CANCELLED__\"
    end try
  " 2>/dev/null) || true
else
  STAGE2_RESULT=$(osascript -e "
    try
      set dialogResult to display dialog \"승인 범위를 선택하세요\" with title \"$ESCAPED_TITLE\" buttons {\"세션 허용\", \"항상 허용\", \"도구 전체 허용\"} default button \"세션 허용\" with icon $ICON
      return button returned of dialogResult
    on error number -128
      return \"__CANCELLED__\"
    end try
  " 2>/dev/null) || true
fi

# Handle cancel or failure in stage 2
if [[ -z "$STAGE2_RESULT" || "$STAGE2_RESULT" == "__CANCELLED__" ]]; then
  echo "DENY|User cancelled"
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2 result routing
# ─────────────────────────────────────────────────────────────────────────────

case "$STAGE2_RESULT" in
  "세션 허용")
    echo "ALLOW|SESSION"
    ;;
  "항상 허용")
    echo "ALLOW|ALWAYS"
    ;;
  "도구 전체 허용")
    echo "ALLOW|TOOL_WILDCARD"
    ;;
  *)
    echo "DENY|User cancelled"
    ;;
esac

exit 0
