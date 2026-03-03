#!/usr/bin/env node
/**
 * Permission GUI Hook for Claude Code — V2
 *
 * Flow:
 *   stdin JSON
 *     → TIER 0 auto-approve (safe commands, read-only tools, agents)
 *     → gui-approvals.json rule matching (V1/V2 with scope)
 *     → Session approval file matching (per-PID, 24h TTL)
 *     → Burst file matching (per-tool, 5s TTL)
 *     → Risk classification → spawn OS-native popup (PS1/osascript) with risk tier
 *     → Parse V2 IPC response (ALLOW|ONCE/SESSION/ALWAYS/TOOL_WILDCARD, DENY|reason, BURST|SCOPE)
 *     → return {decision: "allow"} or {decision: "deny", reason: "..."}
 */

import { execSync } from 'child_process';
import { readFileSync, writeFileSync, existsSync, readdirSync, unlinkSync, statSync, mkdirSync } from 'fs';
import { join } from 'path';
import { tmpdir, platform } from 'os';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const HOME = process.env.USERPROFILE || process.env.HOME || '';
const APPROVALS_FILE = join(HOME, '.claude', 'gui-approvals.json');

// OS-specific UI script routing
function getApprovalUICommand(toolName, detailB64, tier, projName, intentB64, contextB64) {
  const uiDir = join(HOME, '.claude', 'hooks', 'ui');

  if (platform() === 'win32') {
    const script = join(uiDir, 'win', 'approval-dialog.ps1');
    return `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${script}" ` +
      `-ToolName "${toolName}" -DetailBase64 "${detailB64}" -RiskTier ${tier}` +
      ` -ProjectName "${projName.replace(/"/g, "'")}"` +
      (intentB64 ? ` -IntentBase64 "${intentB64}"` : '') +
      (contextB64 ? ` -ContextBase64 "${contextB64}"` : '');
  }

  if (platform() === 'darwin') {
    const script = join(uiDir, 'mac', 'approval-dialog.sh');
    return `bash "${script}" ` +
      `--tool-name "${toolName}" --detail-base64 "${detailB64}" --risk-tier ${tier}` +
      ` --project-name "${projName.replace(/"/g, "'")}"` +
      (intentB64 ? ` --intent-base64 "${intentB64}"` : '') +
      (contextB64 ? ` --context-base64 "${contextB64}"` : '');
  }

  // Unsupported platform → null (tier-based auto-decision)
  return null;
}
const TEMP_DIR = tmpdir();
// cwdHash: deterministic hash of cwd for per-project session isolation
function cwdHash() {
  const cwd = process.cwd();
  let hash = 0;
  for (let i = 0; i < cwd.length; i++) {
    hash = ((hash << 5) - hash + cwd.charCodeAt(i)) | 0;
  }
  return Math.abs(hash).toString(36);
}

function projectName() {
  const cwd = process.cwd();
  const parts = cwd.replace(/\\/g, '/').split('/');
  return parts[parts.length - 1] || 'unknown';
}

const SESSION_KEY = cwdHash();

const DEFAULT_CONFIG = {
  autoApproveTier0: true,
  autoApproveTier1: false,
  dangerousRequireDoubleConfirm: true,
  burstWindowMs: 5000,
  sessionApprovalTTLHours: 24,
};

// ---------------------------------------------------------------------------
// TIER 0 — Safe command whitelist
// ---------------------------------------------------------------------------

const SAFE_COMMANDS = new Set([
  'echo', 'printf', 'pwd', 'ls', 'dir', 'wc', 'date', 'whoami',
  'hostname', 'which', 'where', 'type', 'file', 'stat', 'du', 'df',
  'env', 'printenv', 'uname', 'id', 'cat', 'head', 'tail',
  'sort', 'uniq', 'diff', 'find', 'grep', 'rg', 'tree',
]);

const SAFE_COMMAND_PATTERNS = [
  /^git\s+(status|diff|log|branch|show|fetch|remote|tag|rev-parse)/,
  /^npm\s+(test|run\s+(test|lint|build|check)|ls|outdated|audit)/,
  /^tsc(\s|$)/, /^eslint\s/, /^prettier\s/,
  /^pytest/, /^python\s+-m\s+pytest/,
];

