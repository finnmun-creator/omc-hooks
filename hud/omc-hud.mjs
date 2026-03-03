#!/usr/bin/env node
/**
 * OMC HUD - Statusline Script
 * Wrapper that imports from dev paths, plugin cache, or npm package
 */

import { existsSync, readdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

async function main() {
  const home = homedir();
  let pluginCacheVersion = null;
  let pluginCacheDir = null;
  
  // 1. Development paths (preferred for local development)
  const devPaths = [
    join(home, "Workspace/oh-my-claudecode/dist/hud/index.js"),
    join(home, "workspace/oh-my-claudecode/dist/hud/index.js"),
    join(home, "projects/oh-my-claudecode/dist/hud/index.js"),
  ];
  
  for (const devPath of devPaths) {
    if (existsSync(devPath)) {
      try {
        await import(pathToFileURL(devPath).href);
        return;
      } catch { /* continue */ }
    }
  }
  
  // 2. Plugin cache (for production installs)
  const pluginCacheBase = join(home, ".claude/plugins/cache/omc/oh-my-claudecode");
  if (existsSync(pluginCacheBase)) {
    try {
      const versions = readdirSync(pluginCacheBase);
      if (versions.length > 0) {
        const latestVersion = versions.sort((a, b) => a.localeCompare(b, undefined, { numeric: true })).reverse()[0];
        pluginCacheVersion = latestVersion;
        pluginCacheDir = join(pluginCacheBase, latestVersion);
        const pluginPath = join(pluginCacheDir, "dist/hud/index.js");
        if (existsSync(pluginPath)) {
          await import(pathToFileURL(pluginPath).href);
          return;
        }
      }
    } catch { /* continue */ }
  }
  
  // 3. Windows global npm path (explicit)
  const globalNpmPath = join(home, "AppData/Roaming/npm/node_modules/oh-my-claude-sisyphus/dist/hud/index.js");
  if (existsSync(globalNpmPath)) {
    try {
      await import(pathToFileURL(globalNpmPath).href);
      return;
    } catch { /* continue */ }
  }

  // 4. npm package (global or local install - bare import)
  try {
    await import("oh-my-claude-sisyphus/dist/hud/index.js");
    return;
  } catch { /* continue */ }
  
  // 4. Fallback: provide detailed error message with fix instructions
  if (pluginCacheDir && existsSync(pluginCacheDir)) {
    // Plugin exists but dist/ folder is missing - needs build
    const distDir = join(pluginCacheDir, "dist");
    if (!existsSync(distDir)) {
      console.log(`[OMC HUD] Plugin installed but not built. Run: cd "${pluginCacheDir}" && npm install && npm run build`);
    } else {
      console.log(`[OMC HUD] Plugin dist/ exists but HUD not found. Run: cd "${pluginCacheDir}" && npm run build`);
    }
  } else if (existsSync(pluginCacheBase)) {
    // Plugin cache directory exists but no versions
    console.log(`[OMC HUD] Plugin cache found but no versions installed. Run: /oh-my-claudecode:omc-setup`);
  } else {
    // No plugin installation found at all
    console.log("[OMC HUD] Plugin not installed. Run: /oh-my-claudecode:omc-setup");
  }
}

main();
