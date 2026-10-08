// Loads KEY=VALUE settings from the repo's .env file (gitignored; see
// .env.example) into process.env. Variables already set in the real
// environment win, so `PORT=1234 npm start` still works.

const fs = require("node:fs");
const path = require("node:path");

const ENV_PATH = path.join(__dirname, "..", ".env");

function loadEnv() {
  let text;
  try {
    text = fs.readFileSync(ENV_PATH, "utf8");
  } catch {
    return; // no .env: defaults apply
  }
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const match = line.match(/^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
    if (!match) continue;
    let value = match[2];
    if (/^(["']).*\1$/.test(value)) {
      value = value.slice(1, -1);
    } else {
      value = value.replace(/\s+#.*$/, "").trim(); // trailing comment
    }
    if (process.env[match[1]] === undefined) process.env[match[1]] = value;
  }
}

module.exports = { ENV_PATH, loadEnv };
