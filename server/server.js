#!/usr/bin/env node
// Studio Tools System dev server.
//
// Serves the framework (../studio_plugin_src) plus every tool pack listed in
// ../toolpacks.json as a JSON "bundle" that the StudioToolsLoader plugin turns
// into ModuleScripts inside Studio. Pack files are placed under
// Packs/<packId>/. Watches everything for changes and notifies the plugin via
// long-polling so it can hot-reload.
//
// Endpoints:
//   GET /version            -> { version, hash }
//   GET /bundle             -> { version, hash, files: [{ path, source }], packs: [manifest] }
//   GET /poll?since=<hash>  -> { version, hash }, returned immediately if the
//                              hash differs from `since`, otherwise held open
//                              until a change happens or the timeout expires.
//   POST /log               <- { build, entries: [{ kind, message }] } from the
//                              plugin: Studio output mentioning StudioTools.
//   POST /chat              <- { message }: send a message to the Tools Agent (see chat.js;
//                              the coding agent behind it is set in .env)
//   GET  /chat/poll         -> conversation updates (long-poll)
//   POST /chat/stop, POST /chat/reset
//   POST /chat/requests     <- { prompt, toolId, toolName }: a prompt from a tool (ctx:askAgent),
//                              queued behind the agent's current work -> { id, status, ... }
//   GET  /chat/requests/poll?id=&status= -> that request's status/reply (long-poll)
//   POST /chat/requests/cancel <- { id }
//
// Security: requests must address the server as localhost (blocks DNS
// rebinding), and POSTs must carry an `X-Studio-Tools: 1` header, which a web
// page can't add to a cross-site request (so websites can't drive the chat).
//
// Server events and Studio output are both written to logs/studio-tools.log
// (truncated on start), so agents can follow what happens in Studio.

require("./env").loadEnv(); // before anything reads process.env
const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const packs = require("./packs");
const chat = require("./chat");
const { REPO_ROOT, SRC_DIR, treeFiles } = require("./tree");

const PORT = Number(process.env.PORT) || 34873;
// Listen on both loopback addresses since "localhost" may resolve to either.
const HOSTS = process.env.HOST ? [process.env.HOST] : ["127.0.0.1", "::1"];
const POLL_TIMEOUT_MS = 15000;
const DEBOUNCE_MS = 100;

let bundle = { version: 0, hash: "", files: [], packs: [] };
let waiters = new Set();

const LOG_PATH = path.resolve(process.env.LOG_FILE || path.join(__dirname, "..", "logs", "studio-tools.log"));
fs.mkdirSync(path.dirname(LOG_PATH), { recursive: true });
fs.writeFileSync(LOG_PATH, "");

function writeLog(source, text) {
  const time = new Date().toISOString();
  const lines = String(text).split(/\r?\n/);
  const body = lines.map((line, i) => (i === 0 ? `${time} [${source}] ${line}` : `    ${line}`)).join("\n");
  fs.appendFileSync(LOG_PATH, body + "\n");
}

function log(...args) {
  const text = args.join(" ");
  console.log(`[${new Date().toLocaleTimeString()}]`, text);
  writeLog("server", text);
}

// Studio output forwarded by the plugin.
function logStudio(body) {
  const build = body.build != null ? `build ${body.build} ` : "";
  for (const entry of Array.isArray(body.entries) ? body.entries : []) {
    const kind = typeof entry.kind === "string" ? entry.kind : "output";
    const message = String(entry.message ?? "");
    writeLog(`studio ${build}${kind}`, message);
    const firstLine = message.split(/\r?\n/)[0];
    const more = message.includes("\n") ? " (…)" : "";
    console.log(`[${new Date().toLocaleTimeString()}] [studio ${build}${kind}] ${firstLine}${more}`);
  }
}

function readJsonBody(req, limit, callback) {
  let size = 0;
  const chunks = [];
  req.on("data", (chunk) => {
    size += chunk.length;
    if (size > limit) req.destroy();
    else chunks.push(chunk);
  });
  req.on("end", () => {
    try {
      callback(null, JSON.parse(Buffer.concat(chunks).toString("utf8")));
    } catch (err) {
      callback(err);
    }
  });
}

