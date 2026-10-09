#!/usr/bin/env node
// Static checks for the framework, the loader plugin and every tool pack in
// toolpacks.json, without needing Studio:
//
//   * pack manifests and layout (toolpack.json, Tools/ folder, SDK.luau)
//   * libraries.json (libraries are downloaded into .libraries/ if missing)
//   * Luau syntax, type checking and lints via luau-lsp, against Roblox's
//     plugin-security API definitions and the same instance tree the loader
//     builds in Studio
//
// Exits with status 1 if there are errors. Warnings don't fail the check.
// luau-lsp is downloaded into .tools/ on first run.
//
//   npm run check

const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const { execFileSync, spawnSync } = require("node:child_process");

const packs = require("../server/packs");
const sdk = require("../server/sdk");
const libraries = require("../server/libraries");
const { REPO_ROOT, ROOT_NAME, collectFiles, treeFiles, buildSourcemap } = require("../server/tree");

const LUAU_LSP_VERSION = "1.69.0";
const TOOLS_DIR = path.join(REPO_ROOT, ".tools");
const LSP_DIR = path.join(TOOLS_DIR, `luau-lsp-${LUAU_LSP_VERSION}`);
const LOADER_PATH = path.join(REPO_ROOT, "studio_plugin", "StudioToolsLoader.lua");

const errors = [];
const warnings = [];

function display(file) {
  const rel = path.relative(process.cwd(), file);
  return rel.startsWith("..") ? file : rel;
}

// --- luau-lsp ------------------------------------------------------------

function releaseAsset() {
  if (process.platform === "darwin") return "luau-lsp-macos.zip";
  if (process.platform === "win32") return "luau-lsp-win64.zip";
  if (process.platform === "linux") return os.arch() === "arm64" ? "luau-lsp-linux-arm64.zip" : "luau-lsp-linux-x86_64.zip";
  throw new Error(`No luau-lsp build for ${process.platform}`);
}

async function download(url, dest) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`GET ${url} -> ${res.status}`);
  fs.writeFileSync(dest, Buffer.from(await res.arrayBuffer()));
}

async function ensureLuauLsp() {
  const exe = path.join(LSP_DIR, process.platform === "win32" ? "luau-lsp.exe" : "luau-lsp");
  const defs = path.join(LSP_DIR, "globalTypes.PluginSecurity.d.luau");
  if (fs.existsSync(exe) && fs.existsSync(defs)) return { exe, defs };

  console.log(`Installing luau-lsp ${LUAU_LSP_VERSION} into ${display(LSP_DIR)} ...`);
  fs.mkdirSync(LSP_DIR, { recursive: true });
  const base = `https://github.com/JohnnyMorganz/luau-lsp`;
  const zip = path.join(LSP_DIR, "luau-lsp.zip");
  await download(`${base}/releases/download/${LUAU_LSP_VERSION}/${releaseAsset()}`, zip);
  try {
    execFileSync("tar", ["-xf", zip, "-C", LSP_DIR]); // bsdtar (macOS, Windows) handles zip
  } catch {
    execFileSync("unzip", ["-o", "-q", zip, "-d", LSP_DIR]);
  }
  fs.rmSync(zip);
  if (process.platform !== "win32") fs.chmodSync(exe, 0o755);
  await download(
    `https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/${LUAU_LSP_VERSION}/scripts/globalTypes.PluginSecurity.d.luau`,
    defs
  );
  return { exe, defs };
}