const SAFE_TOOLS = new Set([
  'Read', 'Grep', 'Glob', 'Agent', 'Task',
]);

// ---------------------------------------------------------------------------
// TIER 2/3 — Dangerous patterns
// ---------------------------------------------------------------------------

const SOURCE_EXTENSIONS = new Set([
  '.ts', '.tsx', '.js', '.jsx', '.py', '.go', '.rs',
  '.java', '.c', '.cpp', '.h', '.svelte', '.vue',
]);

const TIER3_BASH_PATTERNS = [
  /\brm\b/, /\bsudo\b/, /\beval\b/,
];

const TIER3_SQL_KEYWORDS = [
  /\bDROP\b/i, /\bDELETE\b/i,
];

// ---------------------------------------------------------------------------
// Risk classification
// ---------------------------------------------------------------------------

/**
 * Classify the risk tier for a tool invocation.
 * Returns 0 (auto-approve) through 3 (dangerous).
 */
function classifyRiskTier(toolName, toolInput) {
  // --- TIER 0: Safe tools (read-only, agents) ---
  if (SAFE_TOOLS.has(toolName)) {
    return 0;
  }

  // --- Bash-specific classification ---
  if (toolName === 'Bash') {
    const cmd = (toolInput.command || '').trim();
    const baseCmd = cmd.split(/\s+/)[0];

    // TIER 3: Dangerous bash commands
    if (TIER3_BASH_PATTERNS.some(p => p.test(cmd))) return 3;

    // TIER 2: Pipes, redirects, curl/wget (check BEFORE safe commands,
    // because "cat foo | rm bar" should not auto-approve just because cat is safe)
    if (/\|/.test(cmd) || />/.test(cmd)) return 2;
    if (/^(curl|wget)\b/.test(cmd)) return 2;

    // TIER 0: Safe single commands (no pipes/redirects at this point)
    if (SAFE_COMMANDS.has(baseCmd)) return 0;
    if (SAFE_COMMAND_PATTERNS.some(p => p.test(cmd))) return 0;

    // TIER 1: git write ops, npm install
    if (/^git\s+(add|commit|push|merge|rebase|checkout|switch|stash|pull|clone)/.test(cmd)) return 1;
    if (/^npm\s+install/.test(cmd)) return 1;

    // Default for bash: TIER 1
    return 1;
  }

  // --- Edit/Write classification ---
  if (toolName === 'Edit' || toolName === 'Write') {
    const filePath = toolInput.file_path || toolInput.filePath || '';

    // TIER 3: .env modification
    if (/\.env$/i.test(filePath) || /[/\\]\.env\b/i.test(filePath)) return 3;

    // TIER 1: Markdown, JSON, .claude/** paths
    if (/\.(md|json)$/i.test(filePath)) return 1;
    if (/[/\\]\.claude[/\\]/i.test(filePath)) return 1;

    // TIER 2: Source code files
    const ext = filePath.includes('.') ? '.' + filePath.split('.').pop().toLowerCase() : '';
    if (SOURCE_EXTENSIONS.has(ext)) return 2;

    // Default for file operations: TIER 1
    return 1;
  }

  // --- WebFetch ---
  if (toolName === 'WebFetch') return 2;

  // --- NotebookEdit ---
  if (toolName === 'NotebookEdit') return 2;

  // Default: TIER 1
  return 1;
}

// ---------------------------------------------------------------------------
// Approvals persistence (V1/V2 support)
// ---------------------------------------------------------------------------

function loadApprovals() {
  try {
    if (existsSync(APPROVALS_FILE)) {
      const data = JSON.parse(readFileSync(APPROVALS_FILE, 'utf-8'));
      if (Array.isArray(data.rules)) {
        // V1 → V2 auto-migration
        if (!data.version || data.version < 2) {
          data.version = 2;
          data.config = { ...DEFAULT_CONFIG, ...(data.config || {}) };
          for (const rule of data.rules) {
            if (!rule.scope) rule.scope = 'always';
          }
          try { saveApprovals(data); } catch { /* migration save failed — non-fatal */ }
        }
        // Ensure config has all defaults
        data.config = { ...DEFAULT_CONFIG, ...(data.config || {}) };
        return data;
      }
    }
  } catch { /* corrupted → reset */ }
  return { rules: [], version: 2, config: { ...DEFAULT_CONFIG } };
}

