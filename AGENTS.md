# Agent guide: studio_tools_system

A hot-reloadable framework for interactive tools in Roblox Studio. A small loader plugin in Studio fetches the framework and the tool packs from a local Node server as Luau source and hot-reloads them whenever files change.

You can't see or operate Studio. Your feedback comes from `npm run check` (static) and `logs/studio-tools.log` (what actually happened in Studio).

## Layout

| Path | What | Changes reach Studio by |
| --- | --- | --- |
| `studio_plugin_src/SDK/` | Public, versioned API for tool packs (`Tool` base class, `Types.luau`, `Maid`, `Signal`) | hot reload |
| `studio_plugin_src/System/` | Framework internals: entry point, `ToolManager`, `ToolContext`, `Palette` UI, settings | hot reload |
| `toolpacks/core/` | Built-in tool pack; the reference for how packs are written | hot reload |
| `toolpacks.json` | Packs everyone gets (committed) | hot reload |
| `toolpacks.local.json` | The user's own packs (gitignored; machine-specific paths go here, never in committed files) | hot reload |
| `user_toolpacks/` | The user's own pack folders (gitignored), loaded without being listed. The Tools Agent puts new tools in `user_toolpacks/user` | hot reload |
| `studio_plugin/StudioToolsLoader.lua` | The loader plugin installed in Studio | **reinstall + Studio restart** |
| `libraries.json` | Libraries packed into the plugin (e.g. geometry3luau), pinned to GitHub release assets. Code requires them as `script:FindFirstAncestor("StudioTools").Libraries.<name>` | **reinstall + Studio restart** |
| `server/` | Dev server, pack syncing, tree/sourcemap building, SDK generation, Tools Agent chat (`chat.js`, agent adapters in `agents/`, system prompt in `agent-instructions.md`) | **server restart** (except `agent-instructions.md`, read on every message) |
| `.env` | Server settings, e.g. which agent powers the chat (gitignored; see `.env.example`) | **server restart** |
| `scripts/` | `check`, `export-sdk`, `new-pack`, `sync-packs`, `sync-libraries`, `install-plugin` | (run directly) |
| `templates/toolpack/` | Template copied by `npm run new-pack` | — |
| `docs/TOOLPACKS.md` | The tool pack contract. Read it before changing packs or the SDK. | — |

Generated or managed, never edit by hand: `toolpacks/*/src/SDK.luau` (use `npm run export-sdk`), `.toolpacks/` (git pack cache), `.tools/` (luau-lsp), `.libraries/` (downloaded libraries; read `.libraries/<name>-<tag>/src/` for a library's source, but change it in the library's own repo), `logs/`, `.chat/` (Studio chat conversation).

You may be running headless from the Studio "Tools Agent" chat box (`server/chat.js`), as Claude Code or Codex. In that case you also get the instructions in `server/agent-instructions.md`: the user sees only your text replies, nobody can approve permission prompts (actions that need approval are refused), and new tools go in `user_toolpacks/user/`.

## Commands

```sh
npm start                    # dev server (usually already running in the user's terminal; don't start a second one on the same port)
npm run check                # REQUIRED after every Luau or pack change; exit code 1 = errors
npm run export-sdk           # regenerate SDK.luau in local packs after changing SDK/Types.luau
npm run new-pack -- <dir>    # scaffold a new tool pack and register it in toolpacks.local.json (not needed in user_toolpacks/); --name, --tab, --empty
npm run sync-packs           # pull git packs
npm run sync-libraries       # download the libraries in libraries.json into .libraries/
npm run install-plugin       # build the loader plugin, with the libraries, into Studio's Plugins folder (after changing the loader or libraries.json)
```

## Work loop

1. Make the change.
2. Run `npm run check` and fix every error. Treat warnings as things to fix unless there's a reason not to.
3. If the dev server is running, saving is enough: Studio reloads within a second or two. The reload waits while a tool is active in Studio.
4. Read the tail of `logs/studio-tools.log`.
   - `[studio build N output] [StudioTools] Loaded build N (...)`: the change is live.
   - `Build N failed to load; keeping the previous system`: the framework (System/SDK) is broken. Nothing new loaded.
   - `Tool pack '<id>' failed to load`: that pack's tools are omitted. The engine's error line, e.g. `StudioTools.Packs.<id>.Tools.X:42: ...`, appears nearby.
   - `Tool module X is invalid: ...` / `failed to activate`: contract or runtime problems found in Studio.
   - The module path `StudioTools.Packs.core.Tools.PlaceBlock:42` maps to `toolpacks/core/src/Tools/PlaceBlock.luau` line 42. `StudioTools.System.X` maps to `studio_plugin_src/System/X.luau`.
5. Interactive behavior (clicking in the viewport, dragging) only runs when a person uses the tool in Studio. When that matters, say what you couldn't verify and ask the user to try it. Any errors they hit will show up in the log.

If the log shows nothing new after a save, the server may not be running, or Studio may be closed or in play mode. Say so rather than assuming the change worked.

## Rules

- **No side effects at module load.** Every module is required during validation. Do work in `activate` / `start`, not at the top level.
- **Tools use `ctx` for cleanup and undo.** Connect and create through `ctx` (`ctx:connect`, `ctx:onMouseDown`, `ctx:createHighlight`, ...) so deactivation cleans up. Put changes to the place inside `ctx:recordUndo` / `ctx:beginUndo`.
- **Pack code uses only the SDK.** Packs require `script.Parent.Parent.SDK` (their generated `SDK.luau`), never `StudioTools.System`.
- **The SDK is a versioned contract** (see Versioning in `docs/TOOLPACKS.md`).
  - Adding to `ToolContext` or the SDK is fine. Update `SDK/Types.luau` to match, then run `npm run export-sdk`.
  - Removing, renaming or changing behavior is breaking. Bump `API_VERSION` in `SDK/init.luau`, and either keep old versions working or raise `MIN_API_VERSION`. Ask the user before making a breaking change.
  - `SDK/Types.luau` must stay self-contained (no requires); it's copied into every pack.
- **The loader must stay robust.** It's the only code that can't hot-reload, and a bug there means reinstalling and restarting Studio. Keep it minimal. After changing it, run `npm run install-plugin` and tell the user to restart Studio.
- **Server changes need a restart.** Tell the user to restart `npm start`.
- **Hot reload must stay safe.** A broken framework build must leave the previous one running, and a broken pack must only drop that pack.
- **Style:** match the surrounding code. Tabs in Luau, 2 spaces in JS/JSON, Luau type annotations on public functions. Files use Luau's default lenient type checking; only add `--!strict` if you're prepared to fully type the file.
- **Node:** no npm dependencies (only Node built-ins, Node 20+).
