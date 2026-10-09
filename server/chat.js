// The Studio "Tools Agent" chat: an agent-neutral conversation backed by a
// headless coding agent (Claude Code or Codex, chosen with STUDIO_AGENT; see
// agents/index.js for the adapter interface).
//
// Each chat message runs one agent turn in the repo root, resuming the
// agent's previous session so context carries over between messages. The
// conversation (messages + agent session id) is the source of truth here and
// is saved to .chat/conversation.json, so it survives server restarts and
// Studio hot reloads; the Studio UI just displays it and never needs to know
// which agent is behind it.
//
// Tools in Studio can also send prompts (ctx:askAgent, "requests"). They go
// into the same conversation, labeled with the tool that sent them, and are
// queued while the agent is busy. Each request's status and final reply can
// be long-polled, so the tool can wait for the result. Requests live in
// memory only: a server restart forgets them (and the tool's request fails).
//
// If the agent can't be used (unknown STUDIO_AGENT, or its CLI doesn't run),
// the chat reports itself unavailable to Studio in neutral terms and the
// details go to the server log; the rest of the server is unaffected. A
// missing CLI is re-checked periodically, so installing it is enough.

const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const { execFile } = require("node:child_process");
const packs = require("./packs");
const { getAgent } = require("./agents");
const { REPO_ROOT } = require("./tree");

const STATE_DIR = path.join(REPO_ROOT, ".chat");
const STATE_FILE = path.join(STATE_DIR, "conversation.json");
const MAX_MESSAGES = 300;
const POLL_TIMEOUT_MS = 15000;
const RECHECK_MS = 30000;
const UNAVAILABLE_TEXT = "The Tools Agent isn't available. Details are in the server log.";
const MAX_QUEUED_REQUESTS = 10;
const MAX_PROMPT_LENGTH = 20000;
const KEEP_FINISHED_REQUESTS_MS = 30 * 60 * 1000;
const MAX_KEPT_REQUESTS = 200;
const FINISHED = new Set(["done", "failed", "cancelled"]);

// The agent's system prompt (chat-specific instructions on top of AGENTS.md).
// Read for every turn, so edits apply without a server restart. Claude Code
// applies them on every message; Codex keeps a session's first instructions
// until New chat.
const INSTRUCTIONS_PATH = path.join(__dirname, "agent-instructions.md");

function readInstructions() {
  try {
    return fs.readFileSync(INSTRUCTIONS_PATH, "utf8").trim();
  } catch (err) {
    log(`[chat] Can't read ${INSTRUCTIONS_PATH}: ${err.message}`);
    return "";
  }
}

let log = console.log;
let agent = null;
// "checking" (treated as available), "available" or "unavailable"
let availability = { state: "checking", detail: "" };
let recheckTimer = null;

// --- state -----------------------------------------------------------------

function newConversation() {
  return { conversationId: crypto.randomUUID(), agent: null, sessionId: null, nextId: 1, messages: [] };
}

let state = newConversation();
let revision = 1;
let job = null; // { handle, stopped, request }
let activity = "";
const waiters = new Set();

// Tool requests: id -> { id, prompt, source: { toolId, name }, status, reply, error, finishedAt, waiters }
// status: "queued" | "running" | "done" | "failed" | "cancelled"
const requests = new Map();
const queue = []; // queued requests, oldest first

function loadState() {
  try {
    const saved = JSON.parse(fs.readFileSync(STATE_FILE, "utf8"));
    if (saved && Array.isArray(saved.messages) && typeof saved.conversationId === "string") {
      // Conversations saved before agents were configurable were Claude Code sessions.
      if (saved.sessionId && !saved.agent) saved.agent = "claude";
      state = saved;
    }
  } catch {
    // no saved conversation yet
  }
}

function saveState() {
  try {
    fs.mkdirSync(STATE_DIR, { recursive: true });
    fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 1));
  } catch (err) {
    log(`[chat] Can't save conversation: ${err.message}`);
  }
}

function changed() {
  revision += 1;
  for (const respond of waiters) respond();
  waiters.clear();
}

// role: "user" | "assistant" | "tool" (a step) | "info" | "error"
// source: for a user message sent by a tool, the tool's display name
function addMessage(role, text, source) {
  const message = { id: state.nextId++, role, text: String(text), time: Date.now() };
  if (source) message.source = source;
  state.messages.push(message);
  if (state.messages.length > MAX_MESSAGES) state.messages.splice(0, state.messages.length - MAX_MESSAGES);
  saveState();
  changed();
}

