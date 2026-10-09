--[[
	InputBehavior: base class for the objects that turn mouse input into tool
	actions.

	Tools don't listen to the mouse themselves. They add behaviors
	(self:addInputBehavior), and the system's input manager routes input to
	them:

	  * Capture (mouse button sequences). While nothing is capturing, every
	    input update asks every behavior wantsCapture(input). The requests
	    are ordered by priority (lower first), then depth (nearest first),
	    and beginCapture() is called on each in turn until one returns
	    Begin. That behavior then gets every update through updateCapture()
	    until it returns End, followed by endCapture(). Only one behavior
	    captures at a time. forceEndCapture() is called instead if the
	    capture is taken away (tool shutdown, behavior removed, Studio
	    losing focus).
	  * Hover. Behaviors with enableHover = true are asked wantsHover(input)
	    on every update that isn't captured; the best request (same order)
	    hovers: beginHover(), then updateHover() while it stays the best,
	    then endHover(). Hover is paused, not ended, while a behavior
	    captures, and resumes on the update that ends the capture.

	Every behavior is asked on every update, because any of them might have
	the nearest hit. While the mouse is over system UI in the viewport (the
	shutdown buttons, the chat box) or a dialog is open, nothing starts
	capturing and hover ends.

	Methods must not yield. One that does is left to finish in the
	background and treated as having failed; errors are reported in the
	output and also count as failure (no capture or hover, or the capture is
	force-ended).

	The standard behaviors (SingleClick, ClickDrag, ClickOrDrag, Hover) cover
	most tools; they take hit tests and callbacks as options. For custom
	ones, extend this class:

		local MyBehavior = SDK.InputBehavior:extend({ id = "MyBehavior" })

		function MyBehavior:wantsCapture(input: SDK.InputState): SDK.CaptureRequest?
			...
		end

		local behavior = MyBehavior:new({ someOption = 1 })
]]

local InputBehavior = {}
InputBehavior.__index = InputBehavior
InputBehavior.id = "InputBehavior"
InputBehavior.priority = 100
InputBehavior.enableHover = false

-- Creates a subclass of `base`. The given table becomes the class.
function InputBehavior.extend(base: any, definition: { [string]: any }?): any
	local class = definition or {}
	class.__index = class
	return setmetatable(class, base)
end

-- Creates an instance of `class` with `fields` (options and callbacks)
-- copied onto it, then calls init().
function InputBehavior.new(class: any, fields: { [string]: any }?): any
	local self = setmetatable(table.clone(fields or {}), class)
	self:init()
	return self
end

-- Called by new(). Override to set up state or option defaults.
function InputBehavior:init() end

function InputBehavior:wantsCapture(_input: any): any
	return nil
end

function InputBehavior:beginCapture(_input: any): string
	return "Ignore"
end

function InputBehavior:updateCapture(_input: any): string
	return "End"
end

function InputBehavior:endCapture(_input: any) end

function InputBehavior:forceEndCapture(_input: any) end

function InputBehavior:wantsHover(_input: any): any
	return nil
end

function InputBehavior:beginHover(_input: any): string
	return "Ignore"
end

function InputBehavior:updateHover(_input: any): string
	return "End"
end

function InputBehavior:endHover(_input: any) end

-- Helpers for subclasses ----------------------------------------------------

-- Which modifier keys are held in `input`.
function InputBehavior.getModifiers(input: any): any
	return {
		shift = input.shift.down,
		ctrl = input.ctrl.down,
		alt = input.alt.down,
		cmd = input.cmd.down,
	}
end

-- The state of a mouse button ("Left", "Middle" or "Right") in `input`.
function InputBehavior.getButton(input: any, button: string): any
	if button == "Middle" then
		return input.middle
	elseif button == "Right" then
		return input.right
	end
	return input.left
end

-- A capture request for the standard behaviors: asks to capture when
-- hitTest(point) hits.
function InputBehavior.requestIfHit(hitTest: any, point: any): any
	if type(hitTest) ~= "function" then
		return nil
	end
	local depth = hitTest(point)
	if type(depth) ~= "number" then
		return nil
	end
	return { depth = depth }
end

return InputBehavior