function saveApprovals(approvals) {
  try {
    const dir = join(HOME, '.claude');
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
    writeFileSync(APPROVALS_FILE, JSON.stringify(approvals, null, 2), 'utf-8');
  } catch { /* silently fail — popup will show next time */ }
}

// ---------------------------------------------------------------------------
// Session approval storage (per-project cwdHash, 24h TTL)
// ---------------------------------------------------------------------------

function sessionFilePath() {
  return join(TEMP_DIR, `claude-session-approvals-${SESSION_KEY}.json`);
}

function loadSessionApprovals() {
  const fp = sessionFilePath();
  try {
    if (existsSync(fp)) {
      const data = JSON.parse(readFileSync(fp, 'utf-8'));
      const ttl = data.ttl || 86400000; // 24h default
      // Check overall file TTL
      if (data.rules && Array.isArray(data.rules)) {
        const validRules = data.rules.filter(r => {
          const age = Date.now() - new Date(r.addedAt).getTime();
          return age < ttl;
        });
        if (validRules.length > 0) {
          return { ...data, rules: validRules };
        }
      }
    }
  } catch { /* corrupted or missing */ }
  return { rules: [], ttl: 86400000 };
}

function saveSessionApproval(toolName, pattern) {
  const session = loadSessionApprovals();
  session.rules.push({
    tool: toolName,
    pattern,
    addedAt: new Date().toISOString(),
  });
  session.ttl = 86400000;
  try {
    writeFileSync(sessionFilePath(), JSON.stringify(session, null, 2), 'utf-8');
  } catch { /* non-fatal */ }
}

// ---------------------------------------------------------------------------
// Burst mode (per-tool, 5s TTL)
// ---------------------------------------------------------------------------

function burstFilePath(toolName) {
  return join(TEMP_DIR, `claude-burst-${toolName}.json`);
}

function isBurstActive(toolName, config) {
  const fp = burstFilePath(toolName);
  try {
    if (existsSync(fp)) {
      const data = JSON.parse(readFileSync(fp, 'utf-8'));
      const ttl = data.ttlMs || config.burstWindowMs || 5000;
      const age = Date.now() - new Date(data.approvedAt).getTime();
      return age < ttl;
    }
  } catch { /* corrupted or missing */ }
  return false;
}

function createBurstFile(toolName, config) {
  const fp = burstFilePath(toolName);
  const data = {
    tool: toolName,
    approvedAt: new Date().toISOString(),
    ttlMs: config.burstWindowMs || 5000,
  };
  try {
    writeFileSync(fp, JSON.stringify(data, null, 2), 'utf-8');
  } catch { /* non-fatal */ }
}

// ---------------------------------------------------------------------------
// Stale file cleanup (24h+ session files, expired burst files)
// ---------------------------------------------------------------------------

function cleanStaleFiles() {
  try {
    const files = readdirSync(TEMP_DIR);
    const now = Date.now();
    const DAY_MS = 86400000;

    for (const f of files) {
      const fp = join(TEMP_DIR, f);

      // Session approval files older than 24h
      if (f.startsWith('claude-session-approvals-')) {
        try {
          const st = statSync(fp);
          if (now - st.mtimeMs > DAY_MS) {
            unlinkSync(fp);
          }
        } catch { /* skip */ }
      }

      // Burst files older than 30s (generous grace period)
      if (f.startsWith('claude-burst-')) {
        try {
          const st = statSync(fp);
          if (now - st.mtimeMs > 30000) {
            unlinkSync(fp);
          }
        } catch { /* skip */ }
      }
    }
  } catch { /* non-fatal — cleanup is best-effort */ }
}

// ---------------------------------------------------------------------------
// Load current user context (written by keyword-detector hook)
// ---------------------------------------------------------------------------

function loadCurrentContext() {
  try {
    const tempDir = process.env.TEMP || process.env.TMP || tmpdir();
    const key = cwdHash();
    const contextFile = join(tempDir, `claude-context-${key}.json`);
    if (existsSync(contextFile)) {
      const data = JSON.parse(readFileSync(contextFile, 'utf-8'));
      // Only use if less than 1 hour old
      const age = Date.now() - new Date(data.timestamp).getTime();
      if (age < 3600000 && data.userRequest) {
        return data.userRequest;
      }
    }
  } catch { /* non-fatal */ }
  return '';
}

