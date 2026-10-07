#!/usr/bin/env node
// Writes SDK.luau into tool packs (at the root of each pack's source folder).
//
//   npm run export-sdk                  every local ("path") pack in toolpacks.json
//   npm run export-sdk -- <packDir>...  specific pack folders (containing toolpack.json)
//
// Git packs are skipped: their cache is overwritten on sync, so the pack's own
// repo should commit its SDK.luau.

const path = require("node:path");
const packs = require("../server/packs");
const sdk = require("../server/sdk");

const args = process.argv.slice(2);
let packDirs;
if (args.length > 0) {
  packDirs = args.map((dir) => ({ dir: path.resolve(dir), origin: dir }));
} else {
  const config = packs.readConfig();
  packDirs = packs.resolvePackDirs({ packs: config.packs.filter((entry) => typeof entry.path === "string") });
}

let failed = false;
for (const packDir of packDirs) {
  try {
    const pack = packs.readPack(packDir);
    const file = sdk.write(pack.sourceDir);
    console.log(`${pack.manifest.id}: wrote ${path.relative(process.cwd(), file)} (API ${sdk.apiVersion()})`);
  } catch (err) {
    console.error(`Skipped: ${err.message}`);
    failed = true;
  }
}
process.exitCode = failed ? 1 : 0;
