--[[
	ToolContext: the API surface handed to a tool while it is active.

	Everything a tool connects or creates through the context is cleaned up
	automatically when the tool is deactivated, so tools generally don't need
	a deactivate() callback at all.

	Fields:
	  ctx.plugin       the Plugin object
	  ctx.toolId       qualified tool id, "<packId>/<toolId>"
	  ctx.settings     live table of this tool's setting values
	  ctx.state        scratch table for the tool's own use
	  ctx.definition   the tool's class

	The public shape of this object is SDK.ToolContext (SDK/Types.luau). Keep
	the two in sync, and treat removing or changing anything as API-breaking.
]]

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local CoreGui = game:GetService("CoreGui")
local UserInputService = game:GetService("UserInputService")

local SDK = require(script.Parent.Parent.SDK)
local AgentRequests = require(script.Parent.AgentRequests)
local Maid = SDK.Maid
local Signal = SDK.Signal

local ToolContext = {}
ToolContext.__index = ToolContext

-- `entry` is a ToolManager entry: { id = "<packId>/<toolId>", definition = class }.
-- options (provided by ToolManager):
--   confirm(options)           shows the system confirmation dialog (yields)
--   refreshShutdownButtons()   re-queries canAccept()
--   inputBehaviorsChanged()    re-collects the tool's input behaviors
--   refreshInput()             re-runs input at the current mouse position
function ToolContext.new(host: any, entry: any, settings: { [string]: any }, options: any?)
	local self = setmetatable({}, ToolContext)
	self.host = host
	self.plugin = host.plugin :: Plugin
	self.toolId = entry.id
	self.definition = entry.definition
	self.settings = settings
	self.state = {}
	self._maid = Maid.new()
	self._settingChanged = self._maid:add(Signal.new())
	self._raycastExclude = {} :: { Instance }
	options = options or {}
	self._confirm = options.confirm
	self._refreshShutdownButtons = options.refreshShutdownButtons
	self._inputBehaviorsChanged = options.inputBehaviorsChanged
	self._refreshInput = options.refreshInput
	self._setStatus = options.setStatus
	self._setSettingState = options.setSettingState
	self._panels = {} :: { Frame } -- from createViewportPanel
	self._panelGui = nil :: ScreenGui?
	self._panelColumns = {} :: { [string]: Frame } -- position -> container
	return self
end

-- Cleanup ---------------------------------------------------------------

-- Registers anything Maid understands (Instance, connection, function, object with Destroy).
function ToolContext:addCleanup<T>(task: T): T
	return self._maid:add(task)
end

function ToolContext:connect(signal: RBXScriptSignal, fn: (...any) -> ()): RBXScriptConnection
	return self._maid:add(signal:Connect(fn))
end

-- Input -----------------------------------------------------------------
-- Tools take mouse input only through input behaviors
-- (Tool:addInputBehavior), which the InputManager routes. Keyboard state
-- and key events are available here.

-- Tells the system that the tool's getInputBehaviors() result changed.
function ToolContext:inputBehaviorsChanged()
	if self._inputBehaviorsChanged then
		self._inputBehaviorsChanged()
	end
end

-- Re-runs hover and capture handling at the current mouse position.
function ToolContext:refreshInput()
	if self._refreshInput then
		self._refreshInput()
	end
end

function ToolContext:isKeyDown(...: Enum.KeyCode): boolean
	for _, keyCode in { ... } do
		if UserInputService:IsKeyDown(keyCode) then
			return true
		end
	end
	return false
end

function ToolContext:isShiftDown(): boolean
	return self:isKeyDown(Enum.KeyCode.LeftShift, Enum.KeyCode.RightShift)
end

-- fn(input: InputObject, isDown: boolean) for keyboard input in the viewport.
function ToolContext:onKey(fn: (InputObject, boolean) -> ())
	self:connect(UserInputService.InputBegan, function(input)
		if input.UserInputType == Enum.UserInputType.Keyboard then
			fn(input, true)
		end
	end)
	self:connect(UserInputService.InputEnded, function(input)
		if input.UserInputType == Enum.UserInputType.Keyboard then
			fn(input, false)
		end
	end)
end

-- fn(key, value) fires when the user edits one of this tool's settings in the palette.
function ToolContext:onSettingChanged(fn: (string, any) -> ())
	return self._maid:add(self._settingChanged:connect(fn))
end

function ToolContext:_notifySettingChanged(key: string, value: any)
	self._settingChanged:fire(key, value)
end

-- Raycasting ------------------------------------------------------------

-- Instances that ctx:raycastAt() should ignore for the lifetime of the tool.
function ToolContext:excludeFromRaycast(instance: Instance)
	table.insert(self._raycastExclude, instance)
end