// ---------------------------------------------------------------------------
// Pattern matching (tool-specific) — extended for V2 scope
// ---------------------------------------------------------------------------

function matchesRule(rules, toolName, toolInput) {
  return rules.some(rule => {
    if (rule.tool !== toolName && rule.scope !== 'tool_wildcard') return false;

    // tool_wildcard scope: match any invocation of this tool
    if (rule.scope === 'tool_wildcard' && rule.tool === toolName) return true;

    if (rule.tool !== toolName) return false;
    if (rule.pattern === '*') return true;

    switch (toolName) {
      case 'Bash': {
        const cmd = (toolInput.command || '').trim();
        const baseCmd = cmd.split(/\s+/)[0];
        return baseCmd === rule.pattern;
      }
      case 'Edit':
      case 'Write':
        return (toolInput.file_path || toolInput.filePath || '') === rule.pattern;
      case 'WebFetch': {
        try { return new URL(toolInput.url || '').hostname === rule.pattern; }
        catch { return false; }
      }
      case 'Task':
        return (toolInput.subagent_type || toolInput.description || '') === rule.pattern;
      case 'NotebookEdit':
        return (toolInput.notebook_path || '') === rule.pattern;
      default:
        return false;
    }
  });
}

// ---------------------------------------------------------------------------
// Intent extraction (Claude's reasoning — shown as separate panel in popup)
// ---------------------------------------------------------------------------

function extractIntent(toolName, toolInput) {
  switch (toolName) {
    case 'Bash':
      return toolInput.description || '';
    case 'Edit':
    case 'Write': {
      const file = toolInput.file_path || toolInput.filePath || '';
      const name = file.replace(/\\/g, '/').split('/').pop() || '';
      return toolName === 'Edit' ? `${name} 파일 수정` : `${name} 파일 작성`;
    }
    case 'WebFetch':
      return toolInput.prompt ? `웹 조회: ${toolInput.prompt.substring(0, 80)}` : '';
    case 'Task':
      return toolInput.description || '';
    case 'NotebookEdit':
      return toolInput.new_source ? '노트북 셀 편집' : '';
    default:
      return '';
  }
}

// ---------------------------------------------------------------------------
// Detail extraction (human-readable summary for popup)
// ---------------------------------------------------------------------------

function extractDetail(toolName, toolInput) {
  switch (toolName) {
    case 'Bash': {
      const cmd  = toolInput.command || '';
      return `$ ${cmd}`;
    }
    case 'Edit': {
      const file   = toolInput.file_path || toolInput.filePath || '';
      const oldStr = (toolInput.old_string || '').substring(0, 300);
      const newStr = (toolInput.new_string || '').substring(0, 300);
      return `File: ${file}\n\n--- old ---\n${oldStr}\n\n+++ new +++\n${newStr}`;
    }
    case 'Write': {
      const file    = toolInput.file_path || toolInput.filePath || '';
      const content = toolInput.content || '';
      const preview = content.length > 400 ? content.substring(0, 400) + '\n...' : content;
      return `File: ${file}\nSize: ${content.length} chars\n\n${preview}`;
    }
    case 'WebFetch': {
      return `URL: ${toolInput.url || ''}\nPrompt: ${toolInput.prompt || ''}`;
    }
    case 'Task': {
      const agent  = toolInput.subagent_type || '';
      const desc   = toolInput.description || '';
      const prompt = (toolInput.prompt || '').substring(0, 400);
      return `Agent: ${agent}\nDescription: ${desc}\n\n${prompt}`;
    }
    case 'NotebookEdit': {
      const nb = toolInput.notebook_path || '';
      return `Notebook: ${nb}\nCell: ${toolInput.cell_number ?? 'N/A'}\nMode: ${toolInput.edit_mode || 'replace'}`;
    }
    default:
      return JSON.stringify(toolInput, null, 2).substring(0, 500);
  }
}

