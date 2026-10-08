--[[
	ToolManager: loads tools from the tool packs, and handles activating and
	deactivating them and editing their settings.

	Packs arrive as root.Packs.<packId> folders, with their manifests in
	host.build.packs (in the order listed in toolpacks.json). Every
	ModuleScript directly under a pack's Tools folder must return a tool
	class created with SDK.Tool:extend (see SDK/Tool.luau and
	docs/TOOLPACKS.md). Classes with `abstract = true` are skipped.

	Packs are grouped into palette tabs by their manifest's `tab` (default
	"Core"). Tabs are created in order of the first pack that names them, so
	several packs can share a tab. Packs the loader couldn't load
	(host.build.failedPacks) are recorded in their tab so the palette can
	show them, and otherwise skipped.

	Tools are tracked as entries:
	  { id = "<packId>/<toolId>", pack = PackManifest, definition = class }

	While a tool is active, the ViewportOverlay shows the shutdown buttons
	the tool asked for (instance:getShutdownOptions()). Every deactivation
	carries a reason that is passed on to the tool's deactivate(ctx, reason):
	the button the user clicked, or Force for anything else (switching tools,
	Studio taking over the viewport, the plugin unloading, activation failing).

	Clicking a shutdown button, or pressing Escape (= Done, or Cancel for
	Accept/Cancel tools), is a shutdown *request*: the tool's
	confirmShutdown(reason, trigger) runs first and may refuse. For
	Accept/Cancel tools, canAccept() is polled to enable/disable Accept.
]]

local UserInputService = game:GetService("UserInputService")

local SDK = require(script.Parent.Parent.SDK)
local SettingsStore = require(script.Parent.SettingsStore)
local ViewportOverlay = require(script.Parent.ViewportOverlay)
local ToolContext = require(script.Parent.ToolContext)

local Maid = SDK.Maid
local Signal = SDK.Signal

local ToolManager = {}
ToolManager.__index = ToolManager

local Reason = SDK.ShutdownReason
local Trigger = SDK.ShutdownTrigger

local ACCEPT_POLL_INTERVAL = 0.1
local DEFAULT_TAB = "Core"

-- Turns a tool's shutdown options into overlay buttons, filling in defaults.
-- Also returns the reason the Escape key maps to.
local function shutdownButtons(entry: any, options: any): ({ ViewportOverlay.Button }, string)
	local name = entry.definition.name
	local function button(reason: string, config: any, defaultTooltip: string): ViewportOverlay.Button
		config = if type(config) == "table" then config else {}
		return {
			reason = reason,
			text = if type(config.text) == "string" then config.text else reason,
			tooltip = if type(config.tooltip) == "string" then config.tooltip else defaultTooltip,
		}
	end

	local shutdownType = options.type or SDK.ShutdownType.Done
	if shutdownType == SDK.ShutdownType.AcceptCancel then
		local buttons = {
			button(Reason.Accept, options.accept, "Keep the changes and exit " .. name),
			button(Reason.Cancel, options.cancel, "Discard the changes and exit " .. name .. " (Esc)"),
		}
		return buttons, Reason.Cancel
	end
	if shutdownType ~= SDK.ShutdownType.Done then
		warn(string.format("[StudioTools] Tool '%s' has unknown shutdown type '%s'; using Done", entry.id, tostring(shutdownType)))
	end
	return { button(Reason.Done, options.done, "Exit " .. name .. " (Esc)") }, Reason.Done
end

local function supportedRange(): string
	if SDK.MIN_API_VERSION == SDK.API_VERSION then
		return tostring(SDK.API_VERSION)
	end
	return string.format("%d-%d", SDK.MIN_API_VERSION, SDK.API_VERSION)
end

