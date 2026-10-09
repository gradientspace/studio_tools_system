--[[
	Erase: click parts to delete them.
]]

local Blocks = require(script.Parent.Parent.Shared.Blocks)
local PartPickerTool = require(script.Parent.Parent.Shared.PartPickerTool)

local EraseBlock = PartPickerTool:extend({
	apiVersion = 1,
	id = "EraseBlock",
	version = "1.1.0",
	name = "Erase",
	description = "Click a part to delete it. By default only blocks created with Place Block can be erased.",
	order = 30,
	highlightColor = Color3.fromRGB(255, 70, 70),
	settings = {
		{ key = "blocksOnly", label = "Blocks Only", type = "boolean", default = true },
	},
})

function EraseBlock:canPick(part: BasePart): boolean
	return not self.ctx.settings.blocksOnly or Blocks.isBlock(part)
end

function EraseBlock:onPick(part: BasePart)
	self.ctx:recordUndo("Erase Block", function()
		-- Reparent rather than Destroy so undo can restore it.
		part.Parent = nil
	end)
end

return EraseBlock
