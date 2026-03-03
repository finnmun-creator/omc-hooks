#!/usr/bin/env node
/**
 * OMC Pre-Tool-Use Hook (Node.js)
 * Enforces delegation by warning when orchestrator attempts direct source file edits
 */

import * as path from 'path';
import { existsSync, readFileSync, writeFileSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';

// Allowed path patterns (no warning)
const ALLOWED_PATH_PATTERNS = [
  /\.omc[\/\\]/,
  /\.claude[\/\\]/,
  /[\/\\]\.claude[\/\\]/,
  /CLAUDE\.md$/,
  /AGENTS\.md$/,
];

// Source file extensions (should warn)
const SOURCE_EXTENSIONS = new Set([
  '.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs',
  '.py', '.pyw',
  '.go', '.rs', '.java', '.kt', '.scala',
  '.c', '.cpp', '.cc', '.h', '.hpp',
  '.rb', '.php',
  '.svelte', '.vue',
  '.graphql', '.gql',
  '.sh', '.bash', '.zsh',
]);

function isAllowedPath(filePath) {
  if (!filePath) return true;
  return ALLOWED_PATH_PATTERNS.some(pattern => pattern.test(filePath));
}

function isSourceFile(filePath) {
  if (!filePath) return false;
  const ext = path.extname(filePath).toLowerCase();
  return SOURCE_EXTENSIONS.has(ext);
}

// Patterns that indicate file modification in bash commands
const FILE_MODIFY_PATTERNS = [
  /sed\s+-i/,
  />\s*[^&]/,
  />>/,
  /tee\s+/,
  /cat\s+.*>\s*/,
  /echo\s+.*>\s*/,
  /printf\s+.*>\s*/,
];

// Source file pattern for command inspection
const SOURCE_EXT_PATTERN = /\.(ts|tsx|js|jsx|mjs|cjs|py|pyw|go|rs|java|kt|scala|c|cpp|cc|h|hpp|rb|php|svelte|vue|graphql|gql|sh|bash|zsh)/i;

function checkBashCommand(command) {
  // Check if command might modify files
  const mayModify = FILE_MODIFY_PATTERNS.some(pattern => pattern.test(command));
  if (!mayModify) return null;

  // Check if it might affect source files
  if (SOURCE_EXT_PATTERN.test(command)) {
    return `[DELEGATION NOTICE] Bash command may modify source files: ${command}

Recommended: Delegate to executor agent instead:
  Task(subagent_type="oh-my-claudecode:executor", model="sonnet", prompt="...")

This is a soft warning. Operation will proceed.`;
  }
  return null;
}

async function main() {
  const chunks = [];
  for await (const chunk of process.stdin) {
    chunks.push(chunk);
  }
  const input = Buffer.isBuffer(chunks[0])
    ? Buffer.concat(chunks).toString('utf-8')
    : chunks.join('');

  let data;
  try {
    data = JSON.parse(input);
  } catch {
    return;
  }

  // ── Priority Interrupt: check flag and optionally block tool calls ──
  try {
    const directory = data.directory || process.cwd();
    const interruptFile = join(directory, '.omc', 'priority-interrupt.json');
    if (existsSync(interruptFile)) {
      const interrupt = JSON.parse(readFileSync(interruptFile, 'utf-8'));
      if (interrupt.state === 'intercepting') {
        interrupt.intercept_count = (interrupt.intercept_count || 0) + 1;
        interrupt.updated_at = new Date().toISOString();

        if (interrupt.intercept_count >= (interrupt.max_intercepts || 3)) {
          // Safety valve exhausted: transition to active and allow through
          interrupt.state = 'active';
          writeFileSync(interruptFile, JSON.stringify(interrupt, null, 2));
          console.log(JSON.stringify({
            hookSpecificOutput: {
              hookEventName: "PreToolUse",
              permissionDecision: "allow",
              additionalContext: `[PRIORITY INTERRUPT 경고] 차단 횟수 초과 (${interrupt.intercept_count}/${interrupt.max_intercepts || 3}). 도구 호출을 허용합니다.`
            }
          }));
        } else {
          // Still within blocking budget: keep intercepting
          writeFileSync(interruptFile, JSON.stringify(interrupt, null, 2));
          console.log(JSON.stringify({
            hookSpecificOutput: {
              hookEventName: "PreToolUse",
              permissionDecision: "block",
              additionalContext: `[PRIORITY INTERRUPT ACTIVE] 현재 도구 호출이 차단되었습니다 (${interrupt.intercept_count}/${interrupt.max_intercepts || 3}).
우선 명령을 먼저 실행하세요: "${interrupt.priority_command}"
이전 작업의 도구 호출은 우선 명령 완료 후 재개됩니다.`
            }
          }));
          return;
        }
      }
      // state === "active" or "completed" → allow through (priority command is running)
    }
  } catch {
    // Interrupt check failed — continue normally
  }

  // Extract tool name (handle both cases)
  const toolName = data.tool_name || data.toolName || '';

  // Handle Bash tool separately - check for file modification patterns
  if (toolName === 'Bash' || toolName === 'bash') {
    const toolInput = data.tool_input || data.toolInput || {};
    const command = toolInput.command || '';
    const warning = checkBashCommand(command);
    if (warning) {
      console.log(JSON.stringify({ hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "allow", additionalContext: warning } }));
    }
    return;
  }

  // Only check Edit and Write tools
  if (!['Edit', 'Write', 'edit', 'write'].includes(toolName)) {
    return;
  }

  // Extract file path (handle nested structures)
  const toolInput = data.tool_input || data.toolInput || {};
  const filePath = toolInput.file_path || toolInput.filePath || '';

  // No file path? Allow
  if (!filePath) {
    return;
  }

  // Check if allowed path
  if (isAllowedPath(filePath)) {
    return;
  }

  // Check if source file
  if (isSourceFile(filePath)) {
    const warning = `[DELEGATION NOTICE] Direct ${toolName} on source file: ${filePath}

Recommended: Delegate to executor agent instead:
  Task(subagent_type="oh-my-claudecode:executor", model="sonnet", prompt="...")

This is a soft warning. Operation will proceed.`;

    console.log(JSON.stringify({ hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "allow", additionalContext: warning } }));
    return;
  }

  // Not a source file, allow without warning
}

main().catch(() => {});
