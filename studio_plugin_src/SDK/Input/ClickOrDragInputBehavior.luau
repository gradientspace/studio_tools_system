--[[
	ClickOrDragInputBehavior: a click, or a drag if the mouse moves far
	enough while the button is held.

		SDK.ClickOrDragInputBehavior:new({
			hitTest = function(point) return depth or nil end,
			onClick = function(point, modifiers) ... end,
			onBeginDrag = function(point, modifiers) ... end,   -- at the press point
			onUpdateDrag = function(point, modifiers) ... end,
			onEndDrag = function(point, modifiers) ... end,
			onCancelDrag = function() ... end,                  -- optional
			dragThreshold = 4,                                  -- optional, pixels
			button = "Left",                                    -- optional; or "Middle" / "Right"
		})

	Releasing within dragThreshold pixels of the press is a click, and as
	with SingleClickInputBehavior it only fires if hitTest still hits on
	release. Once the mouse moves further, the drag begins with onBeginDrag
	at the press point, followed by onUpdateDrag at the current one; from
	then on it works like ClickDragInputBehavior.
]]

local InputBehavior = require(script.Parent.InputBehavior)

local ClickOrDragInputBehavior = InputBehavior:extend({
	id = "ClickOrDrag",
	button = "Left",
	dragThreshold = 4,
})

function ClickOrDragInputBehavior:wantsCapture(input: any): any
	if not InputBehavior.getButton(input, self.button).pressed then
		return nil
	end
	return InputBehavior.requestIfHit(self.hitTest, input.point)
end

function ClickOrDragInputBehavior:beginCapture(input: any): string
	self._pressPoint = input.point
	self._lastPoint = input.point
	self._dragging = false
	return "Begin"
end

function ClickOrDragInputBehavior:updateCapture(input: any): string
	local modifiers = InputBehavior.getModifiers(input)
	if not self._dragging and (input.point.position - self._pressPoint.position).Magnitude > self.dragThreshold then
		self._dragging = true
		if self.onBeginDrag then
			self.onBeginDrag(self._pressPoint, modifiers)
		end
	end
	if self._dragging then
		self._lastPoint = input.point
		if self.onUpdateDrag then
			self.onUpdateDrag(input.point, modifiers)
		end
	end
	return if InputBehavior.getButton(input, self.button).down then "Continue" else "End"
end

function ClickOrDragInputBehavior:endCapture(input: any)
	local modifiers = InputBehavior.getModifiers(input)
	if self._dragging then
		self._dragging = false
		if self.onEndDrag then
			self.onEndDrag(input.point, modifiers)
		end
	elseif self.onClick and InputBehavior.requestIfHit(self.hitTest, input.point) then
		self.onClick(input.point, modifiers)
	end
end

function ClickOrDragInputBehavior:forceEndCapture(input: any)
	if not self._dragging then
		return -- a pending click is simply dropped
	end
	self._dragging = false
	if self.onCancelDrag then
		self.onCancelDrag()
	elseif self.onEndDrag then
		self.onEndDrag(self._lastPoint or input.point, InputBehavior.getModifiers(input))
	end
end

return ClickOrDragInputBehavior
