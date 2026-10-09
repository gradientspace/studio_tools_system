--[[
	ClickDragInputBehavior: press on a target and drag.

		SDK.ClickDragInputBehavior:new({
			hitTest = function(point) return depth or nil end,
			onBeginDrag = function(point, modifiers) ... end,   -- at the press
			onUpdateDrag = function(point, modifiers) ... end,  -- every update while held
			onEndDrag = function(point, modifiers) ... end,     -- at the release
			onCancelDrag = function() ... end,                  -- optional
			button = "Left",                                    -- optional; or "Middle" / "Right"
		})

	onUpdateDrag runs on every input update while the button is held: mouse
	moves, modifier keys going up or down (e.g. Shift to switch drag mode),
	camera moves and refreshes, and the release itself. If the drag is
	taken away (tool shutdown, Studio losing focus), onCancelDrag is called,
	or onEndDrag at the last point if there's no onCancelDrag.
]]

local InputBehavior = require(script.Parent.InputBehavior)

local ClickDragInputBehavior = InputBehavior:extend({
	id = "ClickDrag",
	button = "Left",
})

function ClickDragInputBehavior:wantsCapture(input: any): any
	if not InputBehavior.getButton(input, self.button).pressed then
		return nil
	end
	return InputBehavior.requestIfHit(self.hitTest, input.point)
end

function ClickDragInputBehavior:beginCapture(input: any): string
	self._lastPoint = input.point
	if self.onBeginDrag then
		self.onBeginDrag(input.point, InputBehavior.getModifiers(input))
	end
	return "Begin"
end

function ClickDragInputBehavior:updateCapture(input: any): string
	self._lastPoint = input.point
	if self.onUpdateDrag then
		self.onUpdateDrag(input.point, InputBehavior.getModifiers(input))
	end
	return if InputBehavior.getButton(input, self.button).down then "Continue" else "End"
end

function ClickDragInputBehavior:endCapture(input: any)
	self._lastPoint = nil
	if self.onEndDrag then
		self.onEndDrag(input.point, InputBehavior.getModifiers(input))
	end
end

function ClickDragInputBehavior:forceEndCapture(input: any)
	local point = self._lastPoint or input.point
	self._lastPoint = nil
	if self.onCancelDrag then
		self.onCancelDrag()
	elseif self.onEndDrag then
		self.onEndDrag(point, InputBehavior.getModifiers(input))
	end
end

return ClickDragInputBehavior