function setActivity(text) {
  activity = text;
  changed();
}

// --- availability ------------------------------------------------------------

function setAvailability(state, detail = "") {
  const wasUnavailable = availability.state === "unavailable";
  availability = { state, detail };
  if (state === "unavailable") {
    if (!wasUnavailable) log(`[chat] Tools Agent unavailable: ${detail}`);
    if (agent && !recheckTimer) {
      recheckTimer = setTimeout(() => {
        recheckTimer = null;
        checkAgent();
      }, RECHECK_MS);
      recheckTimer.unref();
    }
  } else if (wasUnavailable) {
    log("[chat] Tools Agent available again");
  }
  if (state === "unavailable" || wasUnavailable) changed();
}

// Runs `<cli> --version` to see whether the agent can be started.
function checkAgent() {
  const bin = agent.bin();
  execFile(bin, ["--version"], { timeout: 20000 }, (err, stdout) => {
    if (err) {
      const reason = err.code === "ENOENT" ? "not found" : err.message.split("\n")[0];
      setAvailability("unavailable", `${agent.displayName} CLI \`${bin}\` couldn't be run (${reason}). ${agent.setupHint}`);
    } else {
      if (availability.state === "checking") log(`Tools Agent chat: ${agent.displayName} (${stdout.trim().split("\n")[0]})`);
      setAvailability("available");
    }
  });
}

// --- running the agent -----------------------------------------------------

// Local packs outside the repo, which the agent must be allowed to edit.
function extraDirs() {
  try {
    return packs
      .resolvePackDirs({ packs: packs.readConfig().packs.filter((e) => typeof e.path === "string" && e.enabled !== false) })
      .map((p) => p.dir)
      .filter((dir) => dir !== REPO_ROOT && !dir.startsWith(REPO_ROOT + path.sep));
  } catch {
    return [];
  }
}

// request: the tool request this turn answers, if any.
function runTurn(message, allowFreshRetry, request = null) {
  // A session belongs to the agent that created it; after switching agents, start fresh.
  if (state.sessionId && state.agent !== agent.id) {
    state.sessionId = null;
    addMessage("info", `Now using ${agent.displayName}; starting a new agent session.`);
  }
  state.agent = agent.id;
  saveState();

  const thisJob = { handle: null, stopped: false, request };
  job = thisJob;
  setActivity("Thinking…"); // after setting job, so the update shows it running
  let lastReply = null;

  thisJob.handle = agent.run(
    {
      message,
      sessionId: state.sessionId,
      cwd: REPO_ROOT,
      extraDirs: extraDirs(),
      instructions: readInstructions(),
    },
    {
      session(id) {
        if (state.sessionId !== id) {
          state.sessionId = id;
          saveState();
        }
      },
      reply(text) {
        lastReply = text;
        addMessage("assistant", text);
        setActivity("Thinking…");
      },
      step(text) {
        addMessage("tool", text);
        setActivity(text);
      },
      activity(text) {
        setActivity(text);
      },
      refused(list) {
        addMessage("info", `Refused (needs approval, which the chat can't give): ${list.join(", ")}`);
      },
      finish(result) {
        if (job === thisJob) job = null;
        if (thisJob.stopped) {
          addMessage("info", "Stopped.");
        } else if (result.unavailable) {
          addMessage("error", UNAVAILABLE_TEXT);
          setAvailability("unavailable", `${result.unavailable}. ${agent.setupHint}`);
        } else if (result.sessionMissing && allowFreshRetry) {
          state.sessionId = null;
          saveState();
          addMessage("info", "The previous agent session wasn't found; starting a new one.");
          runTurn(message, false, request);
          return;
        } else if (result.error || result.sessionMissing) {
          addMessage("error", result.error || "The agent session wasn't found.");
        }
        const outcome = thisJob.stopped ? "stopped" : result.error || result.unavailable ? "failed" : "finished";
        log(`[chat] ${agent.id} turn ${outcome}${result.summary ? ` (${result.summary})` : ""}`);
        if (request) {
          if (thisJob.stopped) finishRequest(request, "cancelled");
          else if (result.unavailable) finishRequest(request, "failed", { error: UNAVAILABLE_TEXT });
          else if (result.error || result.sessionMissing)
            finishRequest(request, "failed", { error: result.error || "The agent session wasn't found." });
          else finishRequest(request, "done", { reply: lastReply });
        }
        setActivity("");
        runNextRequest();
      },
    }
  );
}

