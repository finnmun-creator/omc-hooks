#!/usr/bin/env node

import { existsSync, mkdirSync, copyFileSync, readdirSync, unlinkSync, rmdirSync, chmodSync, readFileSync } from 'fs';
import { join, dirname } from 'path';
import { homedir, platform } from 'os';
import { fileURLToPath } from 'url';
import { mergeSettings, unmergeSettings } from './lib/settings-merger.mjs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const VERSION = JSON.parse(readFileSync(join(__dirname, 'package.json'), 'utf-8')).version;

// ---------------------------------------------------------------------------
// Colors (simple ANSI)
// ---------------------------------------------------------------------------
const c = {
  reset: '\x1b[0m',
  green: '\x1b[32m',
  red: '\x1b[31m',
  yellow: '\x1b[33m',
  cyan: '\x1b[36m',
  dim: '\x1b[2m',
};

function ok(msg) { console.log(`${c.green}[OK]${c.reset} ${msg}`); }
function warn(msg) { console.log(`${c.yellow}[WARN]${c.reset} ${msg}`); }
function err(msg) { console.error(`${c.red}[ERROR]${c.reset} ${msg}`); }
function info(msg) { console.log(`${c.dim}[INFO]${c.reset} ${msg}`); }

// ---------------------------------------------------------------------------
// Path helpers
// ---------------------------------------------------------------------------
const HOME = homedir();
const IS_WIN = platform() === 'win32';

const CLAUDE_DIR = join(HOME, '.claude');
const HOOKS_DIR = join(CLAUDE_DIR, 'hooks');
const UI_DIR_WIN = join(HOOKS_DIR, 'ui', 'win');
const UI_DIR_MAC = join(HOOKS_DIR, 'ui', 'mac');
const HUD_DIR = join(CLAUDE_DIR, 'hud');

const SRC_HOOKS = join(__dirname, 'hooks');
const SRC_UI_WIN = join(__dirname, 'ui', 'win');
const SRC_UI_MAC = join(__dirname, 'ui', 'mac');
const SRC_HUD = join(__dirname, 'hud');
const SRC_DEFAULTS = join(__dirname, 'defaults');

// Known filenames (only these are removed during uninstall)
const KNOWN_HOOKS = [
  'permission-gui.mjs',
  'keyword-detector.mjs',
  'input-notify.mjs',
  'pre-tool-use.mjs',
  'post-tool-use.mjs',
  'session-start.mjs',
];
const KNOWN_UI_WIN = ['approval-dialog.ps1', 'question-dialog.ps1'];
const KNOWN_UI_MAC = ['approval-dialog.sh', 'question-dialog.sh'];
const KNOWN_HUD = ['omc-hud.mjs'];

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------
function showHelp() {
  console.log(`
${c.cyan}omc-hooks${c.reset} — Enhanced hooks for Claude Code

${c.cyan}Usage:${c.reset}
  npx omc-hooks              Install hooks (default)
  npx omc-hooks install      Install hooks
  npx omc-hooks uninstall    Remove hooks
  npx omc-hooks --version    Show version
  npx omc-hooks --help       Show this help

${c.cyan}What it does:${c.reset}
  Copies hook scripts to ~/.claude/hooks/ and merges
  settings.json with hook registrations. Existing settings
  are preserved — omc-hooks entries are added without duplicates.
`);
}

function ensureDir(dir) {
  if (!existsSync(dir)) {
    mkdirSync(dir, { recursive: true });
  }
}

function copyDir(srcDir, destDir, pattern, chmod) {
  if (!existsSync(srcDir)) return 0;
  const files = readdirSync(srcDir).filter(f => f.endsWith(pattern));
  for (const f of files) {
    copyFileSync(join(srcDir, f), join(destDir, f));
    if (chmod !== undefined) {
      try { chmodSync(join(destDir, f), chmod); } catch {}
    }
  }
  return files.length;
}

function removeKnownFiles(dir, knownFiles) {
  if (!existsSync(dir)) return 0;
  let count = 0;
  for (const f of knownFiles) {
    const p = join(dir, f);
    if (existsSync(p)) {
      try { unlinkSync(p); count++; } catch {}
    }
  }
  return count;
}

function tryRmdir(dir) {
  try {
    if (existsSync(dir) && readdirSync(dir).length === 0) {
      rmdirSync(dir);
    }
  } catch {}
}

