#!/usr/bin/env node
// OMC Session Start Hook (Node.js)
// Restores persistent mode states when session starts
// Cross-platform: Windows, macOS, Linux

import { existsSync, readFileSync, readdirSync, writeFileSync, unlinkSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';

async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) {
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString('utf-8');
}

function readJsonFile(path) {
  try {
    if (!existsSync(path)) return null;
    return JSON.parse(readFileSync(path, 'utf-8'));
  } catch {
    return null;
  }
}

function countIncompleteTodos(todosDir) {
  let count = 0;
  if (existsSync(todosDir)) {
    try {
      const files = readdirSync(todosDir).filter(f => f.endsWith('.json')).slice(0, 20);
      for (const file of files) {
        const todos = readJsonFile(join(todosDir, file));
        if (Array.isArray(todos)) {
          count += todos.filter(t => t.status !== 'completed' && t.status !== 'cancelled').length;
        }
      }
    } catch {}
  }
  return count;
}

async function main() {
  try {
    const input = await readStdin();
    let data = {};
    try { data = JSON.parse(input); } catch {}

    const directory = data.directory || process.cwd();
    const messages = [];

    // ── Priority Interrupt: cleanup stale state from abnormal termination ──
    const interruptFile = join(directory, '.omc', 'priority-interrupt.json');
    try {
      if (existsSync(interruptFile)) {
        const interrupt = JSON.parse(readFileSync(interruptFile, 'utf-8'));
        if (interrupt.state === 'intercepting' || interrupt.state === 'active') {
          // Abnormal termination during priority interrupt — restore modes
          const suspended = interrupt.suspended_context || {};
          if (suspended.had_ultrawork && suspended.ultrawork_state) {
            const restoredUw = { ...suspended.ultrawork_state, active: true };
            const uwPath = join(directory, '.omc', 'ultrawork-state.json');
            try { writeFileSync(uwPath, JSON.stringify(restoredUw, null, 2)); } catch {}
            const globalUw = join(homedir(), '.claude', 'ultrawork-state.json');
            try { writeFileSync(globalUw, JSON.stringify(restoredUw, null, 2)); } catch {}
          }
          if (suspended.had_ralph && suspended.ralph_state) {
            const restoredRalph = { ...suspended.ralph_state, active: true };
            const ralphPath = join(directory, '.omc', 'ralph-state.json');
            try { writeFileSync(ralphPath, JSON.stringify(restoredRalph, null, 2)); } catch {}
          }
          messages.push(`<session-restore>

[PRIORITY INTERRUPT 정리] 이전 세션에서 비정상 종료된 Priority Interrupt를 정리했습니다.
중단되었던 명령: "${interrupt.priority_command || '알 수 없음'}"
${suspended.had_ultrawork ? '복원됨: ultrawork 모드' : ''}${suspended.had_ralph ? '복원됨: ralph 모드' : ''}

</session-restore>

---
`);
        }
        // Delete stale interrupt file regardless of state
        try { unlinkSync(interruptFile); } catch {}
      }
    } catch {
      // Cleanup failed — non-fatal
    }

    // Check for ultrawork state
    const ultraworkState = readJsonFile(join(directory, '.omc', 'ultrawork-state.json'))
      || readJsonFile(join(homedir(), '.claude', 'ultrawork-state.json'));

    if (ultraworkState?.active) {
      messages.push(`<session-restore>

[ULTRAWORK MODE RESTORED]

You have an active ultrawork session from ${ultraworkState.started_at}.
Original task: ${ultraworkState.original_prompt}

Continue working in ultrawork mode until all tasks are complete.

</session-restore>

---
`);
    }

    // Check for incomplete todos
    const todosDir = join(homedir(), '.claude', 'todos');
    const incompleteCount = countIncompleteTodos(todosDir);

    if (incompleteCount > 0) {
      messages.push(`<session-restore>

[PENDING TASKS DETECTED]

You have ${incompleteCount} incomplete tasks from a previous session.
Please continue working on these tasks.

</session-restore>

---
`);
    }

    if (messages.length > 0) {
      console.log(JSON.stringify({ continue: true, message: messages.join('\n') }));
    } else {
      console.log(JSON.stringify({ continue: true }));
    }
  } catch (error) {
    console.log(JSON.stringify({ continue: true }));
  }
}

main();
