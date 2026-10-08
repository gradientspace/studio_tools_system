// Codex adapter: `codex exec --json`, resuming with `codex exec resume <id>`.
//
// Codex reads AGENTS.md by itself. It has no flag for extra instructions,
// so the chat instructions are prepended to the first message of a session
// (the resumed thread keeps them).
//
// Commands run in Codex's sandbox: CODEX_SANDBOX (default "workspace-write":
// edit the repo and local packs, no network; "danger-full-access" for
// everything). Codex's own config (~/.codex/config.toml) applies otherwise.

const path = require("node:path");
const { runJsonLines } = require("./process");

const CHANGE_VERBS = { add: "Create", update: "Edit", delete: "Delete" };

function run(turn, handlers) {
  const bin = process.env.CODEX_BIN || "codex";
  const sandbox = process.env.CODEX_SANDBOX || "workspace-write";

  // Options go before the `resume` subcommand, which doesn't accept --sandbox
  // or --add-dir itself; config overrides (-c) work for both.
  const args = ["exec", "--json", "-c", `sandbox_mode="${sandbox}"`];
  if (turn.extraDirs.length > 0) {
    args.push("-c", `sandbox_workspace_write.writable_roots=${JSON.stringify(turn.extraDirs)}`);
  }
  if (process.env.STUDIO_AGENT_MODEL) args.push("-m", process.env.STUDIO_AGENT_MODEL);
  if (turn.sessionId) args.push("resume", turn.sessionId);
  args.push("-"); // prompt from stdin

  const input = turn.sessionId
    ? turn.message
    : `[Instructions for this session]\n${turn.instructions}\n\n[User message]\n${turn.message}`;

  const rel = (file) => {
    if (typeof file !== "string") return "";
    const r = path.relative(turn.cwd, file);
    return r.startsWith("..") ? file : r;
  };

  let failure = null; // from turn.failed
  let lastError = null; // from "error" events (may be transient, e.g. reconnects)
  let summary = "";

  return runJsonLines(
    { bin, args, cwd: turn.cwd, input },
    (event) => {
      const item = event.item || {};
      switch (event.type) {
        case "thread.started":
          if (event.thread_id) handlers.session(event.thread_id);
          break;
        case "item.started":
          if (item.type === "command_execution") handlers.activity("Running a command…");
          else if (item.type === "reasoning") handlers.activity("Thinking…");
          break;
        case "item.completed":
          if (item.type === "agent_message" && item.text && item.text.trim()) {
            handlers.reply(item.text.trim());
          } else if (item.type === "file_change") {
            for (const change of item.changes || []) {
              handlers.step(`${CHANGE_VERBS[change.kind] || "Change"} ${rel(change.path)}`);
            }
          } else if (item.type === "web_search") {
            handlers.step(`Search ${item.query || "the web"}`);
          } else if (item.type === "mcp_tool_call") {
            handlers.step(item.tool || "Tool call");
          }
          break;
        case "turn.completed":
          if (event.usage) summary = `${event.usage.input_tokens ?? "?"} in / ${event.usage.output_tokens ?? "?"} out tokens`;
          break;
        case "turn.failed":
          failure = (event.error && event.error.message) || "The agent's turn failed.";
          break;
        case "error":
          lastError = event.message || null;
          break;
      }
    },
    (code, stderr, spawnError) => {
      if (spawnError) {
        const hint = spawnError.code === "ENOENT" ? " (is Codex installed? set CODEX_BIN in .env)" : "";
        return handlers.finish({ error: `Couldn't start ${bin}: ${spawnError.message}${hint}` });
      }
      if (code !== 0 && /no rollout found/i.test(stderr)) return handlers.finish({ sessionMissing: true });
      if (failure) return handlers.finish({ error: failure, summary });
      if (code !== 0) {
        return handlers.finish({ error: lastError || stderr.trim() || `${bin} exited with code ${code}`, summary });
      }
      handlers.finish({ summary });
    }
  );
}

module.exports = { id: "codex", displayName: "Codex", run };
