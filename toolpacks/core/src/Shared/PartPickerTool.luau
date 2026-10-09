--[[
	PartPickerTool: base class for tools that act on the part under the
	mouse. It highlights the pickable part under the cursor (a hover
	behavior), and adds the input behavior from createPickBehavior(): by
	default a click that calls onPick(part).

	Subclasses override:
	  onPick(part)            called when a pickable part is clicked (with the default pick behavior)
	  canPick(part)           optional filter (default: any unlocked, non-terrain part)
	  createPickBehavior()    optional; return a different input behavior, e.g. a ClickDragInputBehavior
	  setHighlight(part)      optional; call PartPickerTool.setHighlight(self, part) to keep the default
	  highlightColor          optional class field

	Helpers for subclasses: getTarget(point) and hitTest(point).

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

-- The pickable part at an input point, if any, and the raycast hit.
function PartPickerTool:getTarget(point: SDK.InputPoint): (BasePart?, RaycastResult?)
	local part, hit = self.ctx:partAt(point)
	if part and self:canPick(part) then
		return part, hit
	end
	return nil, hit
end

-- Hit test for input behaviors: the distance to the pickable part at the point.
function PartPickerTool:hitTest(point: SDK.InputPoint): number?
	local part, hit = self:getTarget(point)
	return if part and hit then hit.Distance else nil
end

function PartPickerTool:setHighlight(part: BasePart?)
	self.highlight.Adornee = part
end

function PartPickerTool:createPickBehavior(): SDK.InputBehavior
	return SDK.SingleClickInputBehavior:new({
		id = "Pick",
		hitTest = function(point)
			return self:hitTest(point)
		end,
		onClick = function(point)
			local part = self:getTarget(point)
			if part then
				self:onPick(part)
			end
		end,
	})
end

function PartPickerTool:activate(ctx: SDK.ToolContext)
	self.highlight = ctx:createHighlight(self.highlightColor)
	self:addInputBehavior(SDK.HoverInputBehavior:new({
		id = "Highlight",
		hitTest = function(point)
			return self:hitTest(point)
		end,
		onUpdateHover = function(point)
			self:setHighlight(self:getTarget(point))
		end,
		onEndHover = function()
			self:setHighlight(nil)
		end,
	}))
	self:addInputBehavior(self:createPickBehavior())
end

return PartPickerTool
