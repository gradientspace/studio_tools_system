// The file tree that gets shipped to Studio: the framework (studio_plugin_src)
// plus each tool pack's source under Packs/<packId>/. Shared by the dev
// server, `npm run check` and `npm run export-sdk`.

const fs = require("node:fs");
const path = require("node:path");

const REPO_ROOT = path.resolve(__dirname, "..");
const SRC_DIR = path.resolve(process.env.SRC_DIR || path.join(REPO_ROOT, "studio_plugin_src"));
const ROOT_NAME = "StudioTools"; // name of the root Folder in Studio; part of the pack contract
const SOURCE_EXTENSIONS = new Set([".lua", ".luau"]);

// Lists Luau files under `dir` as [{ path, absPath }], with `path` relative and '/'-separated.
function collectFiles(dir, relDir = "") {
  const files = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name.startsWith(".") || entry.name === "node_modules") continue;
    const absPath = path.join(dir, entry.name);
    const relPath = relDir ? `${relDir}/${entry.name}` : entry.name;
    if (entry.isDirectory()) {
      files.push(...collectFiles(absPath, relPath));
    } else if (entry.isFile() && SOURCE_EXTENSIONS.has(path.extname(entry.name))) {
      files.push({ path: relPath, absPath });
    }
  }
  return files;
}

// All files in the shipped tree, sorted by path. `packs` are results of packs.readPack().
function treeFiles(packs) {
  const files = collectFiles(SRC_DIR);
  for (const pack of packs) {
    for (const file of collectFiles(pack.sourceDir)) {
      files.push({ path: `Packs/${pack.manifest.id}/${file.path}`, absPath: file.absPath });
    }
  }
  return files.sort((a, b) => a.path.localeCompare(b.path));
}

// Builds a Rojo-style sourcemap of the tree, mirroring how the loader turns
// files into ModuleScripts, so luau-lsp can resolve `script.Parent...` requires.
function buildSourcemap(files) {
  const root = { name: ROOT_NAME, className: "Folder", children: [] };
  const nodes = new Map([["", root]]);

  function getNode(dirPath) {
    if (nodes.has(dirPath)) return nodes.get(dirPath);
    const slash = dirPath.lastIndexOf("/");
    const parent = getNode(slash === -1 ? "" : dirPath.slice(0, slash));
    const node = { name: dirPath.slice(slash + 1), className: "Folder", children: [] };
    parent.children.push(node);
    nodes.set(dirPath, node);
    return node;
  }

  for (const file of files) {
    const slash = file.path.lastIndexOf("/");
    const dir = slash === -1 ? "" : file.path.slice(0, slash);
    const name = file.path.slice(slash + 1).replace(/\.luau?$/, "");
    if (name === "init" && dir !== "") {
      const node = getNode(dir);
      node.className = "ModuleScript";
      node.filePaths = [file.absPath];
    } else {
      getNode(dir).children.push({ name, className: "ModuleScript", filePaths: [file.absPath], children: [] });
    }
  }
  return root;
}

module.exports = { REPO_ROOT, SRC_DIR, ROOT_NAME, collectFiles, treeFiles, buildSourcemap };
