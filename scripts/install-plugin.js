#!/usr/bin/env node
// Copies the loader plugin into Roblox Studio's local Plugins folder.
// Override the destination with STUDIO_PLUGINS_DIR.

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

function defaultPluginsDir() {
  if (process.platform === "win32") {
    return path.join(process.env.LOCALAPPDATA || path.join(os.homedir(), "AppData", "Local"), "Roblox", "Plugins");
  }
  return path.join(os.homedir(), "Documents", "Roblox", "Plugins");
}

const pluginsDir = process.env.STUDIO_PLUGINS_DIR || defaultPluginsDir();
const source = path.join(__dirname, "..", "studio_plugin", "StudioToolsLoader.lua");
const dest = path.join(pluginsDir, "StudioToolsLoader.lua");

fs.mkdirSync(pluginsDir, { recursive: true });
fs.copyFileSync(source, dest);
console.log(`Installed ${path.basename(source)} -> ${dest}`);
console.log("Restart Studio (or toggle the plugin in Manage Plugins) to load it.");
