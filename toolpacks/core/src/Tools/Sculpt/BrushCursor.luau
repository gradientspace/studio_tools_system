--[[
	BrushCursor: a ring showing the brush's size on the surface, drawn on
	top of everything (so it can't sink into the mesh), plus a dot at its
	center. The ring is made of line segments: CylinderHandleAdornment
	rings (InnerRadius) don't render.
]]

local SDK = require(script.Parent.Parent.Parent.SDK)

local SEGMENTS = 40
local THICKNESS = 2.5

local BrushCursor = {}
BrushCursor.__index = BrushCursor

function BrushCursor.new(ctx: SDK.ToolContext)
	local self = setmetatable({}, BrushCursor)
	self.lines = {} :: { LineHandleAdornment }
	for i = 1, SEGMENTS do
		local line = ctx:createAdornment("LineHandleAdornment") :: LineHandleAdornment
		line.Thickness = THICKNESS
		line.AlwaysOnTop = true
		line.ZIndex = 1
		line.Visible = false
		self.lines[i] = line
	end
	local dot = ctx:createAdornment("SphereHandleAdornment") :: SphereHandleAdornment
	dot.AlwaysOnTop = true
	dot.ZIndex = 1
	dot.Visible = false
	self.dot = dot
	self.visible = false
	return self
end

-- Shows the ring around `center` (world space) in the plane facing `normal`.
function BrushCursor:show(center: Vector3, normal: Vector3, radius: number, color: Color3)
	local n = if normal.Magnitude > 1e-6 then normal.Unit else Vector3.yAxis
	local helper = if math.abs(n.Y) < 0.9 then Vector3.yAxis else Vector3.xAxis
	local u = n:Cross(helper).Unit
	local w = n:Cross(u)
	-- lift slightly off the surface so the ring reads as lying on it
	local origin = center + n * (radius * 0.02)
	local previous = origin + u * radius
	for i = 1, SEGMENTS do
		local angle = i / SEGMENTS * math.pi * 2
		local point = origin + (u * math.cos(angle) + w * math.sin(angle)) * radius
		local line = self.lines[i]
		line.CFrame = CFrame.lookAt(previous, point)
		line.Length = (point - previous).Magnitude
		line.Color3 = color
		line.Visible = true
		previous = point
	end
	self.dot.CFrame = CFrame.new(center)
	self.dot.Radius = math.max(radius * 0.04, 0.01)
	self.dot.Color3 = color
	self.dot.Visible = true
	self.visible = true
end

function BrushCursor:hide()
	if not self.visible then
		return
	end
	self.visible = false
	for _, line in self.lines do
		line.Visible = false
	end
	self.dot.Visible = false
end

return BrushCursor
