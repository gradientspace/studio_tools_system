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
local CameraMotion = require(script.Parent.CameraMotion)
local CameraSpeed = require(script.Parent.CameraSpeed)
local MeshUpload = require(script.Parent.MeshUpload)
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
	self._alert = options.alert
	self._showProgress = options.showProgress
	self._saveLocalMesh = options.saveLocalMesh
	self._clearLocalMesh = options.clearLocalMesh
	self._refreshShutdownButtons = options.refreshShutdownButtons
	self._inputBehaviorsChanged = options.inputBehaviorsChanged
	self._refreshInput = options.refreshInput
	self._setStatus = options.setStatus
	self._setSettingState = options.setSettingState
	self._setSetting = options.setSetting
	self._panels = {} :: { Frame } -- from createViewportPanel
	self._panelGui = nil :: ScreenGui?
	self._panelColumns = {} :: { [string]: Frame } -- position -> container
	self._undoSteps = nil :: { { name: string, undo: () -> (), redo: () -> () } }? -- from addUndoStep
	self._undoApplied = 0 -- how many of _undoSteps are currently applied
	self._undoToken = nil :: string?
	-- The user's camera speeds when the tool started, restored on deactivate
	-- if autoCameraSpeed changed them.
	self._cameraSpeeds = CameraSpeed.snapshot()
	self._cameraSpeedChanged = false
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

-- Changes one of this tool's settings, as if the user had edited it: the
-- value is coerced and saved, the palette shows it, and onSettingChanged
-- handlers run.
function ToolContext:setSetting(key: string, value: any)
	if self._setSetting then
		self._setSetting(key, value)
	end
end

-- fn(key, value) fires when one of this tool's settings changes (edited in
-- the palette, or set with ctx:setSetting).
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

-- Any HandleAdornment class (LineHandleAdornment, SphereHandleAdornment,
-- ConeHandleAdornment, ...), adorning the Terrain so its CFrame is world
-- space. Visible, with default properties otherwise.
function ToolContext:createAdornment(className: string): HandleAdornment
	local ok, adornment = pcall(Instance.new, className)
	if not ok or not adornment:IsA("HandleAdornment") then
		if ok then
			adornment:Destroy()
		end
		error(string.format("ctx:createAdornment: '%s' is not a HandleAdornment class", tostring(className)), 2)
	end
	adornment.Name = "StudioToolsAdornment"
	adornment.Adornee = workspace.Terrain
	adornment.Parent = CoreGui
	return self:addCleanup(adornment)
end

-- A Model in the Workspace for temporary 3D content, such as a preview mesh.
-- It and everything put in it are made non-archivable, so they're never
-- saved, copied or recorded in undo history; parts in it are locked and
-- ignored by ctx:raycastAt. It's destroyed when the tool deactivates.
function ToolContext:createTemporaryModel(name: string?): Model
	local model = Instance.new("Model")
	model.Name = name or "StudioToolsTemporary"
	model.Archivable = false
	local function prepare(descendant: Instance)
		descendant.Archivable = false
		if descendant:IsA("BasePart") then
			descendant.Locked = true
		end
	end
	self:connect(model.DescendantAdded, prepare)
	self:excludeFromRaycast(model)
	model.Parent = workspace
	return self:addCleanup(model)
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

-- Camera --------------------------------------------------------------------
-- Animated moves shared with the system's own hotkeys (see CameraMotion).

-- Moves the camera to frame a box (cframe = its center and orientation,
-- size = its extents), keeping the current view direction, and makes the box
-- center the camera's orbit point. Animated briefly; a newer move takes over.
function ToolContext:focusView(cframe: CFrame, size: Vector3)
	if typeof(cframe) ~= "CFrame" or typeof(size) ~= "Vector3" then
		error("ctx:focusView: expected (cframe: CFrame, size: Vector3)", 2)
	end
	CameraMotion.frame(cframe, size)
end

