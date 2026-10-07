--[[
	PartPickerTool: base class for tools that hover-highlight a part under the
	mouse and do something when it's clicked.

	Subclasses override:
	  onPick(part)       required; called on mouse down over a pickable part
	  canPick(part)      optional filter (default: any unlocked, non-terrain part)
	  updateHover()      optional; call PartPickerTool.updateHover(self) to keep the default
	  highlightColor     optional class field

	Since this lives in Shared/ rather than Tools/, it isn't listed as a tool.
]]

local SDK = require(script.Parent.Parent.SDK)

local PartPickerTool = SDK.Tool:extend({
	apiVersion = 1,
	highlightColor = Color3.fromRGB(0, 170, 255),
})

function PartPickerTool:canPick(_part: BasePart): boolean
	return true
end

function PartPickerTool:onPick(_part: BasePart)
	error(string.format("tool '%s' must implement onPick()", tostring(self.id)), 2)
end

-- The pickable part under the mouse, if any.
function PartPickerTool:getTarget(): BasePart?
	local part = self.ctx:partUnderMouse()
	if part and self:canPick(part) then
		return part
	end
	return nil
end

function PartPickerTool:updateHover()
	self.highlight.Adornee = self:getTarget()
end

function PartPickerTool:activate(ctx: SDK.ToolContext)
	self.highlight = ctx:createHighlight(self.highlightColor)

	ctx:onMouseMove(function()
		self:updateHover()
	end)
	ctx:onSettingChanged(function()
		self:updateHover()
	end)
	-- Undo/redo can add, remove or change the part under the mouse.
	ctx:onUndoRedo(function()
		self:updateHover()
	end)
	ctx:onMouseDown(function()
		local part = self:getTarget()
		if part then
			self:onPick(part)
		end
		self:updateHover()
	end)

	self:updateHover()
end

return PartPickerTool
