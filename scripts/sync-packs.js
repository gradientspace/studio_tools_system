#!/usr/bin/env node
// Clones missing git tool packs and pulls the latest `ref` for existing ones.
// A running server picks up the changed files and hot-reloads them.

const packs = require("../server/packs");

const config = packs.readConfig();
const dirs = packs.resolvePackDirs(config, { update: true });
for (const packDir of dirs) {
  try {
    const { manifest } = packs.readPack(packDir);
    console.log(`  ${manifest.id}@${manifest.version} (API ${manifest.apiVersion})  ${packDir.origin}`);
  } catch (err) {
    console.log(`  problem: ${err.message}`);
  }
}