function describeChanges(oldFiles, newFiles) {
  const oldMap = new Map(oldFiles.map((f) => [f.path, f.source]));
  const newMap = new Map(newFiles.map((f) => [f.path, f.source]));
  const changes = [];
  for (const [p, src] of newMap) {
    if (!oldMap.has(p)) changes.push(`+ ${p}`);
    else if (oldMap.get(p) !== src) changes.push(`~ ${p}`);
  }
  for (const p of oldMap.keys()) {
    if (!newMap.has(p)) changes.push(`- ${p}`);
  }
  return changes;
}

// Pack directories from toolpacks.json; re-resolved (and missing git packs
// cloned) whenever the config file changes.
let packDirs = [];
let configDirty = true;
let lastPackProblems = "";

// Watchers for the framework and each pack, keyed by directory.
const watchers = new Map();
function setWatchedDirs(dirs) {
  for (const [dir, watcher] of watchers) {
    if (!dirs.has(dir)) {
      watcher.close();
      watchers.delete(dir);
    }
  }
  for (const dir of dirs) {
    if (watchers.has(dir) || !fs.existsSync(dir)) continue;
    try {
      watchers.set(dir, fs.watch(dir, { recursive: true }, scheduleRebuild));
    } catch (err) {
      log(`Can't watch ${dir}: ${err.message}`);
    }
  }
}

function loadPacks() {
  if (configDirty) {
    configDirty = false;
    try {
      packDirs = packs.resolvePackDirs(packs.readConfig(), { log });
    } catch (err) {
      log(`Can't read pack config: ${err.message}`);
    }
  }

  const { loaded, problems } = packs.loadPacks(packDirs);
  // Only repeat problems when they change, not on every file save.
  const problemText = problems.join("\n");
  if (problemText !== lastPackProblems) {
    for (const problem of problems) log(`Pack problem: ${problem}`);
    lastPackProblems = problemText;
  }
  return loaded;
}

function rebuild() {
  const loadedPacks = loadPacks();
  setWatchedDirs(new Set([SRC_DIR, ...packDirs.map((p) => p.dir)]));

  let files;
  try {
    files = treeFiles(loadedPacks).map((f) => ({ path: f.path, source: fs.readFileSync(f.absPath, "utf8") }));
  } catch (err) {
    // Usually a file vanished mid-scan (editor save dance); the next event will retry.
    log("Scan failed, will retry on next change:", err.message);
    return;
  }
  const manifests = loadedPacks.map((p) => p.manifest);

  const hasher = crypto.createHash("sha1");
  hasher.update(JSON.stringify(manifests)).update("\0");
  for (const f of files) hasher.update(f.path).update("\0").update(f.source).update("\0");
  const hash = hasher.digest("hex").slice(0, 16);
  if (hash === bundle.hash) return;

  const changes = describeChanges(bundle.files, files);
  bundle = { version: bundle.version + 1, hash, files, packs: manifests };
  const packList = manifests.map((m) => `${m.id}@${m.version}`).join(", ") || "none";
  log(`Build ${bundle.version} (${hash}), ${files.length} files, packs: ${packList}`);
  if (bundle.version > 1) for (const c of changes) log(`    ${c}`);

  for (const respond of waiters) respond();
  waiters.clear();
}

let debounceTimer = null;
function scheduleRebuild() {
  clearTimeout(debounceTimer);
  debounceTimer = setTimeout(rebuild, DEBOUNCE_MS);
}

function sendJson(res, status, body) {
  const data = JSON.stringify(body);
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Content-Length": Buffer.byteLength(data),
    "Cache-Control": "no-store",
  });
  res.end(data);
}

function versionInfo() {
  return { version: bundle.version, hash: bundle.hash };
}

const ALLOWED_HOSTNAMES = new Set(["localhost", "127.0.0.1", "[::1]"]);

function isAllowedHost(req) {
  const hostname = (req.headers.host || "").replace(/:\d+$/, "").toLowerCase();
  return ALLOWED_HOSTNAMES.has(hostname);
}

