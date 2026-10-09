--[[
	InputManager: the only connection between tools and the mouse.

	It listens to the plugin mouse and UserInputService, turns each input
	event into an SDK.InputState, and routes it to the active tool's input
	behaviors, following the rules in SDK/Input/InputBehavior.luau. It owns
	the capture: only the active tool's behaviors get input, only one of them
	captures at a time, and a capture is force-ended when the tool shuts
	down, the tool's behavior set changes, or Studio loses focus.

	ToolManager tells it which tool is active (setSource), when the tool's
	behaviors changed (refreshBehaviors) and when to re-run input at the
	current mouse position (refresh). Tools never see it.

	Each input event becomes one InputState, and states are processed in
	order, so a press and release that arrive close together are both seen.
	Behavior methods run in their own coroutine: one that yields can't stall
	input (it finishes in the background and counts as failed), and errors
	are reported once per behavior and method.
]]

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local UserInputService = game:GetService("UserInputService")

local SDK = require(script.Parent.Parent.SDK)
local Maid = SDK.Maid

local DEFAULT_PRIORITY = 100

-- Middle- and right-button input is disabled: Studio pans (middle) and
-- rotates (right) the camera on those drags and plugins can't stop it, so
-- the drags don't work. While false, that button always reads as up and
-- behaviors on it never start.
local MIDDLE_BUTTON_ENABLED = false
local RIGHT_BUTTON_ENABLED = false

local MODIFIER_KEYS = {
	shift = { Enum.KeyCode.LeftShift, Enum.KeyCode.RightShift },
	ctrl = { Enum.KeyCode.LeftControl, Enum.KeyCode.RightControl },
	alt = { Enum.KeyCode.LeftAlt, Enum.KeyCode.RightAlt },
	-- Command on macOS / the Windows key; accept both codes it may arrive as.
	cmd = { Enum.KeyCode.LeftMeta, Enum.KeyCode.RightMeta, Enum.KeyCode.LeftSuper, Enum.KeyCode.RightSuper },
}
local IS_MODIFIER: { [Enum.KeyCode]: boolean } = {}
for _, codes in MODIFIER_KEYS do
	for _, code in codes do
		IS_MODIFIER[code] = true
	end
end

local BEHAVIOR_METHODS = {
	"wantsCapture",
	"beginCapture",
	"updateCapture",
	"endCapture",
	"forceEndCapture",
	"wantsHover",
	"beginHover",
	"updateHover",
	"endHover",
}

local function buttonState(down: boolean, wasDown: boolean): SDK.ButtonState
	return table.freeze({ pressed = down and not wasDown, down = down, released = wasDown and not down })
end

local function isStarted(ok: boolean, state: any): boolean
	return ok and (state == "Begin" or state == "Continue")
end

local InputManager = {}
InputManager.__index = InputManager

-- options.isInputBlocked(): true while the mouse is over system UI in the
-- viewport or a dialog is open. Nothing starts capturing then, and hover ends.
function InputManager.new(plugin: Plugin, options: any?)
	local self = setmetatable({}, InputManager)
	self.mouse = plugin:GetMouse()
	self._isInputBlocked = options and options.isInputBlocked or function()
		return false
	end
	self._source = nil -- { get = () -> behaviors, label = string }
	self._behaviors = {} -- the active tool's behaviors, in its order
	self._active = {} -- behavior -> true
	self._capture = nil -- behavior capturing the mouse
	self._hover = nil -- behavior hovering
	self._leftDown = false
	self._middleDown = false
	self._rightDown = false
	self._keysDown = {} -- KeyCode -> true, modifier keys only
	self._last = nil -- the previous InputState
	self._queue = {}
	self._processing = false
	self._warned = {}
	self._maid = Maid.new()

	local mouse = self.mouse
	self._maid:add(mouse.Move:Connect(function()
		self:_push()
	end))
	self._maid:add(mouse.Button1Down:Connect(function()
		if self._leftDown then
			-- The release was missed (e.g. it happened outside the window).
			self._leftDown = false
			self:_push()
		end
		self._leftDown = true
		self:_push()
	end))
	self._maid:add(mouse.Button1Up:Connect(function()
		self._leftDown = false
		self:_push()
	end))
	self._maid:add(UserInputService.InputBegan:Connect(function(input)
		self:_onInput(input, true)
	end))
	self._maid:add(UserInputService.InputEnded:Connect(function(input)
		self:_onInput(input, false)
	end))
	-- Studio lost focus: whatever the user was doing with the mouse is over.
	self._maid:add(UserInputService.WindowFocusReleased:Connect(function()
		self:_endAll()
	end))

	-- Undo/redo and camera moves change what's under the cursor.
	self._maid:add(ChangeHistoryService.OnUndo:Connect(function()
		self:refresh()
	end))
	self._maid:add(ChangeHistoryService.OnRedo:Connect(function()
		self:refresh()
	end))
	self:_watchCamera()
	self._maid:add(workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		self:_watchCamera()
	end))
	self._maid:add(function()
		if self._cameraConnection then
			self._cameraConnection:Disconnect()
		end
	end)
	return self