// --- tool requests -----------------------------------------------------------

function requestInfo(request) {
  const position = queue.indexOf(request) + 1; // 0 when not queued
  return {
    id: request.id,
    status: request.status,
    position: position || undefined,
    reply: request.reply ?? undefined,
    error: request.error ?? undefined,
  };
}

function notifyRequest(request) {
  for (const respond of request.waiters) respond();
  request.waiters.clear();
}

function finishRequest(request, status, { reply = null, error = null } = {}) {
  if (FINISHED.has(request.status)) return;
  request.status = status;
  request.reply = reply;
  request.error = error;
  request.finishedAt = Date.now();
  log(`[chat] Request ${request.id} from ${request.source.toolId} ${status}${error ? `: ${error}` : ""}`);
  notifyRequest(request);
}

// Forgets finished requests once they're old, or when there are too many.
function pruneRequests() {
  const now = Date.now();
  const finished = [...requests.values()].filter((r) => FINISHED.has(r.status));
  finished.forEach((r, i) => {
    if (now - r.finishedAt > KEEP_FINISHED_REQUESTS_MS || i < finished.length - MAX_KEPT_REQUESTS) requests.delete(r.id);
  });
}

// The message the agent sees: the prompt, marked as coming from a tool
// (see "Requests from tools" in agent-instructions.md).
function requestMessage(request) {
  return `[Request from the Studio tool "${request.source.name}" (${request.source.toolId})]\n\n${request.prompt}`;
}

// Starts the oldest queued request if the agent is free.
function runNextRequest() {
  if (job || queue.length === 0) return;
  if (availability.state === "unavailable") {
    for (const request of queue.splice(0)) finishRequest(request, "failed", { error: UNAVAILABLE_TEXT });
    changed();
    return;
  }
  const request = queue.shift();
  request.status = "running";
  notifyRequest(request);
  addMessage("user", request.prompt, request.source.name);
  log(`[chat] Request ${request.id} from ${request.source.toolId} to ${agent.id}: ${request.prompt.split("\n")[0].slice(0, 120)}`);
  runTurn(requestMessage(request), true, request);
}

// POST /chat/requests { prompt, toolId, toolName }
function submitRequest(body) {
  if (availability.state === "unavailable") return { status: 503, body: { error: UNAVAILABLE_TEXT } };
  const prompt = typeof body.prompt === "string" ? body.prompt.trim() : "";
  if (!prompt) return { status: 400, body: { error: "Empty prompt." } };
  if (prompt.length > MAX_PROMPT_LENGTH) {
    return { status: 400, body: { error: `The prompt is too long (over ${MAX_PROMPT_LENGTH} characters).` } };
  }
  if (queue.length >= MAX_QUEUED_REQUESTS) {
    return { status: 429, body: { error: `Too many requests are waiting for the agent (${MAX_QUEUED_REQUESTS}).` } };
  }
  const toolId = typeof body.toolId === "string" && body.toolId ? body.toolId : "unknown";
  const name = typeof body.toolName === "string" && body.toolName ? body.toolName : toolId;
  pruneRequests();
  const request = {
    id: crypto.randomUUID(),
    prompt,
    source: { toolId, name },
    status: "queued",
    reply: null,
    error: null,
    finishedAt: 0,
    waiters: new Set(),
  };
  requests.set(request.id, request);
  queue.push(request);
  if (job) changed(); // the queued count is shown in the chat
  runNextRequest();
  return { status: 200, body: requestInfo(request) };
}

// POST /chat/requests/cancel { id }: drops a queued request, or stops the
// agent if it's working on it.
function cancelRequest(id) {
  const request = requests.get(id);
  if (!request) return { status: 404, body: { error: "Unknown request." } };
  const index = queue.indexOf(request);
  if (index !== -1) {
    queue.splice(index, 1);
    finishRequest(request, "cancelled");
    changed();
  } else if (job && job.request === request) {
    job.stopped = true;
    job.handle.stop();
  }
  return { status: 200, body: requestInfo(request) };
}

