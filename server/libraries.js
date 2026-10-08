// Luau libraries bundled into the installed plugin (e.g. geometry3luau).
//
// Libraries are pinned in libraries.json to a GitHub release asset: a .rbxmx
// model whose root is the library's ModuleScript. `npm run install-plugin`
// packs them into the plugin, and the loader mounts them at
// StudioTools/Libraries/<name> in every build, so they're loaded once per
// Studio session instead of being re-sent with every hot reload.
//
// The downloaded asset is cached in .libraries/<name>-<tag>/, together with
// its modules extracted as .luau files (src/), which `npm run check` and
// coding agents use. The release is the single source of both.
//
// Downloads use the public release URL. For private repos, set GITHUB_TOKEN
// in .env, or have the GitHub CLI (gh) logged in.

require("./env").loadEnv();
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { REPO_ROOT } = require("./tree");

const CONFIG_PATH = path.join(REPO_ROOT, "libraries.json");
const CACHE_DIR = path.join(REPO_ROOT, ".libraries");
const NAME_PATTERN = /^[A-Za-z_][A-Za-z0-9_]*$/;

// Returns [{ name, repo, tag, asset }] from libraries.json (empty if there's no file).
function readConfig() {
  if (!fs.existsSync(CONFIG_PATH)) return [];
  const config = JSON.parse(fs.readFileSync(CONFIG_PATH, "utf8"));
  const entries = Array.isArray(config.libraries) ? config.libraries : [];
  const seen = new Set();
  return entries.map((entry, i) => {
    const where = `libraries.json entry ${i + 1}`;
    for (const key of ["name", "repo", "tag", "asset"]) {
      if (typeof entry[key] !== "string" || entry[key] === "") throw new Error(`${where}: "${key}" must be a non-empty string`);
    }
    if (!NAME_PATTERN.test(entry.name)) throw new Error(`${where}: "name" must be a valid Luau identifier`);
    if (!/^[\w.-]+\/[\w.-]+$/.test(entry.repo)) throw new Error(`${where}: "repo" must look like "owner/name"`);
    if (seen.has(entry.name)) throw new Error(`${where}: duplicate library "${entry.name}"`);
    seen.add(entry.name);
    return { name: entry.name, repo: entry.repo, tag: entry.tag, asset: entry.asset };
  });
}

function cacheDir(lib) {
  return path.join(CACHE_DIR, `${lib.name}-${lib.tag.replace(/[^\w.-]/g, "_")}`);
}

// --- downloading ----------------------------------------------------------

async function fetchOk(url, headers) {
  const res = await fetch(url, { headers: { "User-Agent": "studio_tools_system", ...headers } });
  if (!res.ok) throw new Error(`GET ${url} -> ${res.status}`);
  return res;
}

async function downloadAsset(lib, dest) {
  const token = process.env.GITHUB_TOKEN;
  const attempts = [];

  if (token) {
    // Private repos: release assets are only reachable through the API.
    try {
      const auth = { Authorization: `Bearer ${token}`, "X-GitHub-Api-Version": "2022-11-28" };
      const release = await (await fetchOk(`https://api.github.com/repos/${lib.repo}/releases/tags/${lib.tag}`, auth)).json();
      const asset = (release.assets || []).find((a) => a.name === lib.asset);
      if (!asset) throw new Error(`release ${lib.tag} has no asset named ${lib.asset}`);
      const res = await fetchOk(asset.url, { ...auth, Accept: "application/octet-stream" });
      fs.writeFileSync(dest, Buffer.from(await res.arrayBuffer()));
      return;
    } catch (err) {
      attempts.push(`with GITHUB_TOKEN: ${err.message}`);
    }
  }

  try {
    const res = await fetchOk(`https://github.com/${lib.repo}/releases/download/${lib.tag}/${lib.asset}`);
    fs.writeFileSync(dest, Buffer.from(await res.arrayBuffer()));
    return;
  } catch (err) {
    attempts.push(err.message);
  }

  // Fall back to the GitHub CLI, which has its own login.
  const gh = spawnSync(
    "gh",
    ["release", "download", lib.tag, "-R", lib.repo, "-p", lib.asset, "-O", dest, "--clobber"],
    { encoding: "utf8" }
  );
  if (!gh.error && gh.status === 0 && fs.existsSync(dest)) return;
  attempts.push(gh.error ? "gh not available" : `gh: ${(gh.stderr || "").trim() || `exit ${gh.status}`}`);

  throw new Error(
    `Couldn't download ${lib.asset} from ${lib.repo} release ${lib.tag}:\n  ${attempts.join("\n  ")}\n` +
      "If the repo is private, set GITHUB_TOKEN in .env or log in with `gh auth login`."
  );
}

// --- .rbxmx parsing ----------------------------------------------------------

