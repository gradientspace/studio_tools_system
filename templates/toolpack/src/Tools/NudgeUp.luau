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

	-- Hit test shared by both behaviors: the distance to the part under the
	-- point, or nil if there's none.
	local function hitTest(point: SDK.InputPoint): number?
		local part, hit = ctx:partAt(point)
		return if part and hit then hit.Distance else nil
	end

	-- Highlight the part under the mouse.
	self:addInputBehavior(SDK.HoverInputBehavior:new({
		hitTest = hitTest,
		onUpdateHover = function(point)
			highlight.Adornee = ctx:partAt(point)
		end,
		onEndHover = function()
			highlight.Adornee = nil
		end,
	}))

	-- Click a part to nudge it.
	self:addInputBehavior(SDK.SingleClickInputBehavior:new({
		hitTest = hitTest,
		onClick = function(point)
			local part = ctx:partAt(point)
			if part then
				ctx:recordUndo("Nudge Up", function()
					part.CFrame += Vector3.new(0, ctx.settings.step, 0)
				end)
			end
		end,
	}))
end

return NudgeUp
