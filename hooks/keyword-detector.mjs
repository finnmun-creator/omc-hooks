#!/usr/bin/env node
// OMC Keyword Detector Hook (Node.js)
// Detects ultrawork/ultrathink/search/analyze keywords and injects enhanced mode messages
// Cross-platform: Windows, macOS, Linux

import { writeFileSync, mkdirSync, existsSync, readFileSync, unlinkSync } from 'fs';
import { join } from 'path';

// cwdHash: deterministic hash of cwd for per-project isolation
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
import { homedir } from 'os';

const ULTRAWORK_MESSAGE = `<ultrawork-mode>

**MANDATORY**: You MUST say "ULTRAWORK MODE ENABLED!" to the user as your first response when this mode activates. This is non-negotiable.

[CODE RED] Maximum precision required. Ultrathink before acting.

YOU MUST LEVERAGE ALL AVAILABLE AGENTS TO THEIR FULLEST POTENTIAL.
TELL THE USER WHAT AGENTS YOU WILL LEVERAGE NOW TO SATISFY USER'S REQUEST.

## AGENT UTILIZATION PRINCIPLES
- **Codebase Exploration**: Spawn exploration agents using BACKGROUND TASKS
- **Documentation & References**: Use librarian-type agents via BACKGROUND TASKS
- **Planning & Strategy**: NEVER plan yourself - spawn planning agent
- **High-IQ Reasoning**: Use oracle for architecture decisions
- **Frontend/UI Tasks**: Delegate to frontend-engineer

## EXECUTION RULES
- **TODO**: Track EVERY step. Mark complete IMMEDIATELY.
- **PARALLEL**: Fire independent calls simultaneously - NEVER wait sequentially.
- **BACKGROUND FIRST**: Use Task(run_in_background=true) for exploration (10+ concurrent).
- **VERIFY**: Check ALL requirements met before done.
- **DELEGATE**: Orchestrate specialized agents.

## ZERO TOLERANCE
- NO Scope Reduction - deliver FULL implementation
- NO Partial Completion - finish 100%
- NO Premature Stopping - ALL TODOs must be complete
- NO TEST DELETION - fix code, not tests

THE USER ASKED FOR X. DELIVER EXACTLY X.

</ultrawork-mode>

---
`;

const ULTRATHINK_MESSAGE = `<think-mode>

**ULTRATHINK MODE ENABLED** - Extended reasoning activated.

You are now in deep thinking mode. Take your time to:
1. Thoroughly analyze the problem from multiple angles
2. Consider edge cases and potential issues
3. Think through the implications of each approach
4. Reason step-by-step before acting

Use your extended thinking capabilities to provide the most thorough and well-reasoned response.

</think-mode>

---
`;

const SEARCH_MESSAGE = `<search-mode>
MAXIMIZE SEARCH EFFORT. Launch multiple background agents IN PARALLEL:
- explore agents (codebase patterns, file structures)
- librarian agents (remote repos, official docs, GitHub examples)
Plus direct tools: Grep, Glob
NEVER stop at first result - be exhaustive.
</search-mode>

---
`;

const ANALYZE_MESSAGE = `<analyze-mode>
ANALYSIS MODE. Gather context before diving deep:

CONTEXT GATHERING (parallel):
- 1-2 explore agents (codebase patterns, implementations)
- 1-2 librarian agents (if external library involved)
- Direct tools: Grep, Glob, LSP for targeted searches

IF COMPLEX (architecture, multi-system, debugging after 2+ failures):
- Consult oracle agent for strategic guidance

SYNTHESIZE findings before proceeding.
</analyze-mode>

---
`;

// Read all stdin
async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) {
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString('utf-8');
}

// Extract prompt from various JSON structures
function extractPrompt(input) {
  try {
    const data = JSON.parse(input);
    if (data.prompt) return data.prompt;
    if (data.message?.content) return data.message.content;
    if (Array.isArray(data.parts)) {
      return data.parts
        .filter(p => p.type === 'text')
        .map(p => p.text)
        .join(' ');
    }
    return '';
  } catch {
    // Fallback: try to extract with regex
    const match = input.match(/"(?:prompt|content|text)"\s*:\s*"([^"]+)"/);
    return match ? match[1] : '';
  }
}

