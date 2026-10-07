# Studio Tools System

A hot-reloadable framework for building interactive tools in Roblox Studio.

The only thing installed in Studio is a small **loader plugin**. The framework itself and all the tools are Luau source files served by a local Node server. When you save a file, the server notices, and the loader swaps in the new code — no plugin reinstall or Studio restart.

Tools come in **tool packs**: folders or separate git repos with a small manifest. The palette shows a tab per tab name the packs declare (default "Core"); several packs can share a tab. Packs are listed in `toolpacks.json`, and the server syncs and serves them. See [docs/TOOLPACKS.md](docs/TOOLPACKS.md) for the pack contract.

```
studio_plugin/StudioToolsLoader.lua   Loader plugin installed in Studio (toolbar, dock widget, HTTP, hot reload)
server/                               Dev server: bundles the framework + packs, watches for changes, syncs git packs
studio_plugin_src/                    The framework (hot-reloaded)
  SDK/                                  public, versioned API for packs: Tool base class, types, Maid, Signal
  System/                               internals: entry point, ToolManager, ToolContext, Palette UI, settings
toolpacks.json                        Tool packs everyone gets (local paths and/or git repos)
toolpacks.local.json                  Your own packs, same format (gitignored)
toolpacks/core/                       Built-in pack; reference for writing your own
  toolpack.json                         pack manifest
  src/SDK.luau                          generated SDK types + forwarder (npm run export-sdk)
  src/Tools/                            PlaceBlock, PaintBlock, MoveBlock, EraseBlock
  src/Shared/                           Blocks helpers, PartPickerTool base class
docs/TOOLPACKS.md                     Tool pack contract
templates/toolpack/                   Template used by npm run new-pack
AGENTS.md, CLAUDE.md                  Instructions for coding agents working in this repo
```

## Setup

Requires Node 20+.

```sh
npm start                 # run the dev server on http://localhost:34873
npm run install-plugin    # copy the loader into Studio's local Plugins folder
npm run sync-packs        # clone/pull the git packs in toolpacks.json (missing ones are also cloned on start)
npm run check             # syntax/type check framework, loader and packs; validate pack manifests
npm run export-sdk        # (re)generate SDK.luau in local packs
npm run new-pack -- <dir> # scaffold a new tool pack (with agent instructions) and register it
```

Studio output about the tool system (loads, failures, runtime errors) is forwarded to the server and written to `logs/studio-tools.log`, so it can be followed without looking at Studio. See "Checking and debugging" in [docs/TOOLPACKS.md](docs/TOOLPACKS.md).

Restart Studio, then click **GS-STS** (in the Studio Tools group of the Plugins tab) to open the palette. The first time the plugin contacts the server, Studio asks for permission to make HTTP requests to `localhost`; allow it.

The server URL can be changed with the `StudioToolsSystem.ServerUrl` plugin setting. The server port can be changed with `PORT=... npm start`.

## How hot reload works

