--[[
	HoverInputBehavior: hover only, never captures.

		SDK.HoverInputBehavior:new({
			hitTest = function(point) return depth or nil end,
			onBeginHover = function(point, modifiers) ... end,   -- optional; defaults to onUpdateHover
			onUpdateHover = function(point, modifiers) ... end,
			onEndHover = function() ... end,
		})

	Hovers while hitTest hits and no other behavior has a better hover
	request. onUpdateHover runs on every input update in between (mouse
	moves, modifier keys, camera moves and refreshes). Hover pauses while
	another behavior captures the mouse.
]]

local InputBehavior = require(script.Parent.InputBehavior)

local HoverInputBehavior = InputBehavior:extend({
	id = "Hover",
	enableHover = true,
})

function HoverInputBehavior:wantsHover(input: any): any
	return InputBehavior.requestIfHit(self.hitTest, input.point)
end

function HoverInputBehavior:beginHover(input: any): string
	local onBegin = self.onBeginHover or self.onUpdateHover
	if onBegin then
		onBegin(input.point, InputBehavior.getModifiers(input))
	end
	return "Begin"
end

function HoverInputBehavior:updateHover(input: any): string
	if self.onUpdateHover then
		self.onUpdateHover(input.point, InputBehavior.getModifiers(input))
	end
	return "Continue"
end

function HoverInputBehavior:endHover(_input: any)
	if self.onEndHover then
		self.onEndHover()
	end
end

return HoverInputBehavior
