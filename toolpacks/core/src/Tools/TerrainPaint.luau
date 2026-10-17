--[[
	Paint Terrain: paint a material onto the terrain with a brush, down to
	a depth below the surface. Can be limited to slopes in a range (e.g.
	rock on steep sides only) and to one material already there.
	Ctrl/Cmd+click picks up the material under the cursor. See
	TerrainBrushTool for strokes and the cursor.
]]

local SDK = require(script.Parent.Parent.SDK)
local TerrainBrushTool = require(script.Parent.Parent.Shared.TerrainBrushTool)
local TerrainPicking = require(script.Parent.Parent.Shared.TerrainPicking)
local TerrainSettings = require(script.Parent.Parent.Shared.TerrainSettings)

local Terrain = SDK.Terrain

local TerrainPaint = TerrainBrushTool:extend({
	apiVersion = 1,
	id = "TerrainPaint",
	name = "Paint Terrain",
	version = "0.1.0",
	description = "Paint a terrain material with a brush, optionally only on slopes in a range or over one material. Ctrl+click picks up a material.",
	order = 160,
	settings = {
		{ key = "material", label = "Material", type = "enum", options = TerrainSettings.MATERIALS, default = "Rock", tooltip = "The material to paint. Ctrl/Cmd+click on the terrain picks it up." },
		{ key = "radius", label = "Radius", type = "number", default = 12, min = 2, max = 200, step = 0.5, extended = { widget = "slider" }, tooltip = "Brush radius in studs. [ and ] change it." },
		{ key = "depth", label = "Depth", type = "number", default = 4, min = 1, max = 64, step = 1, tooltip = "How deep below the surface the material goes, in studs." },
		{ key = "softEdge", label = "Soft edge", type = "boolean", default = false, tooltip = "Scatter the outer half of the brush, for a ragged edge instead of a clean one." },
		{ key = "minSlope", label = "Min slope", type = "number", default = 0, min = 0, max = 90, step = 1, extended = { widget = "slider" }, tooltip = "Only paint where the terrain is at least this steep, in degrees." },
		{ key = "maxSlope", label = "Max slope", type = "number", default = 90, min = 0, max = 90, step = 1, extended = { widget = "slider" }, tooltip = "Only paint where the terrain is at most this steep, in degrees." },
		{ key = "onlyOver", label = "Only over", type = "enum", options = { "Any", table.unpack(TerrainSettings.MATERIALS) }, default = "Any", tooltip = "Only paint over this material. Any: every material." },
		{ key = "help", label = "Ctrl/Cmd+click: pick up a material · [ ]: size · C: center the view", type = "label" },
	},
})

function TerrainPaint:cursorColor(modifiers: SDK.Modifiers): Color3
	if modifiers.ctrl or modifiers.cmd then
		return Color3.fromRGB(255, 255, 255)
	end
	return Color3.fromRGB(255, 160, 60)
end

function TerrainPaint:activate(ctx: SDK.ToolContext)
	TerrainBrushTool.activate(self, ctx)
	ctx:setStatus("Drag on the terrain to paint it.")
end

-- Ctrl/Cmd+click: pick up the material under the cursor instead.
function TerrainPaint:beginStroke(stroke: any, modifiers: SDK.Modifiers): boolean?
	if not (modifiers.ctrl or modifiers.cmd) then
		return true
	end
	local ray = stroke.ray
	local hit = TerrainPicking.raycast(ray.Origin, ray.Direction)
	local name = hit and hit.Material.Name
	if name and table.find(TerrainSettings.MATERIALS, name) then
		self.ctx:setSetting("material", name)
		self.ctx:setStatus("Picked up " .. name .. ".")
	end
	return false
end

function TerrainPaint:applyStroke(stroke: any, centers: { Vector3 }, _dt: number, _modifiers: SDK.Modifiers)
	-- painting again where it's already painted changes nothing, so only new positions count
	if stroke.painted and centers[1] == stroke.painted then
		return
	end
	stroke.painted = centers[#centers]
	local settings = self.ctx.settings
	local radius = settings.radius
	local points = table.create(#centers)
	for i, c in centers do
		points[i] = Vector2.new(c.X, c.Z)
	end
	local soft = settings.softEdge
	local only = TerrainSettings.material(if settings.onlyOver == "Any" then nil else settings.onlyOver)
	Terrain.paint(Terrain.path(points, { radius = if soft then radius / 2 else radius }), {
		material = TerrainSettings.material(settings.material) or Enum.Material.Rock,
		depth = settings.depth,
		falloff = if soft then "linear" else nil,
		falloffWidth = if soft then radius / 2 else nil,
		dither = soft,
		onlyMaterials = if only then { only } else nil,
		minSlope = if settings.minSlope > 0 then settings.minSlope else nil,
		maxSlope = if settings.maxSlope < 90 then settings.maxSlope else nil,
	})
end

return TerrainPaint