end

function InputManager:_watchCamera()
	if self._cameraConnection then
		self._cameraConnection:Disconnect()
		self._cameraConnection = nil
	end
	local camera = workspace.CurrentCamera
	if camera then
		self._cameraConnection = camera:GetPropertyChangedSignal("CFrame"):Connect(function()
			self:refresh()
		end)
	end
end

function InputManager:_onInput(input: InputObject, isDown: boolean)
	if input.UserInputType == Enum.UserInputType.MouseButton3 then
		if MIDDLE_BUTTON_ENABLED and self._middleDown ~= isDown then
			self._middleDown = isDown
			self:_push()
		end
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		if RIGHT_BUTTON_ENABLED and self._rightDown ~= isDown then
			self._rightDown = isDown
			self:_push()
		end
	elseif input.UserInputType == Enum.UserInputType.Keyboard and IS_MODIFIER[input.KeyCode] then
		self._keysDown[input.KeyCode] = isDown or nil
		self:_push()
	end
end

function InputManager:_isModifierDown(name: string): boolean
	for _, code in MODIFIER_KEYS[name] do
		if self._keysDown[code] then
			return true
		end
	end
	return false
end

-- Makes the InputState for the current moment, relative to the previous one.
function InputManager:_snapshot(): SDK.InputState
	local mouse = self.mouse
	local point = table.freeze({ position = Vector2.new(mouse.X, mouse.Y), ray = mouse.UnitRay })
	local last = self._last
	local function button(name: string, down: boolean): SDK.ButtonState
		return buttonState(down, last ~= nil and last[name].down)
	end
	local state = table.freeze({
		point = point,
		previousPoint = if last then last.point else point,
		left = button("left", self._leftDown),
		middle = button("middle", self._middleDown),
		right = button("right", self._rightDown),
		shift = button("shift", self:_isModifierDown("shift")),
		ctrl = button("ctrl", self:_isModifierDown("ctrl")),
		alt = button("alt", self:_isModifierDown("alt")),
		cmd = button("cmd", self:_isModifierDown("cmd")),
		time = os.clock(),
	})
	self._last = state
	return state
end

-- Records the input as it is now and processes it (along with anything queued).
function InputManager:_push()
	-- Snapshot even with no tool active, so pressed/released stay relative
	-- to the real previous state.
	local state = self:_snapshot()
	if not self._source then
		return
	end
	table.insert(self._queue, state)
	if self._processing then
		return -- the loop below is already running further up the stack
	end
	self._processing = true
	while self._queue[1] do
		local input = table.remove(self._queue, 1)
		local ok, err = xpcall(self._process, debug.traceback, self, input)
		if not ok then
			warn("[StudioTools] Input processing failed:\n" .. tostring(err))
		end
	end
	self._processing = false
end

-- Re-runs input at the current mouse position.
function InputManager:refresh()
	if self._source then
		self:_push()
	end
end

-- Behavior calls ---------------------------------------------------------------

function InputManager:_warnOnce(behavior: any, key: string, message: string)
	local warned = self._warned[behavior]
	if not warned then
		warned = {}
		self._warned[behavior] = warned
	end
	if warned[key] then
		return
	end
	warned[key] = true
	local label = if self._source then self._source.label else "?"
	local id = if type(behavior) == "table" then tostring(behavior.id) else tostring(behavior)
	warn(string.format("[StudioTools] Tool '%s' input behavior '%s' %s", label, id, message))
end

-- Calls behavior:method(input). Returns ok and the result; ok is false if it
-- errored or yielded.
function InputManager:_call(behavior: any, method: string, input: SDK.InputState): (boolean, any)
	local thread = coroutine.create(function()
		return xpcall(behavior[method], debug.traceback, behavior, input)
	end)
	local _, ok, result = coroutine.resume(thread)
	if coroutine.status(thread) ~= "dead" then
		self:_warnOnce(behavior, method .. ":yield", method .. "() yielded; input behavior methods must not yield (use task.spawn for slow work)")
		return false, nil
	end
	if not ok then
		self:_warnOnce(behavior, method, method .. "() failed:\n" .. tostring(result))
		return false, nil
	end
	return true, result
end

-- Asks every behavior wantsCapture or wantsHover, and returns the requests
-- best first: lower priority, then nearer depth, then the tool's order.
function InputManager:_requests(method: string, input: SDK.InputState): { any }
	local requests = {}
	for index, behavior in self._behaviors do
		if method == "wantsHover" and behavior.enableHover ~= true then
			continue
		end
		local ok, request = self:_call(behavior, method, input)
		if not ok or request == nil then
			continue
		end
		if type(request) ~= "table" or type(request.depth) ~= "number" or request.depth ~= request.depth then
			self:_warnOnce(behavior, method .. ":request", method .. "() must return nil or { depth = number }")
			continue
		end
		table.insert(requests, {
			behavior = behavior,
			depth = request.depth,
			priority = if type(behavior.priority) == "number" then behavior.priority else DEFAULT_PRIORITY,
			index = index,
		})
	end
	table.sort(requests, function(a, b)
		if a.priority ~= b.priority then
			return a.priority < b.priority
		end
		if a.depth ~= b.depth then
			return a.depth < b.depth
		end
		return a.index < b.index
	end)
	return requests
