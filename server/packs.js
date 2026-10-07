// Tool pack discovery: reads the pack config, syncs git packs into a local
// cache, and reads each pack's toolpack.json manifest.
//
// The config is toolpacks.json (committed: packs everyone gets) followed by
// toolpacks.local.json (gitignored: this user's own packs), same format:
//   {
//     "packs": [
//       { "path": "toolpacks/core" },                            // local folder (relative to the config file)
//       { "git": "https://github.com/org/repo.git", "ref": "main" }, // cloned into .toolpacks/
//       { "path": "../my_pack", "enabled": false }               // temporarily disabled
//     ]
//   }
//
// See docs/TOOLPACKS.md for the pack contract.

const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const { execFileSync } = require("node:child_process");

const REPO_ROOT = path.resolve(__dirname, "..");
const CONFIG_PATH = path.resolve(process.env.TOOLPACKS_CONFIG || path.join(REPO_ROOT, "toolpacks.json"));
const LOCAL_CONFIG_PATH = path.join(path.dirname(CONFIG_PATH), "toolpacks.local.json");
const CONFIG_PATHS = [CONFIG_PATH, LOCAL_CONFIG_PATH];
const CACHE_DIR = path.join(REPO_ROOT, ".toolpacks");
const MANIFEST_NAME = "toolpack.json";
const PACK_ID_PATTERN = /^[A-Za-z0-9_-]+$/;
const DEFAULT_TAB = "Core";
const MAX_TAB_LENGTH = 24;

// Reads one config file as { packs: [...] } (empty if the file doesn't exist).
function readConfigFile(file) {
  if (!fs.existsSync(file)) return { packs: [] };
  const config = JSON.parse(fs.readFileSync(file, "utf8"));
  if (!Array.isArray(config.packs)) throw new Error(`${file}: "packs" must be an array`);
  return config;
}

// The merged config. Each entry gets `baseDir`, the folder its relative `path` is resolved from.
function readConfig() {
  const entries = [];
  for (const file of CONFIG_PATHS) {
    for (const entry of readConfigFile(file).packs) {
      entries.push({ ...entry, baseDir: path.dirname(file) });
    }
  }
  return { packs: entries };
}

function gitCacheDir(url) {
  const base = url.replace(/\/+$/, "").split(/[/:]/).pop().replace(/\.git$/, "") || "pack";
  const hash = crypto.createHash("sha1").update(url).digest("hex").slice(0, 8);
  return path.join(CACHE_DIR, `${base.replace(/[^A-Za-z0-9_-]/g, "_")}-${hash}`);
}

function git(args) {
  return execFileSync("git", args, { stdio: ["ignore", "pipe", "pipe"], encoding: "utf8" });
}

// Clones the pack if it isn't cached yet; with update, also fetches the latest `ref`.
// Returns "cloned", "updated" or "cached".
function syncGitPack(entry, { update }) {
  const dir = gitCacheDir(entry.git);
  if (!fs.existsSync(path.join(dir, ".git"))) {
    fs.mkdirSync(CACHE_DIR, { recursive: true });
    fs.rmSync(dir, { recursive: true, force: true });
    const args = ["clone", "--depth", "1"];
    if (entry.ref) args.push("--branch", entry.ref);
    args.push(entry.git, dir);
    git(args);
    return "cloned";
  }
  if (update) {
    // The cache is managed by us; local edits there are discarded.
    git(["-C", dir, "fetch", "--depth", "1", "origin", entry.ref || "HEAD"]);
    git(["-C", dir, "reset", "--hard", "FETCH_HEAD"]);
    return "updated";
  }
  return "cached";
}

// Resolves config entries to pack directories, cloning (and with update,
// pulling) git packs as needed. Returns [{ dir, origin }].
function resolvePackDirs(config, { update = false, log = console.log } = {}) {
  const result = [];
  for (const entry of config.packs) {
    if (entry.enabled === false) continue;
    if (typeof entry.path === "string") {
      result.push({ dir: path.resolve(entry.baseDir || path.dirname(CONFIG_PATH), entry.path), origin: entry.path });
    } else if (typeof entry.git === "string") {
      const dir = gitCacheDir(entry.git);
      const origin = entry.ref ? `${entry.git}#${entry.ref}` : entry.git;
      try {
        const status = syncGitPack(entry, { update });
        if (status !== "cached") log(`Pack ${status}: ${origin}`);
      } catch (err) {
        const detail = (err.stderr || err.message || "").toString().trim();
        if (fs.existsSync(path.join(dir, ".git"))) {
          log(`Failed to update ${origin}, using cached copy: ${detail}`);
        } else {
          log(`Failed to clone ${origin}: ${detail}`);
          continue;
        }
      }
      result.push({ dir, origin });
    } else {
      log(`Ignoring toolpacks.json entry without "path" or "git": ${JSON.stringify(entry)}`);
    }
  }
  return result;
}

// Reads and validates a pack's toolpack.json. Throws with a readable message on problems.
function readPack({ dir, origin }) {
  const manifestPath = path.join(dir, MANIFEST_NAME);
  if (!fs.existsSync(manifestPath)) throw new Error(`${origin}: no ${MANIFEST_NAME} found in ${dir}`);
  let raw;
  try {
    raw = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  } catch (err) {
    throw new Error(`${origin}: invalid ${MANIFEST_NAME}: ${err.message}`);
  }
  if (typeof raw.id !== "string" || !PACK_ID_PATTERN.test(raw.id)) {
    throw new Error(`${origin}: "id" must be letters, digits, "_" or "-"`);
  }
  if (!Number.isInteger(raw.apiVersion)) {
    throw new Error(`${origin}: "apiVersion" must be an integer`);
  }
  const sourceDir = path.resolve(dir, raw.source || ".");
  if (sourceDir !== dir && !sourceDir.startsWith(dir + path.sep)) {
    throw new Error(`${origin}: "source" must be inside the pack`);
  }
  if (!fs.existsSync(sourceDir)) throw new Error(`${origin}: source folder ${sourceDir} not found`);
  if (raw.tab !== undefined && (typeof raw.tab !== "string" || !raw.tab.trim() || raw.tab.trim().length > MAX_TAB_LENGTH)) {
    throw new Error(`${origin}: "tab" must be a non-empty string of at most ${MAX_TAB_LENGTH} characters`);
  }

  return {
    dir,
    sourceDir,
    manifest: {
      id: raw.id,
      name: typeof raw.name === "string" ? raw.name : raw.id,
      version: typeof raw.version === "string" ? raw.version : "0.0.0",
      apiVersion: raw.apiVersion,
      description: typeof raw.description === "string" ? raw.description : "",
      tab: typeof raw.tab === "string" ? raw.tab.trim() : DEFAULT_TAB,
      origin,
    },
  };
}

// Reads every pack's manifest. Returns { loaded: [pack], problems: [string] }.
function loadPacks(packDirs) {
  const loaded = [];
  const problems = [];
  const seen = new Map();
  for (const packDir of packDirs) {
    try {
      const pack = readPack(packDir);
      const existing = seen.get(pack.manifest.id);
      if (existing) {
        problems.push(`Pack id "${pack.manifest.id}" from ${packDir.origin} is already used by ${existing}; skipping`);
        continue;
      }
      seen.set(pack.manifest.id, packDir.origin);
      loaded.push(pack);
    } catch (err) {
      problems.push(err.message);
    }
  }
  return { loaded, problems };
}

module.exports = {
  CONFIG_PATH,
  LOCAL_CONFIG_PATH,
  CONFIG_PATHS,
  readConfigFile,
  readConfig,
  resolvePackDirs,
  readPack,
  loadPacks,
};
