#!/usr/bin/env node
// Builds the loader plugin and installs it into Roblox Studio's local Plugins
// folder as StudioToolsLoader.rbxmx: the loader script, with the libraries
// from libraries.json in a Libraries folder under it. Libraries are
// downloaded into .libraries/ first if needed.
//
// Override the destination with STUDIO_PLUGINS_DIR. Restart Studio afterwards.

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const libraries = require("../server/libraries");

const PLUGIN_NAME = "StudioToolsLoader";
const LOADER_PATH = path.join(__dirname, "..", "studio_plugin", `${PLUGIN_NAME}.lua`);

function defaultPluginsDir() {
  if (process.platform === "win32") {
    return path.join(process.env.LOCALAPPDATA || path.join(os.homedir(), "AppData", "Local"), "Roblox", "Plugins");
  }
  return path.join(os.homedir(), "Documents", "Roblox", "Plugins");
}

function escapeXml(text) {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// The library's root <Item> from its release asset, with referents made
// unique within the plugin file.
function libraryItemXml(lib, index) {
  const { xml, root } = libraries.readAsset(lib, lib.assetPath);
  if (/<SharedString\b/.test(xml)) throw new Error(`${lib.asset} uses SharedStrings, which aren't supported`);
  const prefix = `L${index}_`;
  return xml
    .slice(root.start, root.end)
    .replace(/(<Item\s[^>]*?referent=")([^"]*)"/g, `$1${prefix}$2"`)
    .replace(/(<Ref name="[^"]*">)(?!null<)([^<]+)<\/Ref>/g, `$1${prefix}$2</Ref>`);
}

async function main() {
  const libs = await libraries.syncLibraries();

  const parts = [
    '<roblox version="4">',
    '<Item class="Script" referent="LOADER">',
    "<Properties>",
    `<string name="Name">${PLUGIN_NAME}</string>`,
    `<ProtectedString name="Source">${escapeXml(fs.readFileSync(LOADER_PATH, "utf8"))}</ProtectedString>`,
    "</Properties>",
  ];
  if (libs.length > 0) {
    parts.push('<Item class="Folder" referent="LIBRARIES">', '<Properties><string name="Name">Libraries</string></Properties>');
    libs.forEach((lib, i) => parts.push(libraryItemXml(lib, i)));
    parts.push("</Item>");
  }
  parts.push("</Item>", "</roblox>", "");

  const pluginsDir = process.env.STUDIO_PLUGINS_DIR || defaultPluginsDir();
  const dest = path.join(pluginsDir, `${PLUGIN_NAME}.rbxmx`);
  fs.mkdirSync(pluginsDir, { recursive: true });
  fs.writeFileSync(dest, parts.join("\n"));
  console.log(`Installed ${PLUGIN_NAME} -> ${dest}`);
  for (const lib of libs) console.log(`  with library ${lib.name} ${lib.tag}`);

  // Earlier versions installed the bare script; two copies would both load.
  const oldScript = path.join(pluginsDir, `${PLUGIN_NAME}.lua`);
  if (fs.existsSync(oldScript)) {
    fs.rmSync(oldScript);
    console.log(`Removed the old ${path.basename(oldScript)}`);
  }
  console.log("Restart Studio (or toggle the plugin in Manage Plugins) to load it.");
}

main().catch((err) => {
  console.error(`install-plugin failed: ${err.message}`);
  process.exitCode = 1;
});