// ---------------------------------------------------------------------------
// Pattern generation (for approval rules)
// ---------------------------------------------------------------------------

function generatePattern(toolName, toolInput) {
  switch (toolName) {
    case 'Bash': {
      const cmd = (toolInput.command || '').trim();
      return cmd.split(/\s+/)[0] || '*';
    }
    case 'Edit':
    case 'Write':
      return toolInput.file_path || toolInput.filePath || '*';
    case 'WebFetch': {
      try { return new URL(toolInput.url || '').hostname; }
      catch { return '*'; }
    }
    case 'Task':
      return toolInput.subagent_type || toolInput.description || '*';
    case 'NotebookEdit':
      return toolInput.notebook_path || '*';
    default:
      return '*';
  }
}

// ---------------------------------------------------------------------------
// Output helpers
// ---------------------------------------------------------------------------

function emitAllow() {
  console.log(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'allow',
    },
  }));
}

function emitDeny(reason) {
  console.log(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason: reason || 'User denied via GUI popup',
    },
  }));
}

// ---------------------------------------------------------------------------
// IPC response parsing (V2)
// ---------------------------------------------------------------------------

/**
 * Parse the PowerShell dialog response.
 *
 * V2 formats:
 *   ALLOW|ONCE
 *   ALLOW|SESSION
 *   ALLOW|ALWAYS
 *   ALLOW|TOOL_WILDCARD
 *   DENY|reason
 *   BURST|SCOPE  (burst checkbox was checked; SCOPE = ONCE|SESSION|ALWAYS|TOOL_WILDCARD)
 *
 * V1 backward compat:
 *   ALLOW|True  → ALLOW|ALWAYS
 *   DENY|False  → DENY
 */
function parseResponse(raw) {
  const trimmed = (raw || '').trim();
  const lines = trimmed.split(/\r?\n/);
  // Take the last non-empty line (PowerShell may emit warnings before)
  let responseLine = '';
  for (let i = lines.length - 1; i >= 0; i--) {
    if (lines[i].trim()) {
      responseLine = lines[i].trim();
      break;
    }
  }

  const result = {
    decision: 'DENY',
    scope: 'ONCE',
    burst: false,
    reason: '',
  };

  if (!responseLine) return result;

  // Check for BURST prefix (may appear as additional line or combined)
  const allLines = lines.map(l => l.trim()).filter(Boolean);
  for (const line of allLines) {
    if (line.startsWith('BURST|')) {
      result.burst = true;
      const burstScope = line.split('|')[1] || '';
      if (burstScope) result.scope = burstScope.toUpperCase();
    }
  }

  const parts = responseLine.split('|');
  const decision = (parts[0] || '').toUpperCase();
  const scopeOrReason = parts[1] || '';

  if (decision === 'ALLOW') {
    result.decision = 'ALLOW';

    // V1 backward compat
    if (scopeOrReason.toLowerCase() === 'true') {
      result.scope = 'ALWAYS';
    } else if (scopeOrReason) {
      result.scope = scopeOrReason.toUpperCase();
    } else {
      result.scope = 'ONCE';
    }

    // Check for BURST flag in parts[2] (PS1 outputs: ALLOW|SCOPE|BURST)
    if ((parts[2] || '').toUpperCase() === 'BURST') {
      result.burst = true;
    }
  } else if (decision === 'DENY') {
    result.decision = 'DENY';
    // V1 backward compat
    if (scopeOrReason.toLowerCase() === 'false') {
      result.reason = 'User denied via GUI popup';
    } else {
      result.reason = scopeOrReason || 'User denied via GUI popup';
    }
  } else if (decision === 'BURST') {
    // BURST as the primary response line
    result.decision = 'ALLOW';
    result.burst = true;
    result.scope = scopeOrReason ? scopeOrReason.toUpperCase() : 'ONCE';
  }

  return result;
}

// ---------------------------------------------------------------------------
// Apply approval based on parsed scope
// ---------------------------------------------------------------------------