function decodeXml(text) {
  const cdata = text.match(/^\s*<!\[CDATA\[([\s\S]*)\]\]>\s*$/);
  if (cdata) return cdata[1];
  return text.replace(/&(#x[0-9a-fA-F]+|#\d+|lt|gt|amp|quot|apos);/g, (_, entity) => {
    if (entity[0] === "#") {
      return String.fromCodePoint(entity[1] === "x" ? parseInt(entity.slice(2), 16) : parseInt(entity.slice(1), 10));
    }
    return { lt: "<", gt: ">", amp: "&", quot: '"', apos: "'" }[entity];
  });
}

// Parses the <Item> tree of a Roblox XML model into
// [{ className, name, source, start, end, children }], where start/end are
// the item's offsets in `xml`. Only Name and Source are read.
function parseRbxmx(xml) {
  const tagPattern = /<Item\s[^>]*?class="([^"]*)"[^>]*>|<\/Item>|<Properties>/g;
  const roots = [];
  const stack = [];
  let match;
  while ((match = tagPattern.exec(xml))) {
    if (match[0] === "<Properties>") {
      const end = xml.indexOf("</Properties>", tagPattern.lastIndex);
      if (end === -1) throw new Error("unterminated <Properties>");
      const props = xml.slice(tagPattern.lastIndex, end);
      const item = stack[stack.length - 1];
      if (item) {
        const name = props.match(/<string name="Name">([\s\S]*?)<\/string>/);
        const source = props.match(/<ProtectedString name="Source">([\s\S]*?)<\/ProtectedString>/);
        if (name) item.name = decodeXml(name[1]);
        if (source) item.source = decodeXml(source[1]);
      }
      tagPattern.lastIndex = end + "</Properties>".length;
    } else if (match[0] === "</Item>") {
      const item = stack.pop();
      if (!item) throw new Error("unbalanced </Item>");
      item.end = tagPattern.lastIndex;
    } else {
      const item = { className: match[1], name: "", source: null, start: match.index, end: -1, children: [] };
      (stack.length > 0 ? stack[stack.length - 1].children : roots).push(item);
      stack.push(item);
    }
  }
  if (stack.length > 0) throw new Error("unterminated <Item>");
  return roots;
}

// Writes an item tree as Rojo-style files: a ModuleScript with module
// children becomes a folder with init.luau. Non-script items are skipped.
function writeItem(item, dir, isRoot) {
  const scriptChildren = item.children.filter((c) => c.className === "ModuleScript" || c.className === "Folder");
  if (item.className === "ModuleScript" && scriptChildren.length === 0 && !isRoot) {
    fs.writeFileSync(path.join(dir, `${item.name}.luau`), item.source || "");
    return;
  }
  if (item.className !== "ModuleScript" && item.className !== "Folder") return;
  const itemDir = isRoot ? dir : path.join(dir, item.name);
  fs.mkdirSync(itemDir, { recursive: true });
  if (item.className === "ModuleScript") fs.writeFileSync(path.join(itemDir, "init.luau"), item.source || "");
  for (const child of scriptChildren) writeItem(child, itemDir, false);
}

// Reads a cached asset and checks it holds one ModuleScript named lib.name.
function readAsset(lib, file) {
  const xml = fs.readFileSync(file, "utf8");
  const roots = parseRbxmx(xml);
  if (roots.length !== 1 || roots[0].className !== "ModuleScript") {
    throw new Error(`${lib.asset} must contain exactly one ModuleScript at its root`);
  }
  if (roots[0].name !== lib.name) {
    throw new Error(`${lib.asset}'s root module is named "${roots[0].name}", but libraries.json calls it "${lib.name}"`);
  }
  return { xml, root: roots[0] };
}

// --- sync ----------------------------------------------------------------

// Downloads and extracts any library missing from the cache. Returns
// [{ ...lib, dir, assetPath, sourceDir }].
async function syncLibraries({ log = console.log } = {}) {
  const result = [];
  for (const lib of readConfig()) {
    const dir = cacheDir(lib);
    const assetPath = path.join(dir, lib.asset);
    const sourceDir = path.join(dir, "src");
    if (!fs.existsSync(sourceDir)) {
      log(`Downloading library ${lib.name} ${lib.tag} (${lib.repo}) ...`);
      const tmp = `${dir}.tmp`;
      fs.rmSync(tmp, { recursive: true, force: true });
      fs.mkdirSync(tmp, { recursive: true });
      try {
        await downloadAsset(lib, path.join(tmp, lib.asset));
        const { root } = readAsset(lib, path.join(tmp, lib.asset));
        writeItem(root, path.join(tmp, "src"), true);
        fs.rmSync(dir, { recursive: true, force: true });
        fs.renameSync(tmp, dir);
      } catch (err) {
        fs.rmSync(tmp, { recursive: true, force: true });
        throw err;
      }
    }
    result.push({ ...lib, dir, assetPath, sourceDir });
  }
  return result;
}

module.exports = { CONFIG_PATH, CACHE_DIR, readConfig, syncLibraries, readAsset, parseRbxmx };
