# Agent guide: {{PACK_NAME}} (Studio Tools pack `{{PACK_ID}}`)

This repo is a **tool pack** for the Studio Tools system: interactive tools for Roblox Studio, written in Luau. The tools run inside the Studio Tools framework, which lives in a separate repo, **studio_tools_system**. That repo's dev server serves this pack to Studio and hot-reloads it whenever files change.

Below, `$STUDIO_TOOLS` means the user's studio_tools_system checkout. Where it lives is up to each user, so find it, in this order:
1. Ask the dev server (it has to be running for hot reload anyway): `curl -s http://localhost:34873/` returns JSON with `repoRoot` (the checkout) and `logFile`. The port can differ if the user changed it.
2. The `STUDIO_TOOLS_DIR` environment variable, if set.
3. Otherwise, ask the user.

Don't write the path into files in this repo.

You can't see or operate Studio. Your feedback comes from `npm run check` (static) and `$STUDIO_TOOLS/logs/studio-tools.log` (what actually happened in Studio).

## Layout

```
toolpack.json      manifest: id, name, version, apiVersion, source
src/
  SDK.luau         GENERATED; never edit. Types for the SDK and ToolContext: read it for the API.
  Tools/           every module directly in here is a tool (a folder with init.luau also counts)
  ...              anything else (Shared/ helpers, base classes) under any name
```

The full contract is in `$STUDIO_TOOLS/docs/TOOLPACKS.md`. Read it before writing tools. The tools in `$STUDIO_TOOLS/toolpacks/core/src/` are working examples, including inheritance via a base class.

## Writing tools

- A tool module returns a class made with `SDK.Tool:extend({ apiVersion = {{API_VERSION}}, id = ..., name = ..., ... })` and overrides `activate(ctx)`.
- Require the SDK with `local SDK = require(script.Parent.Parent.SDK)` and annotate `ctx: SDK.ToolContext` so calls on `ctx` are type checked.
- Every tool declares `apiVersion` explicitly.
- Take mouse input through input behaviors (`self:addInputBehavior(SDK.SingleClickInputBehavior:new({...}))`, `ClickDragInputBehavior`, `ClickOrDragInputBehavior`, `HoverInputBehavior`), not mouse events. Behavior callbacks must not yield; use `task.spawn` for slow work.
- Connect and create through `ctx` (`ctx:createHighlight`, `ctx:connect`, ...) so everything is cleaned up on deactivate.
- Give tools their controls through the settings panel: values as `settings`, actions as `type = "button"` settings handled in `onAction(key)`, progress with `ctx:setStatus(text)`, and `ctx:setSettingState(key, { visible, enabled, label, tooltip })` to change widgets as the tool runs. Every setting can have a `tooltip`. Only UI that truly needs the viewport goes in a panel from `ctx:createViewportPanel()`; never create your own ScreenGui. See "Settings" and "Viewport panels" in `docs/TOOLPACKS.md`.
- Put changes to the place inside `ctx:recordUndo` / `ctx:beginUndo`.
- No side effects at module load: every module is required to validate the pack.
- Only require things inside this pack, plus the SDK.

## Work loop

This pack must be listed in the user's pack config, normally `$STUDIO_TOOLS/toolpacks.local.json` (`npm run new-pack` adds it there). Use a `path` entry while developing; a `git` entry only picks up pushed commits after `npm run sync-packs`.

1. Edit files here.
2. `npm --prefix "$STUDIO_TOOLS" run check`. Fix every error, and the warnings for this pack. It checks this pack's manifest and layout, Luau syntax and types, and whether `SDK.luau` is up to date.
3. If the dev server is running (`npm start` in `$STUDIO_TOOLS`, usually in the user's terminal), saving is enough: Studio reloads within a second or two. The reload waits while a tool is active in Studio.
4. Read the tail of `$STUDIO_TOOLS/logs/studio-tools.log`:
   - `Loaded build N`: your change is live.
   - `Tool pack '{{PACK_ID}}' failed to load`: this pack's tools are omitted. The engine's error, e.g. `StudioTools.Packs.{{PACK_ID}}.Tools.MyTool:42: ...`, appears nearby. That path maps to `src/Tools/MyTool.luau` line 42.
   - `Tool module X is invalid: ...` / `failed to activate` / runtime errors with stack traces: problems found in Studio.
5. Interactive behavior only runs when a person uses the tool in Studio. When that matters, say what you couldn't verify and ask the user to try it; any errors will show up in the log.

If the SDK changes (check reports `SDK.luau is outdated`), run `npm --prefix "$STUDIO_TOOLS" run export-sdk -- "$PWD"` and commit the result.

## Style

Tabs for indentation. Match the surrounding code. Keep tools small; put shared logic in `src/Shared/` or a base class.
