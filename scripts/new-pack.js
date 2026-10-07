#!/usr/bin/env node
// Creates a new tool pack from templates/toolpack and registers it in
// toolpacks.local.json (this user's own, gitignored pack list).
//
//   npm run new-pack -- <dir> [packId]
//
// <dir> must not exist yet (or be empty). packId defaults to the folder name.

const fs = require("node:fs");
const path = require("node:path");
const packs = require("../server/packs");
const sdk = require("../server/sdk");
const { REPO_ROOT } = require("../server/tree");

const TEMPLATE_DIR = path.join(REPO_ROOT, "templates", "toolpack");

function fail(message) {
  console.error(message);
  process.exit(1);
}

const [dirArg, idArg] = process.argv.slice(2);
if (!dirArg) fail("Usage: npm run new-pack -- <dir> [packId]");

const packDir = path.resolve(dirArg);
if (fs.existsSync(packDir) && fs.readdirSync(packDir).length > 0) fail(`${packDir} already exists and isn't empty`);

const packId = idArg || path.basename(packDir).replace(/[^A-Za-z0-9_-]/g, "_");
if (!/^[A-Za-z0-9_-]+$/.test(packId)) fail(`Invalid pack id "${packId}": use letters, digits, "_" or "-"`);

const packName = packId
  .split(/[_-]+/)
  .filter(Boolean)
  .map((word) => word[0].toUpperCase() + word.slice(1))
  .join(" ");

const replacements = {
  "{{PACK_ID}}": packId,
  "{{PACK_NAME}}": packName,
  "{{API_VERSION}}": String(sdk.apiVersion()),
};

function copyTemplate(src, dest) {
  fs.mkdirSync(dest, { recursive: true });
  for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
    const from = path.join(src, entry.name);
    const to = path.join(dest, entry.name);
    if (entry.isDirectory()) {
      copyTemplate(from, to);
    } else {
      let text = fs.readFileSync(from, "utf8");
      for (const [key, value] of Object.entries(replacements)) text = text.split(key).join(value);
      fs.writeFileSync(to, text);
    }
  }
}

copyTemplate(TEMPLATE_DIR, packDir);
const pack = packs.readPack({ dir: packDir, origin: dirArg });
sdk.write(pack.sourceDir);
console.log(`Created pack "${packId}" in ${packDir}`);

// Register it in the local (gitignored) config unless it's already listed somewhere.
const alreadyListed = packs
  .readConfig()
  .packs.some((entry) => typeof entry.path === "string" && path.resolve(entry.baseDir, entry.path) === packDir);
if (alreadyListed) {
  console.log("Already listed in the pack config");
} else {
  const localConfig = packs.readConfigFile(packs.LOCAL_CONFIG_PATH);
  const relative = path.relative(path.dirname(packs.LOCAL_CONFIG_PATH), packDir).split(path.sep).join("/");
  localConfig.packs.push({ path: relative });
  fs.writeFileSync(packs.LOCAL_CONFIG_PATH, JSON.stringify(localConfig, null, 2) + "\n");
  console.log(`Added { "path": "${relative}" } to ${packs.LOCAL_CONFIG_PATH}`);
}

const relativeToCwd = path.relative(process.cwd(), packDir);
const shownDir = relativeToCwd.startsWith("..") ? packDir : relativeToCwd || ".";
console.log(`
Next steps:
  cd "${shownDir}" && git init        # if this will be its own repo
  npm run check                       # from ${REPO_ROOT}
  Edit src/Tools/; a running server hot-reloads the pack into Studio.`);