// GET /chat/requests/poll?id=<id>&status=<status the caller last saw>
// Answers immediately if the status differs (or the request is finished),
// else waits up to POLL_TIMEOUT_MS.
function pollRequest(req, res, url, sendJson) {
  const request = requests.get(url.searchParams.get("id") || "");
  if (!request) {
    return sendJson(res, 404, { error: "Unknown request. The tool server may have restarted." });
  }
  if (request.status !== url.searchParams.get("status") || FINISHED.has(request.status)) {
    return sendJson(res, 200, requestInfo(request));
  }
  let done = false;
  const respond = () => {
    if (done) return;
    done = true;
    clearTimeout(timer);
    request.waiters.delete(respond);
    sendJson(res, 200, requestInfo(request));
  };
  const timer = setTimeout(respond, POLL_TIMEOUT_MS);
  request.waiters.add(respond);
  req.on("close", () => {
    done = true;
    clearTimeout(timer);
    request.waiters.delete(respond);
  });
}

// --- API -------------------------------------------------------------------

function start(message) {
  if (availability.state === "unavailable") return { status: 503, body: { error: UNAVAILABLE_TEXT } };
  if (job || queue.length > 0) return { status: 409, body: { error: "The agent is still working on the previous message." } };
  const text = typeof message === "string" ? message.trim() : "";
  if (!text) return { status: 400, body: { error: "Empty message." } };
  addMessage("user", text);
  log(`[chat] Message to ${agent.id}: ${text.split("\n")[0].slice(0, 120)}`);
  runTurn(text, true);
  return { status: 200, body: { ok: true } };
}

// Stops the agent, and cancels any tool requests waiting for it.
function stop() {
  if (queue.length > 0) {
    for (const request of queue.splice(0)) finishRequest(request, "cancelled");
    changed();
  }
  if (!job) return { status: 200, body: { ok: true, running: false } };
  job.stopped = true;
  job.handle.stop();
  return { status: 200, body: { ok: true } };
}

function reset() {
  if (job) return { status: 409, body: { error: "Stop the current request before starting a new chat." } };
  state = newConversation();
  saveState();
  changed();
  log("[chat] New conversation");
  return { status: 200, body: { ok: true } };
}

function snapshot(after, conversationId) {
  const sameConversation = conversationId === state.conversationId;
  return {
    conversationId: state.conversationId,
    revision,
    running: job !== null,
    // When the running turn is a tool's request, the tool's name.
    runningTool: job && job.request ? job.request.source.name : null,
    activity,
    queued: queue.length, // tool requests waiting for the agent
    available: availability.state !== "unavailable",
    unavailableReason: availability.state === "unavailable" ? UNAVAILABLE_TEXT : null,
    reset: !sameConversation,
    messages: sameConversation ? state.messages.filter((m) => m.id > after) : state.messages,
  };
}

// GET /chat/poll?rev=<revision>&after=<last message id>&conversation=<id>
// Answers immediately if anything changed since `rev`, else waits up to POLL_TIMEOUT_MS.
function poll(req, res, url, sendJson) {
  const rev = Number(url.searchParams.get("rev")) || 0;
  const after = Number(url.searchParams.get("after")) || 0;
  const conversationId = url.searchParams.get("conversation") || "";
  if (rev !== revision || conversationId !== state.conversationId) {
    return sendJson(res, 200, snapshot(after, conversationId));
  }
  let done = false;
  const respond = () => {
    if (done) return;
    done = true;
    clearTimeout(timer);
    waiters.delete(respond);
    sendJson(res, 200, snapshot(after, conversationId));
  };
  const timer = setTimeout(respond, POLL_TIMEOUT_MS);
  waiters.add(respond);
  req.on("close", () => {
    done = true;
    clearTimeout(timer);
    waiters.delete(respond);
  });
}

function init(options = {}) {
  if (options.log) log = options.log;
  loadState();
  try {
    agent = getAgent(process.env.STUDIO_AGENT);
  } catch (err) {
    setAvailability("unavailable", `${err.message}. Fix it in .env and restart the server.`);
    return;
  }
  checkAgent();
}

function agentName() {
  return agent ? agent.id : null;
}

// For the server's status endpoint.
function status() {
  return { agent: agentName(), state: availability.state, detail: availability.detail || undefined };
}

function shutdown() {
  if (job) {
    job.stopped = true;
    job.handle.stop();
  }
}

module.exports = {
  init,
  start,
  stop,
  reset,
  poll,
  submitRequest,
  cancelRequest,
  pollRequest,
  shutdown,
  agentName,
  status,
};
