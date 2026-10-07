--[[
	Place Block: click on any surface to place a cube against it.
]]

local SDK = require(script.Parent.Parent.SDK)
local Blocks = require(script.Parent.Parent.Shared.Blocks)

local PlaceBlock = SDK.Tool:extend({
	apiVersion = 1,
	id = "PlaceBlock",
	version = "1.0.0",
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

function PlaceBlock:updatePreview()
	local settings = self.ctx.settings
	local hit = self.ctx:raycast()
	if not hit then
		self.targetCFrame = nil
		self.preview.Visible = false
		return
	end
	local position = hit.Position + hit.Normal * (settings.size / 2)
	if settings.snap then
		position = Blocks.snapCenter(position, settings.size)
	end
	self.targetCFrame = CFrame.new(position)
	self.preview.CFrame = self.targetCFrame
	self.preview.Size = Vector3.one * settings.size
	self.preview.Color3 = settings.color
	self.preview.Visible = true
end

function PlaceBlock:place()
	self:updatePreview()
	local cframe = self.targetCFrame
	if not cframe then
		return
	end
	local settings = self.ctx.settings
	self.ctx:recordUndo("Place Block", function()
		local part = Blocks.create(settings.size, cframe, settings.color, settings.material)
		part.Parent = workspace
	end)
	self:updatePreview()
end

function PlaceBlock:activate(ctx: SDK.ToolContext)
	self.preview = ctx:createBoxPreview()
	self.targetCFrame = nil

	ctx:onMouseMove(function()
		self:updatePreview()
	end)
	ctx:onSettingChanged(function()
		self:updatePreview()
	end)
	ctx:onUndoRedo(function()
		self:updatePreview()
	end)
	ctx:onMouseDown(function()
		self:place()
	end)

	self:updatePreview()
end

return PlaceBlock