end

-- Routing ------------------------------------------------------------------------

function InputManager:_process(input: SDK.InputState)
	local captured = self._capture
	if captured then
		local ok, state = self:_call(captured, "updateCapture", input)
		if self._capture ~= captured then
			-- The update itself ended it (e.g. by changing the tool's behaviors).
		elseif isStarted(ok, state) then
			return -- still capturing; hover stays paused
		else
			self._capture = nil
			self:_call(captured, if ok then "endCapture" else "forceEndCapture", input)
		end
	end

	local blocked = self._isInputBlocked()
	if not blocked and self._capture == nil then
		for _, request in self:_requests("wantsCapture", input) do
			local behavior = request.behavior
			if not self._active[behavior] then
				continue
			end
			local ok, state = self:_call(behavior, "beginCapture", input)
			if isStarted(ok, state) then
				if self._active[behavior] and self._capture == nil then
					self._capture = behavior
					return -- hover pauses until the capture ends
				end
				self:_call(behavior, "forceEndCapture", input)
				break
			elseif ok and state == "End" then
				self:_call(behavior, "endCapture", input)
				break
			end
			-- Ignore (or a failure): offer the capture to the next request.
		end
	end

	self:_updateHover(input, blocked)
end

function InputManager:_updateHover(input: SDK.InputState, blocked: boolean)
	local requests = if blocked then {} else self:_requests("wantsHover", input)
	local current = self._hover
	if current and requests[1] and requests[1].behavior == current then
		local ok, state = self:_call(current, "updateHover", input)
		if self._hover == current and not isStarted(ok, state) then
			self._hover = nil
			self:_call(current, "endHover", input)
		end
		return
	end

	if current then
		self._hover = nil
		self:_call(current, "endHover", input)
	end
	for _, request in requests do
		local behavior = request.behavior
		if not self._active[behavior] or self._hover ~= nil then
			continue
		end
		local ok, state = self:_call(behavior, "beginHover", input)
		if isStarted(ok, state) then
			if self._active[behavior] and self._hover == nil then
				self._hover = behavior
			else
				self:_call(behavior, "endHover", input)
			end
			return
		elseif ok and state == "End" then
			self:_call(behavior, "endHover", input)
			return
		end
	end
end

-- Force-ends the capture, ends the hover and forgets which buttons are down.
function InputManager:_endAll()
	table.clear(self._queue)
	self._leftDown, self._middleDown, self._rightDown = false, false, false
	table.clear(self._keysDown)
	local captured, hovered = self._capture, self._hover
	self._capture, self._hover = nil, nil
	if not captured and not hovered then
		return
	end
	local input = self:_snapshot()
	if captured then
		self:_call(captured, "forceEndCapture", input)
	end
	if hovered then
		self:_call(hovered, "endHover", input)
	end
end

-- Tool interface (used by ToolManager) --------------------------------------------

-- Sets the active tool: getBehaviors() returns its behaviors, label names it
-- in warnings. nil means no tool. Ends any capture and hover either way.
function InputManager:setSource(getBehaviors: (() -> { any })?, label: string?)
	self:_endAll()
	self._source = if getBehaviors then { get = getBehaviors, label = label or "?" } else nil
	self._warned = {}
	self:refreshBehaviors()
end

-- Re-collects the active tool's behaviors. A capturing or hovering behavior
-- that's gone is force-ended / ends its hover. Then re-runs input, so new
-- behaviors can hover right away.
function InputManager:refreshBehaviors()
	local behaviors, active = {}, {}
	local source = self._source
	if source then
		local ok, result = xpcall(source.get, debug.traceback)
		if not ok then
			warn(string.format("[StudioTools] Tool '%s' getInputBehaviors() failed:\n%s", source.label, tostring(result)))
		elseif type(result) == "table" then
			for _, behavior in result do
				if active[behavior] then
					continue
				end
				local valid = type(behavior) == "table"
				for _, method in BEHAVIOR_METHODS do
					if not valid then
						break
					end
					valid = type(behavior[method]) == "function"
				end
				if valid then
					table.insert(behaviors, behavior)
					active[behavior] = true
				else
					self:_warnOnce(
						behavior,
						"invalid",
						"isn't an input behavior; create behaviors with SDK.InputBehavior or the standard ones"
					)
				end
			end
		end
	end
	self._behaviors, self._active = behaviors, active

	local captured, hovered = self._capture, self._hover
	if (captured and not active[captured]) or (hovered and not active[hovered]) then
		local input = self._last or self:_snapshot()
		if captured and not active[captured] then
			self._capture = nil
			self:_call(captured, "forceEndCapture", input)
		end
		if hovered and not active[hovered] then
			self._hover = nil
			self:_call(hovered, "endHover", input)
		end
	end
	self:refresh()
end

function InputManager:destroy()
	self:setSource(nil)
	self._maid:clean()
end

return InputManager
