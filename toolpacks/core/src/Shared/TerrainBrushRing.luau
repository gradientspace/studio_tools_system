--[[
	TerrainBrushRing: a brush cursor draped over the terrain: a ring of line
	segments whose points are dropped onto the surface (vertical raycasts),
	plus a dot at the center. Drawn on top of everything.
]]

local SDK = require(script.Parent.Parent.SDK)
local TerrainPicking = require(script.Parent.TerrainPicking)

local SEGMENTS = 48
local THICKNESS = 2.5
local LIFT = 0.3 -- studs above the surface

local TerrainBrushRing = {}
TerrainBrushRing.__index = TerrainBrushRing

function TerrainBrushRing.new(ctx: SDK.ToolContext)
	local self = setmetatable({}, TerrainBrushRing)
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

-- Shows the ring of `radius` studs around `center`, following the terrain.
function TerrainBrushRing:show(center: Vector3, radius: number, color: Color3)
	local above = center.Y + 2 * radius + 50
	local depth = 4 * radius + 100
	local points = table.create(SEGMENTS)
	for i = 1, SEGMENTS do
		local angle = i / SEGMENTS * math.pi * 2
		local x, z = center.X + math.cos(angle) * radius, center.Z + math.sin(angle) * radius
		local y = TerrainPicking.heightAt(x, z, above, depth) or center.Y
		points[i] = Vector3.new(x, y + LIFT, z)
	end
	local previous = points[SEGMENTS]
	for i, point in points do
		local line = self.lines[i]
		line.CFrame = CFrame.lookAt(previous, point)
		line.Length = (point - previous).Magnitude
		line.Color3 = color
		line.Visible = true
		previous = point
	end
	local cameraDistance = (workspace.CurrentCamera.CFrame.Position - center).Magnitude
	self.dot.CFrame = CFrame.new(center)
	self.dot.Radius = math.max(0.1, cameraDistance * 0.004)
	self.dot.Color3 = color
	self.dot.Visible = true
	self.visible = true
end

function TerrainBrushRing:hide()
	if not self.visible then
		return
	end
	self.visible = false
	for _, line in self.lines do
		line.Visible = false
	end
	self.dot.Visible = false
end

return TerrainBrushRing
