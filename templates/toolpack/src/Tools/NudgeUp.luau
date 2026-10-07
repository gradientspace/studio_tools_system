--[[
	Nudge Up: an example tool. Click a part to move it up by a fixed step.
	Replace or delete this once the pack has real tools.
]]

local SDK = require(script.Parent.Parent.SDK)

local NudgeUp = SDK.Tool:extend({
	apiVersion = {{API_VERSION}},
	id = "NudgeUp",
	version = "0.1.0",
	name = "Nudge Up",
	description = "Click a part to move it up. Locked parts are skipped.",
	order = 10,
	settings = {
		{ key = "step", label = "Step", type = "number", default = 1, min = 0.1, max = 64, step = 0.1 },
	},
})

function NudgeUp:activate(ctx: SDK.ToolContext)
	local highlight = ctx:createHighlight()

	ctx:onMouseMove(function()
		highlight.Adornee = ctx:partUnderMouse()
	end)

	ctx:onMouseDown(function()
		local part = ctx:partUnderMouse()
		if not part then
			return
		end
		ctx:recordUndo("Nudge Up", function()
			part.CFrame += Vector3.new(0, ctx.settings.step, 0)
		end)
	end)
end

return NudgeUp