// Parses luau-lsp's default output into { file, location, kind, message } issues.
function parseAnalysis(output) {
  const issues = [];
  for (const line of output.split(/\r?\n/)) {
    if (!line.trim() || line.startsWith("[INFO]") || line.startsWith("[WARN]")) continue;
    // e.g. /abs/path/File.luau [ProjectRoot/System/File](34,18): TypeError: message
    const match = line.match(/^(.*?)(?: \[(.*?)\])?\((\d+),(\d+)\): (\w+): (.*)$/);
    if (match) {
      const [, file, instancePath, lineNo, col, kind, message] = match;
      issues.push({
        file,
        instancePath: instancePath ? instancePath.replace(/^ProjectRoot/, ROOT_NAME).replace(/\//g, ".") : null,
        lineNo: Number(lineNo),
        col: Number(col),
        kind,
        message,
      });
    } else if (issues.length > 0 && /^\s/.test(line)) {
      issues[issues.length - 1].message += `\n${line}`;
    } else {
      issues.push({ file: "", lineNo: 0, col: 0, kind: "Output", message: line });
    }
  }
  // luau-lsp can report the same issue more than once.
  const seen = new Set();
  return issues.filter((issue) => {
    const key = `${issue.file}:${issue.lineNo}:${issue.col}:${issue.kind}:${issue.message}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

// --- checks --------------------------------------------------------------

function checkPacks() {
  const config = packs.readConfig();
  const packDirs = packs.resolvePackDirs(config, { log: (msg) => console.log(msg) });
  const { loaded, problems } = packs.loadPacks(packDirs);
  for (const problem of problems) errors.push(`pack: ${problem}`);

  const expectedSdk = sdk.generate();
  for (const pack of loaded) {
    const { id } = pack.manifest;
    const toolsDir = path.join(pack.sourceDir, "Tools");
    if (!fs.existsSync(toolsDir)) {
      errors.push(`pack ${id}: no Tools folder in ${display(pack.sourceDir)}`);
    } else if (!fs.readdirSync(toolsDir).some((name) => /\.luau?$/.test(name) || fs.existsSync(path.join(toolsDir, name, "init.luau")))) {
      warnings.push(`pack ${id}: Tools folder has no tool modules`);
    }
    const sdkStatus = sdk.status(pack.sourceDir, expectedSdk);
    if (sdkStatus !== "current") {
      warnings.push(`pack ${id}: ${sdk.FILE_NAME} is ${sdkStatus}; run \`npm run export-sdk -- ${display(pack.dir)}\``);
    }
  }
  return loaded;
}

async function checkLuau(loadedPacks, libs) {
  const { exe, defs } = await ensureLuauLsp();
  const files = treeFiles(loadedPacks);
  // Libraries are mounted at StudioTools/Libraries/<name> in Studio. They're
  // in the sourcemap so requires of them resolve, but aren't analyzed themselves.
  const libraryFiles = libs.flatMap((lib) =>
    collectFiles(lib.sourceDir).map((f) => ({ path: `Libraries/${lib.name}/${f.path}`, absPath: f.absPath }))
  );

  const workDir = path.join(TOOLS_DIR, "check");
  fs.mkdirSync(workDir, { recursive: true });
  const sourcemapPath = path.join(workDir, "sourcemap.json");
  fs.writeFileSync(sourcemapPath, JSON.stringify(buildSourcemap([...files, ...libraryFiles])));

  const result = spawnSync(
    exe,
    [
      "analyze",
      `--sourcemap=${sourcemapPath}`,
      `--definitions=@roblox=${defs}`,
      ...files.map((f) => f.absPath),
      LOADER_PATH,
    ],
    { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 }
  );
  if (result.error) throw result.error;

  // Windows paths compare case-insensitively (luau-lsp reports "d:\..." for "D:\...").
  const normalizePath = (p) => (process.platform === "win32" ? path.resolve(p).toLowerCase() : path.resolve(p));
  const libraryRoot = normalizePath(libraries.CACHE_DIR) + path.sep;
  for (const issue of parseAnalysis(`${result.stdout}\n${result.stderr}`)) {
    // Library code is checked by its own project, not here.
    if (issue.file && normalizePath(issue.file).startsWith(libraryRoot)) continue;
    const where = issue.file
      ? `${display(issue.file)}:${issue.lineNo}:${issue.col}${issue.instancePath ? ` (${issue.instancePath})` : ""}`
      : "luau-lsp";
    const text = `${where}: ${issue.kind}: ${issue.message}`;
    // Type and syntax errors fail the check; lints (DeprecatedApi, LocalUnused, ...) are warnings.
    if (/Error$/.test(issue.kind)) errors.push(text);
    else warnings.push(text);
  }
  return files.length + 1;
}

async function checkLibraries() {
  try {
    return await libraries.syncLibraries({ log: (msg) => console.log(msg) });
  } catch (err) {
    errors.push(`libraries: ${err.message}`);
    return [];
  }
}

async function main() {
  const loadedPacks = checkPacks();
  const libs = await checkLibraries();
  const fileCount = await checkLuau(loadedPacks, libs);

  for (const w of warnings) console.log(`warning: ${w}`);
  for (const e of errors) console.log(`error: ${e}`);
  const packList = loadedPacks.map((p) => p.manifest.id).join(", ") || "none";
  const libList = libs.map((l) => `${l.name} ${l.tag}`).join(", ") || "none";
  console.log(
    `\nChecked ${fileCount} files, packs: ${packList}, libraries: ${libList}. ${errors.length} error(s), ${warnings.length} warning(s).`
  );
  process.exitCode = errors.length > 0 ? 1 : 0;
}

main().catch((err) => {
  console.error(`check failed to run: ${err.stack || err}`);
  process.exitCode = 2;
});