local function validateDefinition(definition: any): (boolean, string?)
	if not SDK.Tool.isSubclass(definition) then
		return false, "module must return a tool class created with SDK.Tool:extend({...})"
	end
	if type(definition.apiVersion) ~= "number" then
		return false, "missing number field 'apiVersion'"
	end
	if not SDK.isApiVersionSupported(definition.apiVersion) then
		return false,
			string.format(
				"written for API version %s, but this Studio Tools build supports %s",
				tostring(definition.apiVersion),
				supportedRange()
			)
	end
	if type(definition.id) ~= "string" or not string.match(definition.id, "^[%w_%-]+$") then
		return false, "'id' must be a non-empty string of letters, digits, '_' or '-'"
	end
	if type(definition.name) ~= "string" then
		return false, "missing string field 'name'"
	end
	if definition.activate == SDK.Tool.activate then
		return false, "does not override activate()"
	end
	if definition.settings ~= nil and type(definition.settings) ~= "table" then
		return false, "'settings' must be an array"
	end
	return true, nil
end

local function sortTools(entries: { any })
	table.sort(entries, function(a, b)
		local orderA, orderB = a.definition.order or math.huge, b.definition.order or math.huge
		if orderA ~= orderB then
			return orderA < orderB
		end
		return a.definition.name < b.definition.name
	end)
end

-- options.isInputBlocked: optional extra check for viewport UI outside the
-- ViewportOverlay (e.g. the chat box) that should swallow tool clicks.
function ToolManager.new(host: any, packsFolder: Instance?, options: any?)
	local self = setmetatable({}, ToolManager)
	self.host = host
	self.plugin = host.plugin :: Plugin
	-- { { name, packs = { { manifest, tools = { entry } } }, failedPacks = { PackManifest } } },
	-- in order of first appearance
	self.tabs = {}
	self.tools = {} -- every entry, flattened
	self.toolsById = {}
	self.activeTool = nil -- entry
	self.activeContext = nil
	self.activeInstance = nil
	self.escapeReason = nil -- what Escape does for the active tool
	self._shutdownPending = false -- a confirmShutdown() call is in progress
	self.changed = Signal.new()
	self.store = SettingsStore.new(host.plugin)
	self._maid = Maid.new()
	self._maid:add(self.changed)
	self.overlay = self._maid:add(ViewportOverlay.new())
	self._extraInputBlocked = options and options.isInputBlocked

	local build = host.build or {}
	self:_loadPacks(packsFolder, build.packs or {}, build.failedPacks or {})

	-- Escape dismisses an open confirmation dialog, or else requests that the
	-- active tool shut down. Ignored while typing in a text box.
	self._maid:add(UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed or input.KeyCode ~= Enum.KeyCode.Escape then
			return
		end
		if self.overlay:isConfirmOpen() then
			self.overlay:resolveConfirm(false)
		elseif self.activeTool then
			task.spawn(self.requestShutdown, self, self.escapeReason or Reason.Done, Trigger.Escape)
		end
	end))

	-- Fires when a built-in Studio tool or another plugin takes over the viewport.
	self._maid:add(self.plugin.Deactivation:Connect(function()
		self:deactivate(Reason.Force, true)
	end))

	return self
end

-- Returns the tab with this name, creating it (at the end) if needed.
function ToolManager:_getTab(name: string)
	for _, tab in self.tabs do
		if tab.name == name then
			return tab
		end
	end
	local tab = { name = name, packs = {}, failedPacks = {} }
	table.insert(self.tabs, tab)
	return tab
end

