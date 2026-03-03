#!/usr/bin/env node
/**
 * Input Notify Hook for Claude Code
 * Classifies AskUserQuestion as simple/complex, then:
 *   - Simple: spawns OS-native dialog (PS1/sh) in popup mode (option buttons)
 *   - Complex: spawns OS-native dialog (PS1/sh) in complex mode (center popup with "VS Code로 이동")
 * Immediately returns "allow" with additionalContext — does NOT block execution.
 */

import { spawn } from 'child_process';
import { appendFileSync } from 'fs';
import { tmpdir, platform } from 'os';
import { join } from 'path';

const LOG_FILE = join(tmpdir(), 'claude-notify-debug.log');
function log(msg) {
  appendFileSync(LOG_FILE, `[${new Date().toISOString()}] ${msg}\n`, 'utf-8');
}

const HOME = process.env.USERPROFILE || process.env.HOME || '';

function getQuestionUI() {
  const uiDir = join(HOME, '.claude', 'hooks', 'ui');
  if (platform() === 'win32') {
    return { exe: 'powershell.exe', prefix: ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', join(uiDir, 'win', 'question-dialog.ps1')] };
  }
  if (platform() === 'darwin') {
    return { exe: 'bash', prefix: [join(uiDir, 'mac', 'question-dialog.sh')] };
  }
  return null; // Unsupported platform
}

/**
 * Classify whether the AskUserQuestion is simple (popup) or complex (complex popup).
 *
 * Simple:
 *   - Exactly 1 question
 *   - NOT multiSelect
 *   - 2-4 options
 *   - NO option has a `markdown` field
 *
 * Everything else is Complex.
 */
function classify(toolInput) {
  const questions = toolInput.questions || [];

  if (questions.length !== 1) return 'complex';

  const q = questions[0];
  if (q.multiSelect === true) return 'complex';

  const options = q.options || [];
  if (options.length < 2 || options.length > 4) return 'complex';

  for (const opt of options) {
    if (opt.markdown) return 'complex';
  }

  return 'simple';
}

function toBase64(str) {
  return Buffer.from(str, 'utf-8').toString('base64');
}

async function main() {
  log('=== Hook invoked ===');

  // --- Read stdin ---
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
    return;
  }

  const toolInput = data.tool_input || data.toolInput || {};
  const questions = toolInput.questions || [];

  // --- Extract question text for preview ---
  let questionText = '';
  try {
    if (questions.length > 0) {
      questionText = (questions[0].question || '').substring(0, 200);
    }
  } catch {
    questionText = '입력이 필요합니다';
  }
  if (!questionText) questionText = '입력이 필요합니다';

  // --- Classify ---
  const mode = classify(toolInput);
  log(`Classification: ${mode}`);

  // --- Get OS-specific UI ---
  const ui = getQuestionUI();
  if (!ui) {
    // Unsupported platform → skip popup, allow with context
    log('No GUI available on this platform — skipping popup');
    console.log(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: 'PreToolUse',
        permissionDecision: 'allow',
        additionalContext: '[질문 팝업 미지원 플랫폼] 터미널에서 응답하세요.',
      }
    }));
    return;
  }

  const spawnArgs = [...ui.prefix];

  if (mode === 'simple') {
    const q = questions[0];
    const options = q.options || [];
    const optionLabels = options.map(o => o.label || o.value || '');

    if (platform() === 'win32') {
      spawnArgs.push('-Mode', 'popup');
      spawnArgs.push('-QuestionBase64', toBase64(questionText));
      spawnArgs.push('-OptionsBase64', toBase64(JSON.stringify(optionLabels)));
    } else {
      spawnArgs.push('--mode', 'popup');
      spawnArgs.push('--question-base64', toBase64(questionText));
      spawnArgs.push('--options-base64', toBase64(JSON.stringify(optionLabels)));
    }

    log(`Popup mode: question="${questionText}", options=${JSON.stringify(optionLabels)}`);
  } else {
    // Complex: popup with "VS Code로 이동" button
    const q = questions[0] || {};
    let reason = '터미널에서 직접 확인하세요';
    if (questions.length > 1) reason = '여러 질문이 포함되어 있습니다';
    else if (q.multiSelect) reason = '복수 선택이 가능한 질문입니다';
    else if ((q.options || []).some(o => o.markdown)) reason = '코드 프리뷰가 포함된 질문입니다';

    if (platform() === 'win32') {
      spawnArgs.push('-Mode', 'complex');
      spawnArgs.push('-QuestionBase64', toBase64(questionText));
      spawnArgs.push('-ReasonText', reason);
    } else {
      spawnArgs.push('--mode', 'complex');
      spawnArgs.push('--question-base64', toBase64(questionText));
      spawnArgs.push('--reason-text', reason);
    }

    log(`Complex popup mode: question="${questionText}", reason="${reason}"`);
  }

  // --- Spawn fire-and-forget ---
  const child = spawn(ui.exe, spawnArgs, {
    stdio: 'ignore',
    detached: true,
  });
  child.unref();
  log(`${ui.exe} spawned, pid: ${child.pid}`);

  // --- Output hook response ---
  const additionalContext = mode === 'simple'
    ? '[질문 팝업 표시됨] 팝업 또는 터미널에서 응답하세요.'
    : '[질문 팝업 표시됨] 팝업에서 VS Code로 이동하거나 터미널에서 응답하세요.';

  console.log(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'allow',
      additionalContext,
    }
  }));

  log(`Returned allow with context: ${additionalContext}`);
}

main().catch(() => {
  process.exit(0);
});
