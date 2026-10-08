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

const INSTRUCTIONS = `You are being driven from a chat box inside Roblox Studio (the Studio Tools System's "Tools Agent").
The user only sees your text replies, not your tool calls, commands or diffs, so end each turn with a short, plain summary of what you did or found. Keep replies brief.
The dev server is running and hot-reloads your edits into the user's Studio session (unless a tool is active there). Follow AGENTS.md: after editing Luau, run \`npm run check\`, then read logs/studio-tools.log to confirm the reload.
Nobody can approve permission prompts here, so actions that would need approval are refused; if one is refused, tell the user what you needed to do.`;

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
let job = null; // { handle, stopped }
let activity = "";
const waiters = new Set();

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
function addMessage(role, text) {
  state.messages.push({ id: state.nextId++, role, text: String(text), time: Date.now() });
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

function runTurn(message, allowFreshRetry) {
  // A session belongs to the agent that created it; after switching agents, start fresh.
  if (state.sessionId && state.agent !== agent.id) {
    state.sessionId = null;
    addMessage("info", `Now using ${agent.displayName}; starting a new agent session.`);
  }
  state.agent = agent.id;
  saveState();

  setActivity("Thinking…");
  const thisJob = { handle: null, stopped: false };
  job = thisJob;

  thisJob.handle = agent.run(
    {
      message,
      sessionId: state.sessionId,
      cwd: REPO_ROOT,
      extraDirs: extraDirs(),
      instructions: INSTRUCTIONS,
    },
    {
      session(id) {
        if (state.sessionId !== id) {
          state.sessionId = id;
          saveState();
        }
      },
      reply(text) {
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
          runTurn(message, false);
          return;
        } else if (result.error || result.sessionMissing) {
          addMessage("error", result.error || "The agent session wasn't found.");
        }
        const outcome = thisJob.stopped ? "stopped" : result.error || result.unavailable ? "failed" : "finished";
        log(`[chat] ${agent.id} turn ${outcome}${result.summary ? ` (${result.summary})` : ""}`);
        setActivity("");
      },
    }
  );
}

// --- API -------------------------------------------------------------------

function start(message) {
  if (availability.state === "unavailable") return { status: 503, body: { error: UNAVAILABLE_TEXT } };
  if (job) return { status: 409, body: { error: "The agent is still working on the previous message." } };
  const text = typeof message === "string" ? message.trim() : "";
  if (!text) return { status: 400, body: { error: "Empty message." } };
  addMessage("user", text);
  log(`[chat] Message to ${agent.id}: ${text.split("\n")[0].slice(0, 120)}`);
  runTurn(text, true);
  return { status: 200, body: { ok: true } };
}

function stop() {
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
    activity,
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

module.exports = { init, start, stop, reset, poll, shutdown, agentName, status };
