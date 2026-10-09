--[[
	Paint: click (or click and drag) over parts to set their color.

	An Accept/Cancel tool: everything painted while the tool is active is one
	undo recording. Accept keeps it, Cancel reverts it (after confirming, if
	anything was painted). Accept is disabled until something is painted.

	"Painted" means "differs from how it was when this session first touched
	it": the tool remembers each part's original color/material and recounts
	after undo/redo, so its state stays right however undo affects the parts.

	Extends PartPickerTool, replacing its click with a ClickDragInputBehavior:
	pressing on a part paints it, and dragging paints every part the mouse
	crosses until the button is released.
]]

local SDK = require(script.Parent.Parent.SDK)
local Blocks = require(script.Parent.Parent.Shared.Blocks)
local PartPickerTool = require(script.Parent.Parent.Shared.PartPickerTool)

local PaintBlock = PartPickerTool:extend({
	apiVersion = 1,
	id = "PaintBlock",
	version = "1.2.0",
	name = "Paint",
	description = "Click or drag across parts to paint them. Accept keeps the painting; Cancel reverts it. Locked parts are skipped.",
	order = 20,
	settings = {
		{ key = "color", label = "Color", type = "color", default = Color3.fromRGB(196, 40, 28) },
		{ key = "blocksOnly", label = "Blocks Only", type = "boolean", default = false },
		{ key = "setMaterial", label = "Set Material", type = "boolean", default = false },
		{ key = "material", label = "Material", type = "enum", options = Blocks.MATERIALS, default = "SmoothPlastic" },
	},
	shutdown = {
		type = SDK.ShutdownType.AcceptCancel,
		accept = { tooltip = "Keep the painted colors" },
		cancel = { tooltip = "Revert everything painted since Paint was started (Esc)" },
	},
})

function PaintBlock:canPick(part: BasePart): boolean
	return not self.ctx.settings.blocksOnly or Blocks.isBlock(part)
end

-- Counts parts that currently differ from their original color/material.
function PaintBlock:recount()
	local count = 0
	for part, original in self.originals do
		if part.Parent ~= nil and (part.Color ~= original.color or part.Material ~= original.material) then
			count += 1
		end
	end
	self.paintedCount = count
end

function PaintBlock:paint(part: BasePart)
	if not self.originals[part] then
		self.originals[part] = { color = part.Color, material = part.Material }
	end
	local settings = self.ctx.settings
	part.Color = settings.color
	if settings.setMaterial then
		part.Material = (Enum.Material :: any)[settings.material]
	end
	self:recount()
end

-- Paints the pickable part at the point, if any.
function PaintBlock:paintAt(point: SDK.InputPoint)
	local part = self:getTarget(point)
	self:setHighlight(part)
	if part then
		self:paint(part)
		self.ctx:refreshShutdownButtons()
	end
end

-- The highlight shows the paint color.
function PaintBlock:setHighlight(part: BasePart?)
	local color = self.ctx.settings.color
	self.highlight.Color3 = color
	self.highlight.SurfaceColor3 = color
	PartPickerTool.setHighlight(self, part)
end

function PaintBlock:createPickBehavior(): SDK.InputBehavior
	return SDK.ClickDragInputBehavior:new({
		id = "Paint",
		hitTest = function(point)
			return self:hitTest(point)
		end,
		onBeginDrag = function(point)
			self:paintAt(point)
		end,
		onUpdateDrag = function(point)
			self:paintAt(point)
		end,
	})
end

function PaintBlock:canAccept(): (boolean, string?)
	if self.paintedCount == 0 then
		return false, "Nothing painted yet"
	end
	return true, nil
end

function PaintBlock:confirmShutdown(reason: SDK.ShutdownReason, _trigger: SDK.ShutdownTrigger): boolean
	if reason == SDK.ShutdownReason.Cancel and self.paintedCount > 0 then
		return self.ctx:confirm({
			title = "Discard painting?",
			message = string.format(
				"This reverts the %d part%s painted since Paint was started.",
				self.paintedCount,
				if self.paintedCount == 1 then "" else "s"
			),
			confirmText = "Discard",
			cancelText = "Keep Painting",
		})
	end
	return true
end

function PaintBlock:activate(ctx: SDK.ToolContext)
	self.originals = {} -- part -> { color, material } before this session touched it
	self.paintedCount = 0
	-- One recording for the whole session: cancelling it reverts the painting.
	self.session = ctx:beginUndo("Paint")

	PartPickerTool.activate(self, ctx)
	ctx:onUndoRedo(function(action, waypoint)
		self:recount()
		ctx:refreshShutdownButtons()
		ctx:log(string.format("%s '%s' during paint session; %d part(s) now painted", action, waypoint, self.paintedCount))
	end)
end

function PaintBlock:deactivate(_ctx: SDK.ToolContext, reason: SDK.ShutdownReason)
	-- Force (switching tools etc.) keeps the painting, like Studio's own tools.
	if reason == SDK.ShutdownReason.Cancel then
		self.session.cancel()
	else
		self.session.commit()
	end
end

return PaintBlock