-- Sets Studio's camera fly and mouse-wheel speeds to suit an object of this
-- size (e.g. the bounds of what the tool edits). They're user preferences,
-- so the values from when the tool started come back when it deactivates.
function ToolContext:autoCameraSpeed(size: Vector3)
	if typeof(size) ~= "Vector3" then
		error("ctx:autoCameraSpeed: expected (size: Vector3)", 2)
	end
	if not self._cameraSpeedChanged then
		self._cameraSpeedChanged = true
		self:addCleanup(function()
			CameraSpeed.restore(self.plugin, self._cameraSpeeds)
		end)
	end
	CameraSpeed.apply(self.plugin, self._cameraSpeeds, size)
end

-- Pans the camera (no rotation, no zoom) so that a world point is at the
-- center of the view, and makes it the camera's orbit point. Animated.
function ToolContext:centerView(point: Vector3)
	if typeof(point) ~= "Vector3" then
		error("ctx:centerView: expected (point: Vector3)", 2)
	end
	CameraMotion.center(point)
end

-- Undo steps for the tool's own state ----------------------------------------
-- Studio's undo history only covers the place. A tool that edits state of
-- its own (e.g. a mesh it keeps in memory) adds undo steps instead: each one
-- records a Studio waypoint, so Ctrl+Z / Ctrl+Y and the undo buttons undo
-- and redo it in order with everything else.
--
-- The waypoint needs a change Studio tracks, so each step sets an attribute
-- on the Workspace to "<context token>:<step count>". After any undo or redo
-- the attribute's value says how many of this context's steps should be
-- applied, and the steps in between are undone or redone to match. (Changes
-- to non-archivable instances, CoreGui or the Camera aren't tracked, so the
-- marker has to live in the place.) The attribute is removed on deactivate.

local UNDO_MARKER = "StudioToolsUndoStep"

