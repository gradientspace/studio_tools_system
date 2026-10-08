// Claude Code adapter: `claude -p --output-format stream-json`, resuming with
// --resume <session id>.
//
// Permissions follow the user's own Claude Code settings, plus allow rules
// for reading, editing and `npm run check` / `export-sdk` / `new-pack` so
// the core edit/check loop always works. The chat instructions are passed
// with --append-system-prompt on every turn. CLAUDE_PERMISSION_MODE overrides the
// mode (e.g. "acceptEdits" to restrict, "bypassPermissions" for everything).

const path = require("node:path");
const { runJsonLines } = require("./process");

const ALLOWED_TOOLS = [
  "Read",
  "Edit",
  "Write",
  "Glob",
  "Grep",
  "Bash(npm run check)",
  "Bash(npm run check:*)",
  "Bash(npm run export-sdk)",
  "Bash(npm run export-sdk:*)",
  "Bash(npm run new-pack:*)",
];

function describeToolUse(block, cwd) {
  const input = block.input || {};
  const rel = (file) => {
    if (typeof file !== "string") return "";
    const r = path.relative(cwd, file);
    return r.startsWith("..") ? file : r;
  };
  switch (block.name) {
    case "Read":
    case "Edit":
    case "Write":
      return `${block.name} ${rel(input.file_path)}`;
    case "Glob":
    case "Grep":
      return `${block.name} ${input.pattern || ""}`;
    default:
      return block.name;
  }
}

function binPath() {
  return process.env.CLAUDE_BIN || "claude";
}

function run(turn, handlers) {
  const bin = binPath();
  const args = ["-p", "--output-format", "stream-json", "--verbose", "--append-system-prompt", turn.instructions];
  args.push("--allowedTools", ...ALLOWED_TOOLS);
  if (process.env.CLAUDE_PERMISSION_MODE) args.push("--permission-mode", process.env.CLAUDE_PERMISSION_MODE);
  if (process.env.STUDIO_AGENT_MODEL) args.push("--model", process.env.STUDIO_AGENT_MODEL);
  for (const dir of turn.extraDirs) args.push("--add-dir", dir);
  if (turn.sessionId) args.push("--resume", turn.sessionId);

  let resultError = null;
  let gotResult = false;
  let replied = false;
  let summary = "";

  return runJsonLines(
    { bin, args, cwd: turn.cwd, input: turn.message },
    (event) => {
      if (event.type === "system" && event.subtype === "init" && event.session_id) {
        handlers.session(event.session_id);
      } else if (event.type === "assistant" && event.message && Array.isArray(event.message.content)) {
        for (const block of event.message.content) {
          if (block.type === "text" && block.text && block.text.trim()) {
            replied = true;
            handlers.reply(block.text.trim());
          } else if (block.type === "tool_use") {
            // Commands only show as activity, not as chat history steps.
            if (block.name === "Bash") handlers.activity("Running a command…");
            else handlers.step(describeToolUse(block, turn.cwd));
          }
        }
      } else if (event.type === "result") {
        gotResult = true;
        if (event.session_id) handlers.session(event.session_id);
        if (event.is_error) {
          resultError = event.result || `The agent stopped with an error (${event.subtype || "unknown"}).`;
        } else if (!replied && event.result) {
          handlers.reply(event.result);
        }
        const refused = (event.permission_denials || []).map(
          (d) => d.tool_name + (d.tool_input && d.tool_input.command ? `: ${d.tool_input.command}` : "")
        );
        if (refused.length > 0) handlers.refused([...new Set(refused)]);
        const cost = typeof event.total_cost_usd === "number" ? `, $${event.total_cost_usd.toFixed(3)}` : "";
        summary = `${event.num_turns ?? "?"} steps${cost}`;
      }
    },
    (code, stderr, spawnError) => {
      if (spawnError) return handlers.finish({ unavailable: `Couldn't start ${bin}: ${spawnError.message}` });
      if (code !== 0 && /No conversation found/.test(stderr)) return handlers.finish({ sessionMissing: true });
      if (resultError) return handlers.finish({ error: resultError, summary });
      if (code !== 0 && !gotResult) return handlers.finish({ error: stderr.trim() || `${bin} exited with code ${code}` });
      handlers.finish({ summary });
    }
  );
}

module.exports = {
  id: "claude",
  displayName: "Claude Code",
  setupHint: "Install Claude Code, or set CLAUDE_BIN in .env if it isn't on the server's PATH.",
  bin: binPath,
  run,
};
