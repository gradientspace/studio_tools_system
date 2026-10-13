# Studio Tools System

A hot-reloadable framework for building interactive tools in Roblox Studio.

The only thing installed in Studio is a small **loader plugin**. The framework itself and all the tools are Luau source files served by a local Node server. When you save a file, the server notices, and the loader swaps in the new code — no plugin reinstall or Studio restart.

Shared Luau **libraries** (e.g. [geometry3luau](https://github.com/gradientspace/geometry3luau)) are installed inside the loader plugin from their published GitHub releases, so they load once per Studio session and any tool can `require` them.

Tools come in **tool packs**: folders or separate git repos with a small manifest. The palette shows a tab per tab name the packs declare (default "Core"); several packs can share a tab, and a tool can pick its own `tab` and `section` within it. Packs are listed in `toolpacks.json`, and the server syncs and serves them. See [docs/TOOLPACKS.md](docs/TOOLPACKS.md) for the pack contract.

```
studio_plugin/StudioToolsLoader.lua   Loader plugin installed in Studio (toolbar, dock widget, HTTP, hot reload)
server/                               Dev server: bundles the framework + packs, watches for changes, syncs git packs
studio_plugin_src/                    The framework (hot-reloaded)
  SDK/                                  public, versioned API for packs: Tool base class, types, Maid, Signal
  System/                               internals: entry point, ToolManager, ToolContext, Palette UI, settings
toolpacks.json                        Tool packs everyone gets (local paths and/or git repos)
toolpacks.local.json                  Your own packs, same format (gitignored)
user_toolpacks/                       Your own pack folders, loaded without being listed (gitignored);
                                        the Tools Agent puts new tools in user_toolpacks/user
libraries.json                        Libraries bundled into the plugin, pinned to GitHub release assets
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
npm run install-plugin    # build the loader plugin (with the libraries) into Studio's local Plugins folder
npm run sync-packs        # clone/pull the git packs in toolpacks.json (missing ones are also cloned on start)
npm run sync-libraries    # download the libraries in libraries.json (check and install-plugin do this when needed)
npm run check             # syntax/type check framework, loader and packs; validate pack manifests
npm run export-sdk        # (re)generate SDK.luau in local packs
npm run new-pack -- <dir> # scaffold a new tool pack (with agent instructions) and register it (options: --name, --tab, --empty)
```

Studio output about the tool system (loads, failures, runtime errors) is forwarded to the server and written to `logs/studio-tools.log`, so it can be followed without looking at Studio. See "Checking and debugging" in [docs/TOOLPACKS.md](docs/TOOLPACKS.md).

Restart Studio, then click **GSTools** (in the GSTools group of the Plugins tab) to open the palette. The first time the plugin contacts the server, Studio asks for permission to make HTTP requests to `localhost`; allow it.

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

## Libraries

Libraries are pinned in `libraries.json` to a GitHub release asset: a `.rbxmx` model whose root is the library's ModuleScript.

```json
{ "libraries": [
  { "name": "geometry3luau", "repo": "gradientspace/geometry3luau", "tag": "v0.1.0", "asset": "geometry3luau.rbxmx" }
] }
```

- `npm run install-plugin` downloads each asset into `.libraries/` and packs it into the plugin (`StudioToolsLoader.rbxmx`) under a `Libraries` folder. Changing a library therefore means reinstalling the plugin and restarting Studio.
- On every hot reload the loader moves that folder into the new build, at `StudioTools/Libraries/<name>`. The same ModuleScripts are reused, so a library is loaded once per Studio session, not on every reload.
- Tool code requires it with `require(script:FindFirstAncestor("StudioTools").Libraries.geometry3luau)`.
- The download also extracts the library's modules into `.libraries/<name>-<tag>/src/`, which `npm run check` uses to resolve those requires (library code itself isn't checked) and coding agents can read.
- Public releases download without credentials. For a private repo, set `GITHUB_TOKEN` in `.env` or log in with `gh auth login`.

State that should survive a hot reload can be kept in `host.persist` (a plain table owned by the loader). Tool settings are persisted with `plugin:SetSetting` and survive Studio restarts.

## Local meshes

Studio doesn't save EditableMesh content with the place: a MeshPart showing an EditableMesh (e.g. one made by Bake Transform or Sculpt) is saved with an empty mesh. To keep such parts, tools make them **local meshes** with `ctx:saveLocalMesh(part)`. The part gets a mesh id (attribute `StudioToolsLocalMeshId`, tag `StudioToolsLocalMesh`), and the mesh is uploaded to the dev server, which stores it in `local_meshes/place-<placeId>/<id>.lmesh` (gitignored; set `LOCAL_MESH_DIR` in `.env` to keep it elsewhere). When the place is opened, or a tagged part with an empty mesh is pasted or inserted, the plugin downloads the mesh and puts it back.

- Saving a part again overwrites its stored mesh, as long as the id still belongs to the same EditableMesh. A part whose id belongs to a different mesh (a tool replaced it with a copy, or a duplicate was edited) gets a new id, so the original, which undo can bring back, keeps its stored mesh. Old meshes are never deleted automatically.
- The meshes live on this computer only: someone else opening the place (or Team Create) sees empty meshes. To make a mesh part of the place for good, upload it with Save As MeshPart.
- Restoring is its own undo step ("Load local meshes"), cleared from the history right after the place is opened.
- While the place has local meshes, a dark orange "N Local Meshes" chip shows in the bottom-right corner of the viewport. Its menu (the dots on its right) has **Show Boxes**, which outlines every local mesh, and **Save All As MeshParts**, which uploads each one as a Mesh asset and gives its parts the uploaded mesh (one undo step; not while a tool is active).

## Tools Agent chat in Studio

The **Tools Agent** button at the bottom-left of the viewport opens a chat box connected to a headless coding agent that the dev server runs in this repo. The agent is [Claude Code](https://claude.com/claude-code) by default, or Codex; Studio doesn't know or care which. Type a request ("make Place Block's default size 8") and press Enter.
- **What the agent does:** it edits tools and runs `npm run check`. The server then hot-reloads the change into Studio.
- **Where new tools go:** in your own pack, `user_toolpacks/user/`, which is gitignored, so they stay out of the system's repo. The agent creates the pack when it's first needed. It puts each new tool in an existing tab where one fits, or else in a tab named for the kind of work (Material, Model, Texture, ...), unless you say where it should go. It changes the framework or the built-in packs only when you ask for that explicitly.
- **System prompt:** `server/agent-instructions.md` holds the chat-specific instructions, on top of `AGENTS.md`. Claude Code gets them with `--append-system-prompt` on every message. Codex gets them as `developer_instructions` when a session starts, so after editing the file, use **New chat** for Codex to see the change.
- **Default view:** just the entry field and a one-line preview of the latest reply or current activity. **History** expands the full conversation, with a **New chat** button.
- **Stopping:** while the agent is working, **Send** becomes **Stop**, and a pulsing orange **Working...** label shows next to the Tools Agent button (**Tool called Agent...** when the agent is handling a tool's request).
- **Requests from tools:** tools can send the agent prompts with `ctx:askAgent`, e.g. to edit the place through the Roblox Studio MCP when you click something. They appear in the chat labeled with the tool's name, queue behind whatever the agent is doing, and the agent's final reply goes back to the tool. **Stop** also cancels queued requests.
- **Context:** each message resumes the same agent session, so context carries over between requests. The conversation is kept in `.chat/` (gitignored) and survives server restarts and hot reloads.
- **Choosing the agent:** copy `.env.example` to `.env` (gitignored) and set `STUDIO_AGENT=claude` or `STUDIO_AGENT=codex`, then restart the server. Switching agents starts a new agent session; the chat history stays. The CLI must be installed and signed in on the machine running the server; `CLAUDE_BIN` / `CODEX_BIN` point to it if it isn't on the `PATH`. `STUDIO_AGENT_MODEL` overrides the model.
- **Permissions:**
  - **Claude Code** follows your own Claude Code permission settings, plus it can always read, edit, and run `npm run check` / `npm run export-sdk`. Headless runs can't ask for approval, so anything your settings would prompt for is refused instead, and the chat says so. `CLAUDE_PERMISSION_MODE` overrides the mode (e.g. `acceptEdits` to restrict, `bypassPermissions` to allow everything).
  - **Codex** runs commands in its sandbox. `CODEX_SANDBOX` defaults to `workspace-write`: edit the repo and local packs, no network. `danger-full-access` allows everything.
- **If the agent can't run** (CLI not installed, wrong `*_BIN`, unknown `STUDIO_AGENT`): the server checks the CLI with `--version` at startup. When the check fails, the chat box shows "The Tools Agent isn't available" and disables input, and the reason goes to the server log and to `GET /` (`chat.detail`). The rest of the tool system works normally. A missing CLI is re-checked every 30 seconds, so installing it is enough; an unknown `STUDIO_AGENT` needs a fix in `.env` and a server restart.
- **Adding an agent:** write an adapter in `server/agents/` (the interface is described in `server/agents/index.js`) and register it there.

The server only accepts requests addressed to `localhost`, and POSTs need an `X-Studio-Tools: 1` header. That way a web page you visit can't drive the chat.

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
	local function hitTest(point: SDK.InputPoint): number?
		local part, hit = ctx:partAt(point)
		return if part and hit then hit.Distance else nil
	end
	self:addInputBehavior(SDK.HoverInputBehavior:new({
		hitTest = hitTest,
		onUpdateHover = function(point)
			self.highlight.Adornee = ctx:partAt(point)
		end,
		onEndHover = function()
			self.highlight.Adornee = nil
		end,
	}))
	self:addInputBehavior(SDK.SingleClickInputBehavior:new({
		hitTest = hitTest,
		onClick = function(point)
			local part = ctx:partAt(point)
			if part then
				ctx:recordUndo("My Tool", function()
					part.Color = ctx.settings.color
				end)
			end
		end,
	}))
end

return MyTool
```

Tools never listen to the mouse directly. They add **input behaviors**, and the system's InputManager routes mouse input to them: it decides which behavior captures the mouse (nearest hit wins), runs hover, and ends captures when the tool exits or Studio loses focus. The SDK provides standard behaviors: `SingleClickInputBehavior`, `ClickDragInputBehavior`, `ClickOrDragInputBehavior` and `HoverInputBehavior`. Custom ones extend `SDK.InputBehavior`. See "Input" in docs/TOOLPACKS.md.

While a tool is active, the system shows a **shutdown overlay** at the bottom of the viewport: a Done button by default, or Accept/Cancel. Tools configure it with a `shutdown` field, and `deactivate(ctx, reason)` receives the button the user clicked, or `Force` (see docs/TOOLPACKS.md).

Tools can extend other tool classes (`Base:extend({...})`, overriding methods and calling `Base.method(self, ...)`). In the core pack, Paint, Erase and Move all build on `Shared/PartPickerTool`. The full contract, including inheritance, settings, manifest and versioning rules, is in [docs/TOOLPACKS.md](docs/TOOLPACKS.md).

### ToolContext API

| Member | Description |
| --- | --- |
| `ctx.settings` | Live table of the tool's setting values |
| `ctx.toolId` | Qualified id, `"<packId>/<toolId>"` |
| `ctx.state` | Scratch table for the tool |
| `ctx.plugin` | The `Plugin` |
| `ctx:inputBehaviorsChanged()` | Tell the system the tool's `getInputBehaviors()` changed (`self:addInputBehavior` / `removeInputBehavior` do this) |
| `ctx:refreshInput()` | Re-run hover and capture at the current mouse position (automatic after undo/redo, setting edits and camera moves) |
| `ctx:isKeyDown(...KeyCode)`, `ctx:isShiftDown()` | Modifier/key state |
| `ctx:onKey(fn(input, isDown))` | Keyboard input in the viewport |
| `ctx:onSettingChanged(fn(key, value))` | A setting changed (edited in the palette, or `ctx:setSetting`) |
| `ctx:setSetting(key, value)` | Change one of the tool's settings as if the user had (e.g. a keyboard shortcut for brush size) |
| `ctx:onUndoRedo(fn(action, waypointName))` | User undid/redid while the tool is active; resync any state about the place |
| `ctx:raycastAt(point, maxDistance?, exclude?)` | Raycast along an `InputPoint`'s ray (input behaviors pass points to their callbacks) |
| `ctx:partAt(point)` | Unlocked, non-terrain `BasePart` at the point, plus the `RaycastResult` |
| `ctx:excludeFromRaycast(instance)` | Ignore an instance in `raycastAt` and `partAt` |
| `ctx:createBoxPreview()` | `BoxHandleAdornment` in world space (CoreGui; never saved, no undo) |
| `ctx:createHighlight(color?)` | `SelectionBox` in CoreGui; set `.Adornee` |
| `ctx:createAdornment(className)` | Any `HandleAdornment` (`"LineHandleAdornment"`, `"SphereHandleAdornment"`, ...) in world space (CoreGui; never saved, no undo) |
| `ctx:focusView(cframe, size)` | Animate the camera to frame a box, keeping the view direction; the box center becomes the orbit point |
| `ctx:centerView(point)` | Animate a pan (no rotation or zoom) that puts a world point at the view center; it becomes the orbit point |
| `ctx:autoCameraSpeed(size)` | Set Studio's camera fly/wheel speeds to suit an object of this size; the user's speeds are restored when the tool exits |
| `ctx:createTemporaryModel(name?)` | A non-archivable `Model` in the Workspace for temporary 3D content (never saved, copied or in undo history; parts locked and ignored by `raycastAt`) |
| `ctx:recordUndo(name, fn, ...)` | Run `fn` as one undo waypoint (cancelled if it errors) |
| `ctx:beginUndo(name)` | Open a waypoint across multiple events; returns `{ commit, cancel }` |
| `ctx:addUndoStep(name, undo, redo)` | A Studio undo waypoint for a change to the tool's own state (not the place); Ctrl+Z/Ctrl+Y call `undo`/`redo` while the tool is active |
| `ctx:confirm({ title?, message, confirmText?, cancelText? })` | Modal confirmation dialog in the viewport; yields, returns true/false |
| `ctx:alert({ title?, message, buttonText? })` | Modal message (e.g. an error) with one button; yields until dismissed |
| `ctx:showProgress({ title?, message })` | Modal progress dialog while the tool works (e.g. an upload on Accept); returns a handle with `:setMessage(text)` and `:close()` |
| `ctx:refreshShutdownButtons()` | Re-query `canAccept()` now (Accept/Cancel tools) |
| `ctx:setStatus(text?)` | Status line under the tool's name in the palette (nil hides it) |
| `ctx:setSettingState(key, { visible?, enabled?, label?, tooltip? })` | Show/hide, enable/disable, relabel or change the tooltip of one setting's widget (any type, including `"button"` actions, which call the tool's `onAction(key)`) |
| `ctx:createViewportPanel({ position? }?)` | A system-styled Frame in the viewport (`"Top"`, `"TopLeft"`, `"TopRight"`) for UI that doesn't fit the settings panel; clicks on it don't reach the tool. Style its contents with `SDK.ViewportStyle` |
| `ctx:askAgent(prompt, { cancelOnDeactivate? }?)` | Send a prompt to the Tools Agent, which can edit the place through the Roblox Studio MCP. Returns an `AgentRequest` right away: `:await()` (yields), `:onFinished(fn)`, `:cancel()`, `.status`. See "Tools Agent requests" in docs/TOOLPACKS.md |
| `ctx:connect(signal, fn)`, `ctx:addCleanup(task)` | Auto-cleaned on deactivate |
| `ctx:saveLocalMesh(part)` | Store an EditableMesh-backed MeshPart's mesh on the dev server so it survives saving the place (see Local meshes); call inside the undo recording that made the part. Returns its mesh id |
| `ctx:clearLocalMesh(part)` | Stop treating a part as a local mesh (e.g. it now uses an uploaded asset) |
| `ctx:uploadMesh(part, { name, description?, onStatus? })` | Upload a MeshPart's mesh as a new Mesh asset and load it back as an unparented MeshPart for `ApplyMesh` (yields; needs the Studio beta "CreateAssetAsync Luau API") |
| `ctx:log(...)` | Prefixed print |

## Core pack tools

- **Place Block** — click a surface to place a cube against it; grid snapping, size, color, material.
- **Paint** — click or drag across parts to recolor them (optionally set material). An Accept/Cancel tool: Accept is disabled until something is painted, and Cancel asks for confirmation and then reverts the whole session.
- **QuickMove** — drag a part to slide it in XZ; hold Shift to move it vertically. Optional snap increment.
- **Erase** — click to delete; by default only blocks created by Place Block.
- **Sculpt** (Model tab) — brush sculpting of the selected MeshPart: Clay, Draw, Flatten, Smooth, Inflate, Pinch, Crease and Grab brushes, with strength, screen- or world-space size, falloff curves, spacing, X/Y/Z mirroring and front-faces-only. Ctrl/Cmd inverts, Shift smooths, `[` / `]` resize, F frames the mesh and Shift+F the brush area, C centers the view on the point under the cursor, and every stroke is a Studio undo step. Shown textured, untextured or flat shaded. An Accept/Cancel tool: Apply writes the sculpt into the part in place (one undo step; the part keeps its pivot, attachments and welds, and is moved and resized only as much as its new bounds need), making it a local mesh that can be sculpted again, until Save As MeshPart uploads it.
- **Bake Transform** (Model tab) — bakes the rotation and/or scale of the selected MeshParts into their meshes, and optionally moves their pivots to the center or base. Shows each part's new bounding box and pivot while active; Bake replaces each part with a copy using the baked mesh (an EditableMesh) in one undo step, keeping properties and children and repointing welds and constraints. Meshes the user can't edit are skipped.
- **Save As MeshPart** (Model tab) — uploads the selected MeshPart's mesh as a new Mesh asset in your inventory (e.g. to make a baked, in-memory EditableMesh permanent), then either gives the part the uploaded mesh (Replace Input) or adds a copy that uses it. Errors are shown in a dialog.
- **Remesh** (Model tab) — rebuilds the selected MeshPart's mesh with evenly sized triangles (geometry3luau Remesher), aiming for a target triangle count up to 20,000 (Reducer simplifies anything over that). Re-runs in the background as the settings change, previews the result with a wireframe, and shows the resulting triangle count. Apply gives the part the new mesh in place, as a local mesh. UVs aren't kept.