function handlePost(req, res, url) {
  if (req.headers["x-studio-tools"] !== "1") return sendJson(res, 403, { error: "missing X-Studio-Tools header" });

  const withBody = (handler) =>
    readJsonBody(req, 1024 * 1024, (err, body) => {
      if (err) return sendJson(res, 400, { error: "invalid JSON" });
      handler(body || {});
    });
  const reply = (result) => sendJson(res, result.status, result.body);

  switch (url.pathname) {
    case "/log":
      return withBody((body) => {
        logStudio(body);
        sendJson(res, 200, { ok: true });
      });
    case "/chat":
      return withBody((body) => reply(chat.start(body.message)));
    case "/chat/stop":
      return reply(chat.stop());
    case "/chat/reset":
      return reply(chat.reset());
    case "/chat/requests":
      return withBody((body) => reply(chat.submitRequest(body)));
    case "/chat/requests/cancel":
      return withBody((body) => reply(chat.cancelRequest(body.id)));
    default:
      return sendJson(res, 404, { error: "not found" });
  }
}

function handleRequest(req, res) {
  if (!isAllowedHost(req)) return sendJson(res, 403, { error: "forbidden host" });
  const url = new URL(req.url, "http://localhost");

  if (req.method === "POST") return handlePost(req, res, url);
  if (req.method !== "GET") return sendJson(res, 405, { error: "method not allowed" });

  switch (url.pathname) {
    case "/":
      return sendJson(res, 200, {
        name: "studio-tools-system",
        srcDir: SRC_DIR,
        repoRoot: REPO_ROOT,
        config: packs.CONFIG_PATHS,
        logFile: LOG_PATH,
        packs: bundle.packs,
        agent: chat.agentName(),
        chat: chat.status(),
        ...versionInfo(),
      });

    case "/version":
      return sendJson(res, 200, versionInfo());

    case "/bundle":
      return sendJson(res, 200, bundle);

    case "/chat/poll":
      return chat.poll(req, res, url, sendJson);

    case "/chat/requests/poll":
      return chat.pollRequest(req, res, url, sendJson);

    case "/poll": {
      const since = url.searchParams.get("since") || "";
      if (since !== bundle.hash) return sendJson(res, 200, versionInfo());

      let done = false;
      const respond = () => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        waiters.delete(respond);
        sendJson(res, 200, versionInfo());
      };
      const timer = setTimeout(respond, POLL_TIMEOUT_MS);
      waiters.add(respond);
      req.on("close", () => {
        done = true;
        clearTimeout(timer);
        waiters.delete(respond);
      });
      return;
    }

    default:
      return sendJson(res, 404, { error: "not found" });
  }
}

if (!fs.existsSync(SRC_DIR)) {
  console.error(`Source directory not found: ${SRC_DIR}`);
  process.exit(1);
}

// fs.watchFile polls, so it also notices toolpacks.json being created later.
for (const configPath of packs.CONFIG_PATHS) {
  fs.watchFile(configPath, { interval: 1000 }, () => {
    log(`${path.basename(configPath)} changed`);
    configDirty = true;
    scheduleRebuild();
  });
}

// New pack folders in user_toolpacks/ are picked up without a config change.
fs.mkdirSync(packs.USER_PACKS_DIR, { recursive: true });
try {
  fs.watch(packs.USER_PACKS_DIR, { recursive: true }, () => {
    configDirty = true;
    scheduleRebuild();
  });
} catch (err) {
  log(`Can't watch ${packs.USER_PACKS_DIR}: ${err.message}`);
}

log(`Framework: ${SRC_DIR}`);
log(`Log file: ${LOG_PATH}`);
chat.init({ log });
for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => {
    chat.shutdown();
    process.exit(0);
  });
}
log(`Pack config: ${packs.CONFIG_PATHS.join(" + ")} + packs in ${packs.USER_PACKS_DIR}`);
rebuild();
for (const host of HOSTS) {
  const server = http.createServer(handleRequest);
  server.on("error", (err) => {
    if (host === "::1" && HOSTS.length > 1) return; // no IPv6 loopback, that's fine
    console.error(`Failed to listen on ${host}:${PORT}: ${err.message}`);
    process.exit(1);
  });
  server.listen(PORT, host, () => {
    log(`Listening on http://${host.includes(":") ? `[${host}]` : host}:${PORT}`);
  });
}
