// Coding agents that can power the Studio "Tools Agent" chat. Pick one with
// STUDIO_AGENT in .env (default "claude").
//
// An adapter is { id, displayName, run(turn, handlers) -> { stop() } }, where
//
//   turn = {
//     message,       // the user's text
//     sessionId,     // the agent's session id to resume, or null for a new session
//     cwd,           // the repo root
//     extraDirs,     // local pack folders outside the repo that must be editable
//     instructions,  // chat-specific instructions to apply to the session
//   }
//
// and the adapter reports progress through `handlers`:
//
//   session(id)        the agent's session id (stored and passed back to resume)
//   reply(text)        a text reply for the user
//   step(text)         a visible step for the history, e.g. "Edit path/to/file"
//   activity(text)     transient "what it's doing now" status, not recorded
//   refused(list)      actions refused because nobody could approve them
//   finish(result)     exactly once: { error?, sessionMissing?, summary? }
//                      sessionMissing = the session to resume no longer exists
//                      (the conversation then retries once with a new session)

const AGENTS = {
  claude: require("./claude"),
  codex: require("./codex"),
};

function getAgent(id) {
  const agent = AGENTS[(id || "claude").toLowerCase()];
  if (!agent) throw new Error(`Unknown STUDIO_AGENT "${id}"; expected one of: ${Object.keys(AGENTS).join(", ")}`);
  return agent;
}

module.exports = { AGENTS, getAgent };