// ---------------------------------------------------------------------------
// Install
// ---------------------------------------------------------------------------
function install() {
  console.log('');
  console.log(`${c.cyan}============================================${c.reset}`);
  console.log(`${c.cyan}  omc-hooks installer v${VERSION}${c.reset}`);
  console.log(`${c.cyan}============================================${c.reset}`);
  console.log('');

  // Check Node.js version
  const major = parseInt(process.versions.node.split('.')[0], 10);
  if (major < 18) {
    err(`Node.js 18+ required (found ${process.versions.node})`);
    process.exit(1);
  }
  ok(`Node.js ${process.versions.node}`);

  // Create directories
  ensureDir(HOOKS_DIR);
  if (IS_WIN) ensureDir(UI_DIR_WIN);
  else ensureDir(UI_DIR_MAC);
  ensureDir(HUD_DIR);
  ok(`Target: ${HOOKS_DIR}`);

  // Copy hooks/*.mjs
  const hookCount = copyDir(SRC_HOOKS, HOOKS_DIR, '.mjs');
  ok(`Copied ${hookCount} hook files`);

  // Copy UI files (OS-specific)
  if (IS_WIN) {
    const uiCount = copyDir(SRC_UI_WIN, UI_DIR_WIN, '.ps1');
    ok(`Copied ${uiCount} Windows UI files`);
  } else {
    const uiCount = copyDir(SRC_UI_MAC, UI_DIR_MAC, '.sh', 0o755);
    ok(`Copied ${uiCount} macOS UI files (chmod +x)`);
  }

  // Copy HUD
  const hudSrc = join(SRC_HUD, 'omc-hud.mjs');
  if (existsSync(hudSrc)) {
    copyFileSync(hudSrc, join(HUD_DIR, 'omc-hud.mjs'));
    ok('Copied HUD file');
  }

  // gui-approvals.json (only if not exists)
  const approvalsTarget = join(CLAUDE_DIR, 'gui-approvals.json');
  const approvalsSrc = join(SRC_DEFAULTS, 'gui-approvals.json');
  if (existsSync(approvalsTarget)) {
    ok('gui-approvals.json preserved (existing)');
  } else if (existsSync(approvalsSrc)) {
    copyFileSync(approvalsSrc, approvalsTarget);
    ok('gui-approvals.json installed (new)');
  }

  // Merge settings.json
  const settingsPath = join(CLAUDE_DIR, 'settings.json');
  const templatePath = join(SRC_DEFAULTS, 'settings-hooks.json');

  try {
    const result = mergeSettings(settingsPath, templatePath, HOME);
    ok(`settings.json merged (added: ${result.added}, skipped: ${result.skipped})`);
    if (result.backedUp) {
      info('Backup saved: settings.json.bak');
    }
  } catch (e) {
    warn(`settings.json merge failed: ${e.message}`);
  }

  console.log('');
  console.log(`${c.cyan}Installation complete!${c.reset} Restart Claude Code to activate.`);
  console.log('');
}

// ---------------------------------------------------------------------------
// Uninstall
// ---------------------------------------------------------------------------
function uninstall() {
  console.log('');
  console.log(`${c.cyan}============================================${c.reset}`);
  console.log(`${c.cyan}  omc-hooks uninstaller v${VERSION}${c.reset}`);
  console.log(`${c.cyan}============================================${c.reset}`);
  console.log('');

  // Clean settings.json
  const settingsPath = join(CLAUDE_DIR, 'settings.json');
  try {
    unmergeSettings(settingsPath);
    ok('settings.json cleaned');
  } catch (e) {
    warn(`settings.json cleanup failed: ${e.message}`);
  }

  // Remove hook files (only known omc-hooks files)
  const hookCount = removeKnownFiles(HOOKS_DIR, KNOWN_HOOKS);
  ok(`Removed ${hookCount} hook files`);

  // Remove UI files (only known omc-hooks files)
  if (IS_WIN) {
    const uiCount = removeKnownFiles(UI_DIR_WIN, KNOWN_UI_WIN);
    ok(`Removed ${uiCount} Windows UI files`);
    tryRmdir(UI_DIR_WIN);
  } else {
    const uiCount = removeKnownFiles(UI_DIR_MAC, KNOWN_UI_MAC);
    ok(`Removed ${uiCount} macOS UI files`);
    tryRmdir(UI_DIR_MAC);
  }
  tryRmdir(join(HOOKS_DIR, 'ui'));

  // Remove HUD (only known omc-hooks files)
  const hudCount = removeKnownFiles(HUD_DIR, KNOWN_HUD);
  ok(`Removed ${hudCount} HUD file`);
  tryRmdir(HUD_DIR);

  // gui-approvals.json — preserve
  const approvalsPath = join(CLAUDE_DIR, 'gui-approvals.json');
  if (existsSync(approvalsPath)) {
    info('gui-approvals.json preserved (contains your approval rules)');
    info(`To remove: delete ${approvalsPath}`);
  }

  console.log('');
  console.log(`${c.cyan}Uninstall complete!${c.reset} Restart Claude Code to apply.`);
  console.log('');
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
const args = process.argv.slice(2);
const command = args[0] || 'install';

switch (command) {
  case 'install':
    install();
    break;
  case 'uninstall':
    uninstall();
    break;
  case '--version':
  case '-v':
    console.log(`omc-hooks v${VERSION}`);
    break;
  case '--help':
  case '-h':
    showHelp();
    break;
  default:
    err(`Unknown command: ${command}`);
    showHelp();
    process.exit(1);
}