function ToolManager:_loadPacks(packsFolder: Instance?, manifests: { any }, failedPacks: { [string]: string })
	for _, manifest in manifests do
		local tabName = if type(manifest.tab) == "string" and manifest.tab ~= "" then manifest.tab else DEFAULT_TAB
		if failedPacks[manifest.id] then
			-- The loader already logged the errors.
			table.insert(self:_getTab(tabName).failedPacks, manifest)
			continue
		end

		local function packWarn(message: string)
			warn(string.format("[StudioTools] Pack '%s' (%s): %s", manifest.id, manifest.origin or "?", message))
		end

		if not SDK.isApiVersionSupported(manifest.apiVersion) then
			packWarn(
				string.format(
					"written for API version %s, but this Studio Tools build supports %s; skipping",
					tostring(manifest.apiVersion),
					supportedRange()
				)
			)
			continue
		end
		local packFolder = packsFolder and packsFolder:FindFirstChild(manifest.id)
		local toolsFolder = packFolder and packFolder:FindFirstChild("Tools")
		if not toolsFolder then
			packWarn("has no Tools folder; skipping")
			continue
		end

		local pack = { manifest = manifest, tools = {} }
		for _, module in toolsFolder:GetChildren() do
			if not module:IsA("ModuleScript") then
				continue
			end
			local ok, definition = pcall(require, module)
			if not ok then
				packWarn(string.format("tool module %s failed to load: %s", module.Name, tostring(definition)))
				continue
			end
			if type(definition) == "table" and rawget(definition, "abstract") == true then
				continue
			end
			local valid, err = validateDefinition(definition)
			if not valid then
				packWarn(string.format("tool module %s is invalid: %s", module.Name, err or ""))
				continue
			end
			local id = manifest.id .. "/" .. definition.id
			if self.toolsById[id] then
				packWarn(string.format("duplicate tool id '%s' in %s; skipping", definition.id, module.Name))
				continue
			end
			local entry = { id = id, pack = manifest, definition = definition }
			self.toolsById[id] = entry
			table.insert(pack.tools, entry)
		end

		sortTools(pack.tools)
		if #pack.tools > 0 then
			table.insert(self:_getTab(tabName).packs, pack)
			table.move(pack.tools, 1, #pack.tools, #self.tools + 1, self.tools)
		end
	end
end

function ToolManager:getActiveTool()
	return self.activeTool
end

function ToolManager:getSettings(entry: any): { [string]: any }
	return self.store:get(entry)
end

function ToolManager:activate(id: string)
	local entry = self.toolsById[id]
	if not entry or self.activeTool == entry then
		return
	end
	self:deactivate(Reason.Force, true)

	local ctx
	ctx = ToolContext.new(self.host, entry, self.store:get(entry), {
		isInputBlocked = function()
			return self.overlay:isBlockingInput() or (self._extraInputBlocked ~= nil and self._extraInputBlocked())
		end,
		confirm = function(options)
			return self.overlay:confirm(options)
		end,
		refreshShutdownButtons = function()
			if self.activeContext == ctx then
				self:refreshShutdownButtons()
			end
		end,
	})
	local instance = setmetatable({ ctx = ctx }, entry.definition)
	self.activeTool = entry
	self.activeContext = ctx
	self.activeInstance = instance
	self.plugin:Activate(true)

	local ok, err = xpcall(instance.activate, debug.traceback, instance, ctx)
	if not ok then
		warn(string.format("[StudioTools] Tool '%s' failed to activate:\n%s", id, tostring(err)))
		self:deactivate(Reason.Force)
		return
	end

	local gotOptions, options = xpcall(instance.getShutdownOptions, debug.traceback, instance)
	if not gotOptions or type(options) ~= "table" then
		warn(string.format("[StudioTools] Tool '%s' getShutdownOptions() failed; using Done:\n%s", id, tostring(options)))
		options = {}
	end
	local buttons, escapeReason = shutdownButtons(entry, options)
	self.escapeReason = escapeReason
	self.overlay:showShutdownButtons(buttons, function(reason)
		if self.activeInstance == instance then
			task.spawn(self.requestShutdown, self, reason, Trigger.Button)
		end
	end)

	if escapeReason == Reason.Cancel then
		-- Accept/Cancel tool: keep the Accept button's enabled state current.
		self:refreshShutdownButtons()
		task.spawn(function()
			while self.activeInstance == instance do
				task.wait(ACCEPT_POLL_INTERVAL)
				if self.activeInstance == instance and not self._shutdownPending then
					self:refreshShutdownButtons()
				end
			end
		end)
	end
	self.changed:fire()
end

-- Asks the active tool whether Accept is allowed. Returns allowed, why.
function ToolManager:_canAccept(): (boolean, string?)
	local instance = self.activeInstance
	if not instance then
		return false, nil
	end
	local ok, allowed, why = xpcall(instance.canAccept, debug.traceback, instance)
	if not ok then
		if not self._canAcceptWarned then
			self._canAcceptWarned = true
			warn(string.format("[StudioTools] Tool '%s' canAccept() failed; allowing Accept:\n%s", self.activeTool.id, tostring(allowed)))
		end
		return true, nil
	end
	return allowed ~= false, if type(why) == "string" then why else nil
end

-- Re-queries canAccept() and updates the Accept button (Accept/Cancel tools only).
function ToolManager:refreshShutdownButtons()
	if self.escapeReason ~= Reason.Cancel then
		return
	end
	local allowed, why = self:_canAccept()
	self.overlay:setShutdownButtonEnabled(Reason.Accept, allowed, why)
end

-- A user-initiated shutdown (overlay button or Escape). The tool's
-- confirmShutdown() runs first and may yield (e.g. to show a confirmation)
-- or refuse. Only one request is handled at a time.
function ToolManager:requestShutdown(reason: string, trigger: string)
	local instance = self.activeInstance
	if not instance or self._shutdownPending then
		return
	end
	if reason == Reason.Accept and not self:_canAccept() then
		self:refreshShutdownButtons()
		return
	end

	self._shutdownPending = true
	local ok, allowed = xpcall(instance.confirmShutdown, debug.traceback, instance, reason, trigger)
	self._shutdownPending = false
	if not ok then
		-- Don't trap the user in a tool whose confirmShutdown() is broken.
		warn(string.format("[StudioTools] Tool '%s' confirmShutdown() failed; shutting down:\n%s", self.activeTool.id, tostring(allowed)))
	end
	if (not ok or allowed ~= false) and self.activeInstance == instance then
		self:deactivate(reason)
	end
end

-- reason: an SDK.ShutdownReason, passed to the tool's deactivate().
-- pluginAlreadyInactive: true when Studio deactivated us, or when switching
-- directly to another tool (so we don't bounce the plugin's active state).
function ToolManager:deactivate(reason: string, pluginAlreadyInactive: boolean?)
	local entry, ctx, instance = self.activeTool, self.activeContext, self.activeInstance
	if not entry then
		return
	end
	-- Clear first so the Deactivation handler is a no-op if plugin:Deactivate() fires it.
	self.activeTool, self.activeContext, self.activeInstance = nil, nil, nil
	self.escapeReason = nil
	self._canAcceptWarned = false
	self.overlay:hide()

	local ok, err = xpcall(instance.deactivate, debug.traceback, instance, ctx, reason)
	if not ok then
		warn(string.format("[StudioTools] Tool '%s' errored in deactivate:\n%s", entry.id, tostring(err)))
	end
	ctx:destroy()

	if not pluginAlreadyInactive then
		self.plugin:Deactivate()
	end
	self.changed:fire()
end

function ToolManager:toggle(id: string)
	if self.activeTool and self.activeTool.id == id then
		self:deactivate(Reason.Force)
	else
		self:activate(id)
	end
end

function ToolManager:setSetting(id: string, key: string, value: any)
	local entry = self.toolsById[id]
	if not entry then
		return
	end
	local stored = self.store:set(entry, key, value)
	if stored ~= nil and self.activeTool == entry and self.activeContext then
		self.activeContext:_notifySettingChanged(key, stored)
	end
	-- Fire even when rejected so the UI re-renders the previous value.
	self.changed:fire()
end

function ToolManager:destroy()
	self:deactivate(Reason.Force)
	self._maid:clean()
end

return ToolManager