// Remove code blocks to prevent false positives
function removeCodeBlocks(text) {
  return text
    .replace(/```[\s\S]*?```/g, '')
    .replace(/`[^`]+`/g, '');
}

// Create ultrawork state file
function activateUltraworkState(directory, prompt) {
  const state = {
    active: true,
    started_at: new Date().toISOString(),
    original_prompt: prompt,
    reinforcement_count: 0,
    last_checked_at: new Date().toISOString()
  };
  const localDir = join(directory, '.omc');
  if (!existsSync(localDir)) { try { mkdirSync(localDir, { recursive: true }); } catch {} }
  try { writeFileSync(join(localDir, 'ultrawork-state.json'), JSON.stringify(state, null, 2)); } catch {}
  const globalDir = join(homedir(), '.claude');
  if (!existsSync(globalDir)) { try { mkdirSync(globalDir, { recursive: true }); } catch {} }
  try { writeFileSync(join(globalDir, 'ultrawork-state.json'), JSON.stringify(state, null, 2)); } catch {}
}

// Main
async function main() {
  try {
    const input = await readStdin();
    if (!input.trim()) {
      return;
    }

    let data = {};
    try { data = JSON.parse(input); } catch {}
    const directory = data.directory || process.cwd();

    const prompt = extractPrompt(input);
    if (!prompt) {
      return;
    }

    const cleanPrompt = removeCodeBlocks(prompt).toLowerCase();

    // ── Priority Interrupt: "^^" prefix detection ──
    const trimmedPrompt = prompt.trim();
    if (trimmedPrompt.startsWith('^^')) {
      const afterBang = trimmedPrompt.slice(2).trim();
      const omcDir = join(directory, '.omc');
      const interruptFile = join(omcDir, 'priority-interrupt.json');

      // "^^끝" or "^^done" → discard suspended work, clean state
      if (/^(끝|done)$/i.test(afterBang)) {
        // Read suspended info before deleting
        let discardedModes = '';
        try {
          if (existsSync(interruptFile)) {
            const existing = JSON.parse(readFileSync(interruptFile, 'utf-8'));
            const sc = existing.suspended_context || {};
            const modes = [];
            if (sc.had_ultrawork) modes.push('ultrawork');
            if (sc.had_ralph) modes.push('ralph');
            if (modes.length > 0) discardedModes = `\n폐기된 모드: ${modes.join(', ')}`;
          }
        } catch {}
        try { unlinkSync(interruptFile); } catch {}
        process.stdout.write(`<priority-interrupt-end>

[PRIORITY INTERRUPT 해제] 이전 작업 복귀를 취소했습니다. 깨끗한 상태입니다.${discardedModes}

</priority-interrupt-end>

---
`);
        return;
      }

      // "^^" with no command → ignore, treat as normal prompt
      if (!afterBang) {
        // fall through to normal keyword detection
      } else {
        // "^^ command" → suspend current modes and activate interrupt
        if (!existsSync(omcDir)) { try { mkdirSync(omcDir, { recursive: true }); } catch {} }

        // Snapshot current ultrawork/ralph states
        const uwPath = join(omcDir, 'ultrawork-state.json');
        const ralphPath = join(omcDir, 'ralph-state.json');
        let uwState = null;
        let ralphState = null;
        try { if (existsSync(uwPath)) uwState = JSON.parse(readFileSync(uwPath, 'utf-8')); } catch {}
        try { if (existsSync(ralphPath)) ralphState = JSON.parse(readFileSync(ralphPath, 'utf-8')); } catch {}

        // Deactivate ultrawork/ralph so Stop hook won't force continuation
        if (uwState?.active) {
          uwState.active = false;
          try { writeFileSync(uwPath, JSON.stringify(uwState, null, 2)); } catch {}
          // Also deactivate global copy
          const globalUw = join(homedir(), '.claude', 'ultrawork-state.json');
          try {
            if (existsSync(globalUw)) {
              const gState = JSON.parse(readFileSync(globalUw, 'utf-8'));
              gState.active = false;
              writeFileSync(globalUw, JSON.stringify(gState, null, 2));
            }
          } catch {}
        }
        if (ralphState?.active) {
          ralphState.active = false;
          try { writeFileSync(ralphPath, JSON.stringify(ralphState, null, 2)); } catch {}
        }

        // Check for existing interrupt — preserve original suspended context for nested interrupts
        let existingInterrupt = null;
        try { if (existsSync(interruptFile)) existingInterrupt = JSON.parse(readFileSync(interruptFile, 'utf-8')); } catch {}
        const isNested = existingInterrupt && (existingInterrupt.state === 'intercepting' || existingInterrupt.state === 'active');

        // Create priority-interrupt state file
        const interruptState = {
          state: 'intercepting',
          priority_command: afterBang,
          suspended_context: isNested ? existingInterrupt.suspended_context : {
            had_ultrawork: !!(uwState?.active),
            ultrawork_state: uwState,
            had_ralph: !!(ralphState?.active),
            ralph_state: ralphState,
          },
          intercept_count: 0,
          max_intercepts: 3,
          created_at: new Date().toISOString(),
          updated_at: new Date().toISOString(),
        };
        try { writeFileSync(interruptFile, JSON.stringify(interruptState, null, 2)); } catch {}

        process.stdout.write(`<priority-interrupt>

[PRIORITY INTERRUPT] 현재 작업을 일시 중단합니다.
우선 명령 실행: "${afterBang}"

이전 모드 상태:${uwState ? ' ultrawork(중단됨)' : ''}${ralphState ? ' ralph(중단됨)' : ''}${!uwState && !ralphState ? ' 없음' : ''}

우선 명령 완료 후 이전 작업이 자동 복귀됩니다.
"^^끝" 입력 시 이전 작업을 폐기합니다.

</priority-interrupt>

---
`);
        return;
      }
    }

    // Check for ultrawork keywords (highest priority)
    if (/\b(ultrawork|ulw|uw)\b/.test(cleanPrompt)) {
      activateUltraworkState(directory, prompt);
      process.stdout.write(ULTRAWORK_MESSAGE);
      return;
    }

    // Check for ultrathink/think keywords
    if (/\b(ultrathink|think)\b/.test(cleanPrompt)) {
      process.stdout.write(ULTRATHINK_MESSAGE);
      return;
    }

    // Check for search keywords (compound conditions to reduce false positives)
    if (/\b(search|locate|lookup|grep|scan|pinpoint|hunt)\b|find\s+(in\s+codebase|all\s+\w+|where\s+\w+|every\s+\w+|files?\s|usages?\s)|where\s+(is|does|are|did)|show\s+me\s+(all|where|the)|list\s+all/.test(cleanPrompt)) {
      process.stdout.write(SEARCH_MESSAGE);
      return;
    }

    // Check for analyze keywords (compound conditions to reduce false positives)
    if (/\b(analyze|analyse|investigate|deep.?dive|inspect|audit|diagnose|scrutinize|dissect|debug)\b|examine\s+(the|this|why|how)|research\s+(the|this|about|into)|review\s+(code|pr|this\s+code|the\s+code|pull\s+request)|why\s+is|why\s+does|why\s+did/.test(cleanPrompt)) {
      process.stdout.write(ANALYZE_MESSAGE);
      return;
    }

    // Check for DA/PM keywords (내폰시세 business analysis)
    if (/(?<![a-zA-Z])(da\s*분석|pm\s*리뷰|시세\s*분석|매출|마진|비용\s*분석|퍼널|코호트|roi|수익성|채널\s*믹스|kpi|대시보드|내폰시세|손익|매입\s*분석|건당\s*마진|등급별|채널별|브랜드별)(?![a-zA-Z])/i.test(cleanPrompt)) {
      const DAPM_MESSAGE = `<da-pm-mode>
DA/PM VETERAN MODE ACTIVATED. 20년차 데이터 분석+PM 역량 활성화.
비즈니스 해석 → da-pm 에이전트, 통계 연산 → scientist 위임.
내폰시세 도메인 프로토콜 적용: cp949 인코딩, 등급 매핑 필수.
da-pm-suite 스킬 활성화.
</da-pm-mode>

---
`;
      process.stdout.write(DAPM_MESSAGE);
      return;
    }

    // Always save user context for permission popup (per-project isolation)
    try {
      const contextData = {
        userRequest: prompt.substring(0, 200),
        timestamp: new Date().toISOString(),
        projectName: projectName(),
        cwd: process.cwd(),
      };
      const tempDir = process.env.TEMP || process.env.TMP || '/tmp';
      const contextFile = join(tempDir, `claude-context-${cwdHash()}.json`);
      writeFileSync(contextFile, JSON.stringify(contextData), 'utf-8');
    } catch { /* non-fatal */ }

    // No keywords detected
  } catch (error) {
    // On any error, allow continuation
  }
}

main();