-- Casts the ray of an input point (see SDK.InputPoint): from the camera
-- through that point in the viewport.
function ToolContext:raycastAt(point: SDK.InputPoint, maxDistance: number?, extraExclude: { Instance }?): RaycastResult?
	local unitRay = point.ray
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude = table.clone(self._raycastExclude)
	if extraExclude then
		table.move(extraExclude, 1, #extraExclude, #exclude + 1, exclude)
	end
	params.FilterDescendantsInstances = exclude
	return workspace:Raycast(unitRay.Origin, unitRay.Direction * (maxDistance or 10000), params)
end

-- Returns the unlocked BasePart (never Terrain) at an input point, plus the
-- raycast result.
function ToolContext:partAt(point: SDK.InputPoint): (BasePart?, RaycastResult?)
	local hit = self:raycastAt(point)
	local part = hit and hit.Instance
	if part and part:IsA("BasePart") and not part:IsA("Terrain") and not part.Locked then
		return part, hit
	end
	return nil, hit
end

-- Visual feedback ---------------------------------------------------------
-- These live in CoreGui, so they render in the viewport without touching the
-- place, never show up in undo history and are never saved.

function ToolContext:createBoxPreview(): BoxHandleAdornment
	local box = Instance.new("BoxHandleAdornment")
	box.Name = "StudioToolsPreview"
	box.Adornee = workspace.Terrain -- sits at the origin, so box.CFrame is effectively world space
	box.AlwaysOnTop = false
	box.ZIndex = 0
	box.Transparency = 0.5
	box.Visible = false
	box.Parent = CoreGui
	return self:addCleanup(box)
end

function ToolContext:createHighlight(color: Color3?): SelectionBox
	local selectionBox = Instance.new("SelectionBox")
	selectionBox.Name = "StudioToolsHighlight"
	selectionBox.LineThickness = 0.06
	selectionBox.Color3 = color or Color3.fromRGB(0, 170, 255)
	selectionBox.SurfaceTransparency = 0.85
	selectionBox.SurfaceColor3 = selectionBox.Color3
	selectionBox.Adornee = nil
	selectionBox.Parent = CoreGui
	return self:addCleanup(selectionBox)
end

-- Undo ------------------------------------------------------------------

-- Begins an undo waypoint. Call :commit() or :cancel() on the result. A
-- recording that is still open when the tool deactivates is committed.
function ToolContext:beginUndo(name: string)
	local recordingId = ChangeHistoryService:TryBeginRecording(name, name)
	local finished = false
	local handle = {}
	local function finish(operation: Enum.FinishRecordingOperation)
		if finished then
			return
		end
		finished = true
		if recordingId then
			ChangeHistoryService:FinishRecording(recordingId, operation)
		end
	end
	function handle.commit()
		finish(Enum.FinishRecordingOperation.Commit)
	end
	function handle.cancel()
		finish(Enum.FinishRecordingOperation.Cancel)
	end
	self:addCleanup(handle.commit)
	return handle
end

-- fn(action, waypointName) after the user undoes or redoes while the tool is
-- active (action is "Undo" or "Redo"). Use it to resync any state the tool
-- keeps about the place, since undo/redo changes the place behind its back.
function ToolContext:onUndoRedo(fn: (string, string) -> ())
	self:connect(ChangeHistoryService.OnUndo, function(waypoint: string)
		fn("Undo", waypoint)
	end)
	self:connect(ChangeHistoryService.OnRedo, function(waypoint: string)
		fn("Redo", waypoint)
	end)
end

-- Runs fn inside a single undo waypoint. Changes are rolled back if fn errors.
function ToolContext:recordUndo(name: string, fn: (...any) -> ...any, ...: any): (boolean, any)
	local recording = self:beginUndo(name)
	local ok, result = xpcall(fn, debug.traceback, ...)
	if ok then
		recording.commit()
	else
		recording.cancel()
		warn(string.format("[StudioTools] %s failed: %s", name, tostring(result)))
	end
	return ok, result
end

-- System UI ---------------------------------------------------------------

-- Shows a confirmation dialog in the viewport and yields until it's answered.
-- Returns false if dismissed (Cancel button or Escape), if the tool shuts
-- down meanwhile, or if another dialog is already open.
function ToolContext:confirm(options: SDK.ConfirmOptions): boolean
	if not self._confirm then
		return true
	end
	return self._confirm(options)
end

-- Re-queries canAccept() now instead of waiting for the next poll.
function ToolContext:refreshShutdownButtons()
	if self._refreshShutdownButtons then
		self._refreshShutdownButtons()
	end
end

-- Tool UI ----------------------------------------------------------------
-- Tools put their controls in the palette's settings panel: values as
-- settings, actions as "button" settings (Tool:onAction), progress as a
-- status line, with setSettingState to show/hide or enable/disable widgets.
-- A viewport panel is for anything that doesn't fit there.

-- A line of text under the tool's name in the palette; nil hides it.
function ToolContext:setStatus(text: string?)
	if text ~= nil and type(text) ~= "string" then
		error("ctx:setStatus: text must be a string or nil", 2)
	end
	if self._setStatus then
		self._setStatus(text)
	end
end

-- Shows/hides, enables/disables, relabels or changes the tooltip of one
-- setting's widget, for any setting type. Only the fields given change.
-- Every widget starts visible, enabled, and with its schema's label and
-- tooltip, each time the tool activates.
function ToolContext:setSettingState(key: string, state: SDK.SettingState)
	if type(state) ~= "table" then
		error("ctx:setSettingState: state must be a table", 2)
	end
	if self._setSettingState then
		self._setSettingState(key, state)
	end
end

local PANEL_MARGIN = 12

local PANEL_POSITIONS = {
	Top = { anchor = Vector2.new(0.5, 0), position = UDim2.new(0.5, 0, 0, PANEL_MARGIN), align = Enum.HorizontalAlignment.Center },
	TopLeft = { anchor = Vector2.new(0, 0), position = UDim2.new(0, PANEL_MARGIN, 0, PANEL_MARGIN), align = Enum.HorizontalAlignment.Left },
	TopRight = { anchor = Vector2.new(1, 0), position = UDim2.new(1, -PANEL_MARGIN, 0, PANEL_MARGIN), align = Enum.HorizontalAlignment.Right },
}

-- A panel in the viewport, styled like the system's viewport UI (see
-- SDK.ViewportStyle): a Frame that sizes to its contents, with rounded
-- corners, padding and a horizontal UIListLayout named "Layout". The tool
-- fills it and may restyle it. Clicks inside it don't reach the tool's input
-- behaviors. It's removed when the tool deactivates.
function ToolContext:createViewportPanel(options: SDK.ViewportPanelOptions?): Frame
	local positionName = options and options.position or "Top"
	local placement = PANEL_POSITIONS[positionName]
	if not placement then
		error(string.format("ctx:createViewportPanel: unknown position '%s'", tostring(positionName)), 2)
	end
	local style = SDK.ViewportStyle

	local gui = self._panelGui
	if not gui then
		gui = Instance.new("ScreenGui")
		gui.Name = "StudioToolsToolPanels"
		gui.IgnoreGuiInset = true
		gui.ResetOnSpawn = false
		gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		gui.DisplayOrder = 99 -- under the shutdown overlay and the chat
		gui.Parent = CoreGui
		self._panelGui = self:addCleanup(gui)
	end

	-- Panels at the same position stack downward in a column.
	local column = self._panelColumns[positionName]
	if not column then
		column = Instance.new("Frame")
		column.Name = positionName
		column.AnchorPoint = placement.anchor
		column.Position = placement.position
		column.Size = UDim2.new()
		column.AutomaticSize = Enum.AutomaticSize.XY
		column.BackgroundTransparency = 1
		local layout = Instance.new("UIListLayout")
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.HorizontalAlignment = placement.align
		layout.Padding = UDim.new(0, 8)
		layout.Parent = column
		column.Parent = gui
		self._panelColumns[positionName] = column
	end

	local panel = Instance.new("Frame")
	panel.Name = options and options.name or "Panel"
	panel.LayoutOrder = #self._panels + 1
	panel.Size = UDim2.new()
	panel.AutomaticSize = Enum.AutomaticSize.XY
	panel.BackgroundColor3 = style.panel
	panel.BorderSizePixel = 0
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, style.cornerRadius)
	corner.Parent = panel
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, style.padding)
	padding.PaddingRight = UDim.new(0, style.padding)
	padding.PaddingTop = UDim.new(0, style.padding)
	padding.PaddingBottom = UDim.new(0, style.padding)
	padding.Parent = panel
	local layout = Instance.new("UIListLayout")
	layout.Name = "Layout"
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, style.padding)
	layout.Parent = panel
	panel.Parent = column
	table.insert(self._panels, panel)
	return panel
