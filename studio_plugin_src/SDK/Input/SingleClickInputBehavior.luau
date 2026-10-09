--[[
	SingleClickInputBehavior: a press and release on a target.

		SDK.SingleClickInputBehavior:new({
			hitTest = function(point) return depth or nil end,
			onClick = function(point, modifiers) ... end,
			button = "Left",   -- optional; or "Middle"
		})

	hitTest decides whether a press is on a target (and how near it is).
	It's called again on release, and onClick only fires if the release
	still hits, so the user can cancel by moving off the target.
]]

local InputBehavior = require(script.Parent.InputBehavior)

local SingleClickInputBehavior = InputBehavior:extend({
	id = "SingleClick",
	button = "Left",
})

function SingleClickInputBehavior:wantsCapture(input: any): any
	if not InputBehavior.getButton(input, self.button).pressed then
		return nil
	end
	return InputBehavior.requestIfHit(self.hitTest, input.point)
end

function SingleClickInputBehavior:beginCapture(_input: any): string
	return "Begin"
end

function SingleClickInputBehavior:updateCapture(input: any): string
	return if InputBehavior.getButton(input, self.button).down then "Continue" else "End"
end

function SingleClickInputBehavior:endCapture(input: any)
	if self.onClick and InputBehavior.requestIfHit(self.hitTest, input.point) then
		self.onClick(input.point, InputBehavior.getModifiers(input))
	end
end

return SingleClickInputBehavior