1. The loader long-polls `GET /poll?since=<hash>`; the server answers when the framework, any pack, or `toolpacks.json` changes.
2. The loader fetches `GET /bundle` (every `.lua`/`.luau` file in `studio_plugin_src/`, plus each pack's source under `Packs/<packId>/`, plus the pack manifests), and builds a ModuleScript tree mirroring the folder layout (Rojo-style: a folder containing `init.luau` becomes a ModuleScript). The tree is parented to `nil`, so it never touches the place.
3. **If a tool is active, the reload waits** until it's deactivated.
4. Every module in the new tree is `require`d up front. If a framework module (`System`, `SDK`) fails (syntax error, runtime error at load), the new build is discarded, the error is logged, and the current system keeps running. Each tool pack is then checked on its own: a pack with a failing module is dropped from the build (its tools are omitted and the palette marks it as failed) while everything else reloads.
5. The old system's `stop()` is called and the new `System.start(host, root)` runs. If `start` errors, the old system is restarted.
6. The last good build is cached in plugin settings, so tools still load when the server isn't running.

The status bar at the bottom of the palette shows the connection state and the current build. The gear button at its right end opens a menu; **Reload Tools** there forces a re-fetch and reload even if nothing changed.

Because every module is required during validation, **modules should not have side effects at require time** — do work in `activate` / `start`, not at the top level.

State that should survive a hot reload can be kept in `host.persist` (a plain table owned by the loader). Tool settings are persisted with `plugin:SetSetting` and survive Studio restarts.

## Writing a tool

Tools are classes derived from `SDK.Tool`, living in a pack's `Tools/` folder:

```lua
local SDK = require(script.Parent.Parent.SDK)  -- the pack's generated SDK.luau

local MyTool = SDK.Tool:extend({
	apiVersion = 1,             -- Studio Tools API this was written against
	id = "MyTool",              -- stable, unique within the pack
	name = "My Tool",           -- palette label
	version = "1.0.0",
	description = "What it does.",
	order = 40,                 -- palette sort order
	settings = {
		{ key = "size", label = "Size", type = "number", default = 4, min = 1, max = 32, step = 1 },
		{ key = "enabled", label = "Enabled", type = "boolean", default = true },
		{ key = "color", label = "Color", type = "color", default = Color3.new(1, 0, 0) },
		{ key = "mode", label = "Mode", type = "enum", options = { "A", "B" }, default = "A" },
	},
})

-- `self` is a fresh instance per activation; `self.ctx` is the ToolContext.
function MyTool:activate(ctx: SDK.ToolContext)
	self.highlight = ctx:createHighlight()
	ctx:onMouseMove(function()
		self.highlight.Adornee = ctx:partUnderMouse()
	end)
	ctx:onMouseDown(function()
		local part = ctx:partUnderMouse()
		if part then
			ctx:recordUndo("My Tool", function()
				part.Color = ctx.settings.color
			end)
		end
	end)
end

return MyTool
```

While a tool is active, the system shows a **shutdown overlay** at the bottom of the viewport: a Done button by default, or Accept/Cancel. Tools configure it with a `shutdown` field, and `deactivate(ctx, reason)` receives the button the user clicked, or `Force` (see docs/TOOLPACKS.md).

Tools can extend other tool classes (`Base:extend({...})`, overriding methods and calling `Base.method(self, ...)`). In the core pack, Paint, Erase and Move all build on `Shared/PartPickerTool`. The full contract, including inheritance, settings, manifest and versioning rules, is in [docs/TOOLPACKS.md](docs/TOOLPACKS.md).

### ToolContext API

| Member | Description |
| --- | --- |
| `ctx.settings` | Live table of the tool's setting values |
| `ctx.toolId` | Qualified id, `"<packId>/<toolId>"` |
| `ctx.state` | Scratch table for the tool |
| `ctx.plugin`, `ctx.mouse` | The `Plugin` and `PluginMouse` |
| `ctx:onMouseMove(fn)`, `onMouseDown(fn)`, `onMouseUp(fn)` | Viewport mouse input (left button); `onMouseDown` skips clicks on the shutdown overlay |
| `ctx:isKeyDown(...KeyCode)`, `ctx:isShiftDown()` | Modifier/key state |
| `ctx:onKey(fn(input, isDown))` | Keyboard input in the viewport |
| `ctx:onSettingChanged(fn(key, value))` | User edited a setting in the palette |
| `ctx:onUndoRedo(fn(action, waypointName))` | User undid/redid while the tool is active; resync any state about the place |
| `ctx:raycast(maxDistance?, exclude?)` | Raycast from the camera through the cursor |
| `ctx:partUnderMouse()` | Unlocked, non-terrain `BasePart` under the cursor, plus the `RaycastResult` |
| `ctx:excludeFromRaycast(instance)` | Ignore an instance in `raycast` |
| `ctx:createBoxPreview()` | `BoxHandleAdornment` in world space (CoreGui; never saved, no undo) |
| `ctx:createHighlight(color?)` | `SelectionBox` in CoreGui; set `.Adornee` |
| `ctx:recordUndo(name, fn, ...)` | Run `fn` as one undo waypoint (cancelled if it errors) |
| `ctx:beginUndo(name)` | Open a waypoint across multiple events; returns `{ commit, cancel }` |
| `ctx:confirm({ title?, message, confirmText?, cancelText? })` | Modal confirmation dialog in the viewport; yields, returns true/false |
| `ctx:refreshShutdownButtons()` | Re-query `canAccept()` now (Accept/Cancel tools) |
| `ctx:connect(signal, fn)`, `ctx:addCleanup(task)` | Auto-cleaned on deactivate |
| `ctx:log(...)` | Prefixed print |

## Core pack tools

- **Place Block** — click a surface to place a cube against it; grid snapping, size, color, material.
- **Paint** — click or drag across parts to recolor them (optionally set material). An Accept/Cancel tool: Accept is disabled until something is painted, and Cancel asks for confirmation and then reverts the whole session.
- **Move** — drag a part to slide it in XZ; hold Shift to move it vertically. Optional snap increment.
- **Erase** — click to delete; by default only blocks created by Place Block.
