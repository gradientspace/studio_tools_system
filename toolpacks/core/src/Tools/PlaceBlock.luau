--[[
	Place Block: click on any surface to place a cube against it.
]]

local SDK = require(script.Parent.Parent.SDK)
local Blocks = require(script.Parent.Parent.Shared.Blocks)

local PlaceBlock = SDK.Tool:extend({
	apiVersion = 1,
	id = "PlaceBlock",
	version = "1.1.0",
	name = "Place Block",
	description = "Click a surface to place a block against it. With snapping on, blocks sit on a grid matching their size.",
	order = 10,
	settings = {
		{ key = "size", label = "Size", type = "number", default = 4, min = 0.5, max = 64, step = 0.5 },
		{ key = "snap", label = "Snap to Grid", type = "boolean", default = true },
		{ key = "color", label = "Color", type = "color", default = Color3.fromRGB(163, 162, 165) },
		{ key = "material", label = "Material", type = "enum", options = Blocks.MATERIALS, default = "SmoothPlastic" },
	},
})

-- Where a block would go for an input point, and the hit's distance (its
-- hit-test depth). nil if the ray hits nothing.
function PlaceBlock:targetAt(point: SDK.InputPoint): (CFrame?, number?)
	local hit = self.ctx:raycastAt(point)
	if not hit then
		return nil, nil
	end
	local size = self.ctx.settings.size
	local position = hit.Position + hit.Normal * (size / 2)
	if self.ctx.settings.snap then
		position = Blocks.snapCenter(position, size)
	end
	return CFrame.new(position), hit.Distance
end

-- Shows the preview for an input point, or hides it (nil).
function PlaceBlock:showPreview(point: SDK.InputPoint?)
	local cframe = if point then self:targetAt(point) else nil
	if not cframe then
		self.preview.Visible = false
		return
	end
	local settings = self.ctx.settings
	self.preview.CFrame = cframe
	self.preview.Size = Vector3.one * settings.size
	self.preview.Color3 = settings.color
	self.preview.Visible = true
end

function PlaceBlock:place(point: SDK.InputPoint)
	local cframe = self:targetAt(point)
	if not cframe then
		return
	end
	local settings = self.ctx.settings
	self.ctx:recordUndo("Place Block", function()
		local part = Blocks.create(settings.size, cframe, settings.color, settings.material)
		part.Parent = workspace
	end)
end

function PlaceBlock:activate(ctx: SDK.ToolContext)
	self.preview = ctx:createBoxPreview()

	local function hitTest(point: SDK.InputPoint): number?
		local _, depth = self:targetAt(point)
		return depth
	end
	-- The preview follows the mouse (and stays put while the button is held).
	self:addInputBehavior(SDK.HoverInputBehavior:new({
		id = "Preview",
		hitTest = hitTest,
		onUpdateHover = function(point)
			self:showPreview(point)
		end,
		onEndHover = function()
			self:showPreview(nil)
		end,
	}))
	-- Releasing over a surface places the block; the hover then moves the
	-- preview on top of it.
	self:addInputBehavior(SDK.SingleClickInputBehavior:new({
		id = "Place",
		hitTest = hitTest,
		onClick = function(point)
			self:place(point)
		end,
	}))
end

return PlaceBlock
