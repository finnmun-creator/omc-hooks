# OMC Hooks

> **[한국어 가이드 (Korean Guide)](./README-ko.md)**

> Enhanced hooks for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) — GUI-based tool approval and status line HUD.

## Features

### Permission GUI
Risk-based tool approval popup that appears before Claude Code executes tools.

- **4-tier risk classification**: TIER 0 (auto-approve safe commands) → TIER 3 (dangerous, deny-focused)
- **4-level approval scope**: Once / Session / Always (pattern) / Tool-wide
- **Burst mode**: Approve multiple rapid-fire tool calls with one click (5s window)
- **Visual diff**: Color-coded old/new text for Edit operations
- **Context awareness**: Shows current user request and Claude's intent
- **Keyboard shortcuts**: [1]-[4] for scope, [Enter] to allow, [Esc] to deny
- **Per-project isolation**: Session approvals are scoped to the working directory

### Status Line HUD
Token usage display in Claude Code's status bar.

### Additional Hooks
- **Keyword Detector**: Detects mode keywords (ultrawork, analyze, search) and injects context
- **Input Notify**: Popup notification when Claude asks questions
- **Pre-Tool-Use**: Soft delegation warnings for source file edits
- **Post-Tool-Use**: Captures `<remember>` tags for persistent memory
- **Session Start**: Restores mode states across sessions

## Screenshots

> TODO: Add screenshots of the approval dialog and status line

## Requirements

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI
- Node.js 18+
- Windows 10/11 or macOS 12+

## Installation

### Quick Install (Recommended)

```
npx omc-hooks
```

Works on Windows, macOS, and Linux. Requires Node.js 18+.

### Update

```
npx omc-hooks@latest
```

### Uninstall via npx

```
npx omc-hooks uninstall
```

### Alternative: Git Clone

**Windows:**
```powershell
git clone https://github.com/finnmun-creator/omc-hooks.git
cd omc-hooks
.\install.ps1
```

**macOS / Linux:**
```bash
git clone https://github.com/finnmun-creator/omc-hooks.git
cd omc-hooks
bash install.sh
```

> **Note**: macOS uses native osascript (AppleScript) dialogs. Burst mode checkbox is not available on macOS due to osascript limitations.

## What Gets Installed

| Source | Destination | Purpose |
|--------|------------|---------|
| `hooks/*.mjs` | `~/.claude/hooks/` | Core hook scripts |
| `ui/win/*.ps1` | `~/.claude/hooks/ui/win/` | Windows UI dialogs |
| `ui/mac/*.sh` | `~/.claude/hooks/ui/mac/` | macOS UI dialogs (osascript) |
| `hud/omc-hud.mjs` | `~/.claude/hud/` | Status line script |
| `defaults/gui-approvals.json` | `~/.claude/gui-approvals.json` | Default approval rules (only if not exists) |

Your existing `settings.json` is safely merged — existing hooks are preserved, omc-hooks entries are added without duplicates.

## Uninstallation

**Windows:**
```powershell
.\uninstall.ps1
```

**macOS:**
```bash
bash uninstall.sh
```

- Removes all omc-hooks files
- Cleans up settings.json hook entries
- Preserves your `gui-approvals.json` (your approval rules) by default

## How It Works

### Risk Classification

| Tier | Color | Examples | Default Action |
|------|-------|----------|---------------|
| 0 | — | `ls`, `git status`, `Read`, `Grep` | Auto-approve |
| 1 | Green | `git commit`, `npm install`, `.md` edits | Allow-focused popup |
| 2 | Yellow | `curl`, pipes, source code edits | Allow-focused popup |
| 3 | Red | `rm`, `sudo`, `.env` edits | Deny-focused popup |

### Approval Scopes

| Scope | Persistence | Description |
|-------|------------|-------------|
| Once | None | Allow this single invocation |
| Session | Temp file (24h TTL) | Allow this pattern for the session |
| Always | `gui-approvals.json` | Permanently allow this pattern |
| Tool-wide | `gui-approvals.json` | Permanently allow ALL invocations of this tool |

### IPC Protocol

The hook communicates with UI dialogs via stdout:
```
ALLOW|ONCE          # Allow once
ALLOW|SESSION       # Allow for session
ALLOW|ALWAYS        # Always allow this pattern
ALLOW|TOOL_WILDCARD # Always allow this tool
DENY|reason         # Deny with reason
ALLOW|SCOPE|BURST   # Allow + enable burst mode
```

## Platform Notes

### macOS Limitations
- **No burst mode**: osascript `display dialog` doesn't support checkboxes, so burst mode (5-second multi-approve) is not available on macOS
- **3-button limit**: osascript supports max 3 buttons per dialog, so the approval flow uses a 2-stage dialog (allow/deny → scope selection)
- **TIER 3 scope restriction**: Dangerous tools on macOS can only be approved for the current session (no permanent approval)
- **No diff coloring**: osascript text dialogs are plain text only (no rich text formatting)

### Windows Features
- Full Windows Forms UI with rich text, diff coloring, and keyboard shortcuts
- Burst mode checkbox for rapid multi-tool approval
- Single-stage dialog with 4 radio buttons for scope selection

## Configuration

### gui-approvals.json

```json
{
  "rules": [],
  "version": 2,
  "config": {
    "autoApproveTier0": true,
    "autoApproveTier1": false,
    "dangerousRequireDoubleConfirm": true,
    "burstWindowMs": 5000,
    "sessionApprovalTTLHours": 24
  }
}
```

| Option | Default | Description |
|--------|---------|-------------|
| `autoApproveTier0` | `true` | Auto-approve safe commands (ls, git status, etc.) |
| `autoApproveTier1` | `false` | Auto-approve low-risk commands |
| `burstWindowMs` | `5000` | Burst mode window in milliseconds |
| `sessionApprovalTTLHours` | `24` | Session approval time-to-live |

## Project Structure

```
omc-hooks/
├── hooks/                    # Cross-platform Node.js hook engines
│   ├── permission-gui.mjs    # Risk classification + approval engine
│   ├── keyword-detector.mjs  # Keyword detection + context injection
│   ├── input-notify.mjs      # Question popup router
│   ├── pre-tool-use.mjs      # Source file delegation warnings
│   ├── post-tool-use.mjs     # <remember> tag processing
│   └── session-start.mjs     # Session state restoration
├── ui/
│   ├── win/                  # Windows-specific UI
│   │   ├── approval-dialog.ps1  # Approval popup (Windows Forms)
│   │   └── question-dialog.ps1  # Question popup (Windows Forms)
│   └── mac/                  # macOS-specific UI
│       ├── approval-dialog.sh   # Approval popup (osascript)
│       └── question-dialog.sh   # Question popup (osascript)
├── hud/
│   └── omc-hud.mjs          # Status line HUD wrapper
├── defaults/
│   ├── gui-approvals.json    # Default approval config
│   └── settings-hooks.json   # Hook registration template
├── lib/
│   └── settings-merger.mjs   # Safe settings.json merge logic
├── cli.mjs                   # Cross-platform CLI (npx omc-hooks)
├── package.json              # npm package manifest
├── install.ps1               # Windows installer
├── install.sh                # macOS installer
├── uninstall.ps1             # Windows uninstaller
├── uninstall.sh              # macOS uninstaller
└── README.md
```

## Roadmap

- [x] Phase 1: Windows MVP (installer + core hooks)
- [x] Phase 2: macOS support (osascript dialogs)
- [x] Phase 3: npm package (`npx omc-hooks`)
- [ ] Phase 4: GitHub release + CI/CD

## License

MIT