function applyApproval(scope, toolName, toolInput, approvals, config) {
  const pattern = generatePattern(toolName, toolInput);

  switch (scope) {
    case 'ONCE':
      // No persistence — one-time allow
      break;

    case 'SESSION':
      saveSessionApproval(toolName, pattern);
      break;

    case 'ALWAYS':
      approvals.rules.push({
        tool: toolName,
        pattern,
        scope: 'always',
        addedAt: new Date().toISOString(),
      });
      saveApprovals(approvals);
      break;

    case 'TOOL_WILDCARD':
      approvals.rules.push({
        tool: toolName,
        pattern: '*',
        scope: 'tool_wildcard',
        addedAt: new Date().toISOString(),
      });
      saveApprovals(approvals);
      break;

    default:
      // Unknown scope — treat as ONCE
      break;
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  // Best-effort cleanup of stale temp files
  cleanStaleFiles();

  // Read stdin
  const chunks = [];
  for await (const chunk of process.stdin) {
    chunks.push(chunk);
  }
  const raw = Buffer.isBuffer(chunks[0])
    ? Buffer.concat(chunks).toString('utf-8')
    : chunks.join('');

  let data;
  try {
    data = JSON.parse(raw);
  } catch {
    // Unparseable input → skip hook (don't block)
    process.exit(0);
  }

  const toolName  = data.tool_name  || data.toolName  || '';
  const toolInput = data.tool_input || data.toolInput || {};

  // Load approvals (V1 auto-migrates to V2)
  const approvals = loadApprovals();
  const config = approvals.config || { ...DEFAULT_CONFIG };

  // -----------------------------------------------------------------------
  // CHECK 1: TIER 0 auto-approve
  // -----------------------------------------------------------------------
  const tier = classifyRiskTier(toolName, toolInput);

  if (tier === 0 && config.autoApproveTier0) {
    emitAllow();
    return;
  }

  // -----------------------------------------------------------------------
  // CHECK 2: gui-approvals.json rule matching (V2 with scope)
  // -----------------------------------------------------------------------
  if (matchesRule(approvals.rules, toolName, toolInput)) {
    emitAllow();
    return;
  }

  // -----------------------------------------------------------------------
  // CHECK 3: Session approval file matching
  // -----------------------------------------------------------------------
  const session = loadSessionApprovals();
  if (matchesRule(session.rules, toolName, toolInput)) {
    emitAllow();
    return;
  }

  // -----------------------------------------------------------------------
  // CHECK 4: Burst file matching (5s TTL)
  // -----------------------------------------------------------------------
  if (isBurstActive(toolName, config)) {
    emitAllow();
    return;
  }

  // -----------------------------------------------------------------------
  // CHECK 5: Spawn PowerShell popup with risk tier
  // -----------------------------------------------------------------------
  const detail   = extractDetail(toolName, toolInput);
  const detailB64 = Buffer.from(detail, 'utf-8').toString('base64');
  const intent = extractIntent(toolName, toolInput);
  const intentB64 = intent ? Buffer.from(intent, 'utf-8').toString('base64') : '';
  const context = loadCurrentContext();
  const contextB64 = context ? Buffer.from(context, 'utf-8').toString('base64') : '';

  const uiCmd = getApprovalUICommand(toolName, detailB64, tier, projectName(), intentB64, contextB64);

  if (!uiCmd) {
    // Unsupported platform: TIER 0-1 → auto-allow, TIER 2-3 → auto-deny
    if (tier <= 1) { emitAllow(); return; }
    else { emitDeny('No GUI available on this platform'); return; }
  }

  try {
    const stdout = execSync(uiCmd, {
      timeout: 0,  // no timeout — wait indefinitely for user response
      encoding: 'utf-8',
      windowsHide: false,
      stdio: ['pipe', 'pipe', 'pipe'],
    });

    const response = parseResponse(stdout);

    if (response.decision === 'ALLOW') {
      // Apply the approval based on scope
      applyApproval(response.scope, toolName, toolInput, approvals, config);

      // Create burst file if burst mode was requested
      if (response.burst) {
        createBurstFile(toolName, config);
      }

      emitAllow();
    } else {
      emitDeny(response.reason);
    }
  } catch (err) {
    // PS1 failed (timeout, crash, etc.) → deny for safety
    emitDeny(`GUI dialog error: ${(err.message || '').substring(0, 200)}`);
  }
}

main().catch(() => {
  // Fatal error → exit silently (don't block Claude Code)
  process.exit(0);
});