-- Applies or reverts steps until `target` of them are applied.
function ToolContext:_syncUndoSteps()
	local value = workspace:GetAttribute(UNDO_MARKER)
	local target = 0
	if type(value) == "string" then
		local token, count = string.match(value, "^(.*):(%d+)$")
		if token == self._undoToken then
			target = math.min(tonumber(count) or 0, #self._undoSteps)
		end
	end
	while self._undoApplied > target do
		local step = self._undoSteps[self._undoApplied]
		self._undoApplied -= 1
		if step then
			local ok, err = xpcall(step.undo, debug.traceback)
			if not ok then
				warn(string.format("[StudioTools] Tool '%s' undo step '%s' failed:\n%s", self.toolId, step.name, tostring(err)))
			end
		end
	end
	while self._undoApplied < target do
		self._undoApplied += 1
		local step = self._undoSteps[self._undoApplied]
		if step then
			local ok, err = xpcall(step.redo, debug.traceback)
			if not ok then
				warn(string.format("[StudioTools] Tool '%s' redo step '%s' failed:\n%s", self.toolId, step.name, tostring(err)))
			end
		end
	end
end

-- Adds a step to Studio's undo history for a change the tool has already
-- made to its own state. undo() reverts it and redo() makes it again; they
-- run when the user undoes or redoes while the tool is active, and must not
-- yield. After the tool deactivates the waypoints stay in the history but do
-- nothing. Adding a step drops any steps that were undone (like Studio's
-- redo history).
function ToolContext:addUndoStep(name: string, undo: () -> (), redo: () -> ())
	if type(name) ~= "string" or type(undo) ~= "function" or type(redo) ~= "function" then
		error("ctx:addUndoStep: expected (name: string, undo: function, redo: function)", 2)
	end
	if not self._undoSteps then
		self._undoSteps = {}
		self._undoApplied = 0
		self._undoToken = game:GetService("HttpService"):GenerateGUID(false)
		local function sync()
			self:_syncUndoSteps()
		end
		self:connect(ChangeHistoryService.OnUndo, sync)
		self:connect(ChangeHistoryService.OnRedo, sync)
		self:addCleanup(function()
			-- Not recorded: it's absorbed into the next waypoint, where undoing
			-- it only puts back an attribute nothing listens to anymore.
			if workspace:GetAttribute(UNDO_MARKER) ~= nil then
				workspace:SetAttribute(UNDO_MARKER, nil)
			end
		end)
	end
	for index = #self._undoSteps, self._undoApplied + 1, -1 do
		self._undoSteps[index] = nil
	end
	table.insert(self._undoSteps, { name = name, undo = undo, redo = redo })
	self._undoApplied = #self._undoSteps

	local recordingId = ChangeHistoryService:TryBeginRecording(name, name)
	workspace:SetAttribute(UNDO_MARKER, string.format("%s:%d", self._undoToken, self._undoApplied))
	if recordingId then
		ChangeHistoryService:FinishRecording(recordingId, Enum.FinishRecordingOperation.Commit)
	end
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

-- Shows a message (e.g. an error) in a dialog with one button, and yields
-- until it's dismissed: the button, Escape, or the tool shutting down.
function ToolContext:alert(options: SDK.AlertOptions)
	if type(options) ~= "table" or type(options.message) ~= "string" then
		error("ctx:alert: options.message must be a string", 2)
	end
	if not self._alert then
		warn(string.format("[StudioTools:%s] %s%s", self.toolId, if options.title then options.title .. ": " else "", options.message))
		return
	end
	self._alert(options)
end

-- Shows a modal progress dialog (message and an animated bar) while the tool
-- works on something the user must wait for, e.g. an upload on Accept.
-- Viewport input, the shutdown buttons and Escape are blocked while it's
-- open. Returns a handle: handle:setMessage(text), handle:close(). Closed
-- automatically on deactivate.
function ToolContext:showProgress(options: SDK.ProgressOptions): SDK.ProgressHandle
	if type(options) ~= "table" or type(options.message) ~= "string" then
		error("ctx:showProgress: options.message must be a string", 2)
	end
	local inner = if self._showProgress then self._showProgress(options) else nil
	local handle = {}
	function handle.setMessage(_handle: any, text: string)
		if inner then
			inner:setMessage(text)
		end
	end
	function handle.close(_handle: any)
		if inner then
			inner:close()
			inner = nil
		end
	end
	self:addCleanup(function()
		handle:close()
	end)
	return handle :: any
end

-- Local meshes ----------------------------------------------------------------

-- Makes an EditableMesh-backed MeshPart survive saving the place: tags the
-- part with a mesh id and stores the mesh on the dev server (in the
-- background), from where it's restored when the place is opened again.
-- Call it after creating or changing such a part, inside the undo recording
-- that did so (it sets an attribute and a tag on the part). Returns the id.
function ToolContext:saveLocalMesh(part: MeshPart): string
	if typeof(part) ~= "Instance" or not part:IsA("MeshPart") then
		error("ctx:saveLocalMesh: expected a MeshPart", 2)
	end
	if not self._saveLocalMesh then
		error("ctx:saveLocalMesh: local meshes aren't available", 2)
	end
	return self._saveLocalMesh(part)
end

-- Stops treating a part as a local mesh, e.g. after giving it an uploaded
-- mesh asset. Call it inside the undo recording that changed the part.
function ToolContext:clearLocalMesh(part: MeshPart)
	if typeof(part) ~= "Instance" or not part:IsA("MeshPart") then
		error("ctx:clearLocalMesh: expected a MeshPart", 2)
	end
	if self._clearLocalMesh then
		self._clearLocalMesh(part)
	end
end

-- Uploads the part's mesh as a new Mesh asset and loads it back as an
-- unparented MeshPart (see MeshUpload.luau). Yields; errors with a message
-- for the user. Stops early if the tool deactivates meanwhile.
function ToolContext:uploadMesh(part: MeshPart, options: SDK.UploadMeshOptions): SDK.UploadedMesh
	if typeof(part) ~= "Instance" or not part:IsA("MeshPart") then
		error("ctx:uploadMesh: expected a MeshPart", 2)
	end
	if type(options) ~= "table" or type(options.name) ~= "string" or options.name == "" then
		error("ctx:uploadMesh: options.name must be a non-empty string", 2)
	end
	local ok, result = pcall(MeshUpload.upload, part, {
		name = options.name,
		description = options.description,
		onStatus = options.onStatus,
		isCancelled = function()
			return self._destroyed
		end,
	})
	if ok then
		return result
	end
	local message = MeshUpload.cleanError(result)
	if type(result) == "table" and result.cancelled then
		message = "the tool closed during the upload"
			.. if result.uri then string.format(" (the mesh was uploaded as %s, but isn't used)", result.uri) else ""
	end
	error(message, 0)
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
	self._destroyed = true
	self._maid:clean()
end

return ToolContext
