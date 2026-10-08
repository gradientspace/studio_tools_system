// Shared helper for agent adapters: runs a CLI that prints JSON Lines on
// stdout, feeding it the prompt on stdin.

const { spawn } = require("node:child_process");

// onEvent(object) per JSON line; onExit(code, stderr, spawnError) once.
// Returns { stop }.
function runJsonLines({ bin, args, cwd, input }, onEvent, onExit) {
  const child = spawn(bin, args, { cwd, stdio: ["pipe", "pipe", "pipe"] });
  let buffer = "";
  let stderr = "";
  let exited = false;
  const exit = (code, error) => {
    if (exited) return;
    exited = true;
    onExit(code, stderr, error);
  };

  child.stdout.on("data", (chunk) => {
    buffer += chunk.toString("utf8");
    let newline;
    while ((newline = buffer.indexOf("\n")) !== -1) {
      const line = buffer.slice(0, newline).trim();
      buffer = buffer.slice(newline + 1);
      if (!line) continue;
      let event;
      try {
        event = JSON.parse(line);
      } catch {
        continue; // ignore non-JSON lines
      }
      onEvent(event);
    }
  });
  child.stderr.on("data", (chunk) => {
    stderr += chunk.toString("utf8");
  });
  child.on("error", (err) => exit(null, err));
  child.on("close", (code) => exit(code, null));
  child.stdin.on("error", () => {}); // process may exit before reading stdin
  child.stdin.end(input);

  return {
    stop() {
      child.kill("SIGTERM");
    },
  };
}

module.exports = { runJsonLines };
