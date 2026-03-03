import { readFileSync, writeFileSync, existsSync, copyFileSync } from 'fs';
import { join } from 'path';

const KNOWN_HOOK_FILENAMES = [
  'permission-gui.mjs',
  'keyword-detector.mjs',
  'input-notify.mjs',
  'pre-tool-use.mjs',
  'post-tool-use.mjs',
  'session-start.mjs',
];

const KNOWN_HUD_FILENAME = 'omc-hud.mjs';

const HOOK_EVENTS = [
  'UserPromptSubmit',
  'SessionStart',
  'PreToolUse',
  'PostToolUse',
  'Stop',
];

function normalizePath(p) {
  return p.replace(/\\/g, '/');
}

function extractFilename(command) {
  if (!command) return null;
  const normalized = normalizePath(command);
  const parts = normalized.split('/');
  return parts[parts.length - 1] || null;
}

export function mergeSettings(settingsPath, templatePath, homeDir) {
  const normalizedHome = normalizePath(homeDir);

  // Read existing settings or start with empty object
  let existing = {};
  if (existsSync(settingsPath)) {
    try {
      const raw = readFileSync(settingsPath, 'utf-8');
      existing = JSON.parse(raw);
    } catch {
      existing = {};
    }
  }

  // Read template and replace {{HOME}} with actual homeDir (forward slashes)
  let templateRaw = readFileSync(templatePath, 'utf-8');
  templateRaw = templateRaw.replace(/\{\{HOME\}\}/g, normalizedHome);
  const template = JSON.parse(templateRaw);

  // Backup existing settings.json before modifying
  let backedUp = false;
  if (existsSync(settingsPath)) {
    copyFileSync(settingsPath, settingsPath + '.bak');
    backedUp = true;
  }

  // Ensure hooks object exists
  if (!existing.hooks) {
    existing.hooks = {};
  }

  let added = 0;
  let skipped = 0;

  // Merge each hook event
  for (const event of HOOK_EVENTS) {
    const templateEntries = (template.hooks && template.hooks[event]) || [];
    if (templateEntries.length === 0) continue;

    if (!existing.hooks[event]) {
      // Event key doesn't exist — add it from template
      existing.hooks[event] = JSON.parse(JSON.stringify(templateEntries));
      added += countCommands(templateEntries);
    } else {
      // Event exists — check each template hook entry
      for (const templateEntry of templateEntries) {
        const templateCommands = getCommands(templateEntry);
        for (const cmd of templateCommands) {
          const filename = extractFilename(cmd);
          if (filename && isAlreadyRegistered(existing.hooks[event], filename)) {
            skipped++;
          } else {
            // Append the entire hook group entry (or add command to existing entry)
            appendHookEntry(existing.hooks[event], templateEntry);
            added++;
          }
        }
      }
    }
  }

  // Merge statusLine
  if (template.statusLine) {
    if (!existing.statusLine) {
      existing.statusLine = template.statusLine;
      added++;
    }
    // If present, preserve existing — do nothing
  }

  // Write merged settings.json
  writeFileSync(settingsPath, JSON.stringify(existing, null, 2), 'utf-8');

  return { added, skipped, backedUp };
}

export function unmergeSettings(settingsPath) {
  if (!existsSync(settingsPath)) return;

  let settings = {};
  try {
    const raw = readFileSync(settingsPath, 'utf-8');
    settings = JSON.parse(raw);
  } catch {
    return;
  }

  if (settings.hooks) {
    for (const event of Object.keys(settings.hooks)) {
      if (!Array.isArray(settings.hooks[event])) continue;

      settings.hooks[event] = settings.hooks[event]
        .map(entry => {
          if (!entry.hooks || !Array.isArray(entry.hooks)) return entry;
          const filtered = entry.hooks.filter(h => {
            if (!h.command) return true;
            const normalized = normalizePath(h.command);
            if (normalized.includes('omc-hooks')) return false;
            const filename = extractFilename(normalized);
            if (filename && KNOWN_HOOK_FILENAMES.includes(filename)) return false;
            return true;
          });
          if (filtered.length === 0) return null;
          return { ...entry, hooks: filtered };
        })
        .filter(entry => entry !== null);

      // Clean up empty arrays
      if (settings.hooks[event].length === 0) {
        delete settings.hooks[event];
      }
    }

    // Clean up empty hooks object
    if (Object.keys(settings.hooks).length === 0) {
      delete settings.hooks;
    }
  }

  // Remove statusLine if it references omc-hud.mjs (handle both string and object formats)
  if (settings.statusLine) {
    const command = typeof settings.statusLine === 'string'
      ? settings.statusLine
      : settings.statusLine.command;
    if (command) {
      const normalized = normalizePath(command);
      const filename = extractFilename(normalized);
      if (filename === KNOWN_HUD_FILENAME || normalized.includes('omc-hooks')) {
        delete settings.statusLine;
      }
    }
  }

  writeFileSync(settingsPath, JSON.stringify(settings, null, 2), 'utf-8');
}

// --- Helpers ---

function getCommands(entry) {
  if (!entry.hooks || !Array.isArray(entry.hooks)) return [];
  return entry.hooks.map(h => h.command).filter(Boolean);
}

function countCommands(entries) {
  return entries.reduce((sum, entry) => sum + getCommands(entry).length, 0);
}

function isAlreadyRegistered(eventEntries, filename) {
  for (const entry of eventEntries) {
    if (!entry.hooks || !Array.isArray(entry.hooks)) continue;
    for (const h of entry.hooks) {
      if (!h.command) continue;
      const existing = extractFilename(normalizePath(h.command));
      if (existing === filename) return true;
    }
  }
  return false;
}

function appendHookEntry(eventEntries, templateEntry) {
  // Append the template entry as a new group to the event array
  eventEntries.push(templateEntry);
}