end

-- True while the mouse is over one of the tool's viewport panels (the
-- ToolManager blocks tool input then).
function ToolContext:_isMouseOverPanel(): boolean
	if not self._panelGui or not self._panelGui.Enabled then
		return false
	end
	local mouse = self.plugin:GetMouse()
	for _, panel in self._panels do
		if panel.Parent and panel.Visible then
			local position, size = panel.AbsolutePosition, panel.AbsoluteSize
			if mouse.X >= position.X and mouse.X <= position.X + size.X and mouse.Y >= position.Y and mouse.Y <= position.Y + size.Y then
				return true
			end
		end
	end
	return false
end

-- Tools Agent -------------------------------------------------------------

-- Sends a prompt to the Tools Agent (the coding agent behind the chat, which
-- can edit the place through the Roblox Studio MCP) and returns an
-- SDK.AgentRequest right away; it never yields. Wait for the result with
-- request:await() (in a thread that may yield) or request:onFinished(fn).
-- The request outlives the tool unless options.cancelOnDeactivate is set.
function ToolContext:askAgent(prompt: string, options: SDK.AskAgentOptions?): SDK.AgentRequest
	if type(prompt) ~= "string" or not string.find(prompt, "%S") then
		error("ctx:askAgent: prompt must be a non-empty string", 2)
	end
	local request = AgentRequests.submit(self.host.serverUrl, prompt, {
		toolId = self.toolId,
		name = tostring(self.definition.name or self.toolId),
	})
	if options and options.cancelOnDeactivate then
		self:addCleanup(function()
			request:cancel()
		end)
	end
	return request
end

-- Misc ------------------------------------------------------------------

function ToolContext:log(...: any)
	print(string.format("[StudioTools:%s]", self.toolId), ...)
end

function ToolContext:destroy()
	self._maid:clean()
end

return ToolContext
