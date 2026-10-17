--[[
	Raise Polygon: draw a polygon on the terrain to raise a hill, plateau or
	mesa over it. See TerrainCurveTool for drawing and live adjusting.
]]

local SDK = require(script.Parent.Parent.SDK)
local TerrainCurveTool = require(script.Parent.Parent.Shared.TerrainCurveTool)
local TerrainSettings = require(script.Parent.Parent.Shared.TerrainSettings)

local RaisePolygon = TerrainCurveTool:extend({
	apiVersion = 1,
	id = "RaisePolygon",
	name = "Raise Polygon",
	version = "0.1.0",
	description = "Draw a polygon on the terrain (drag, or click its points) to raise a hill over it. Settings changed afterwards adjust the hill.",
	order = 120,
	curveKind = "polygon",
	settings = TerrainCurveTool.settingsWith({
		{ key = "height", label = "Height", type = "number", default = 40, min = 0, max = 400, step = 0.5, extended = { widget = "slider" }, tooltip = "How much the middle of the polygon is raised, in studs." },
		{ key = "falloff", label = "Falloff", type = "enum", options = TerrainSettings.FALLOFFS, default = "Smooth", tooltip = TerrainSettings.FALLOFF_TOOLTIP },
		{ key = "falloffWidth", label = "Falloff width", type = "number", default = 0, min = 0, max = 400, step = 1, extended = { widget = "slider" }, tooltip = "How far in from the edge the slope reaches full height, in studs. 0: to the middle of the polygon." },
		{ key = "maxHeight", label = "Plateau at", type = "number", default = 0, min = 0, max = 400, step = 0.5, extended = { widget = "slider" }, tooltip = "Caps the raise at this many studs, for a flat top (a mesa). 0: no cap." },
		{ key = "mode", label = "Mode", type = "enum", options = TerrainSettings.RAISE_MODES, default = "Add", tooltip = "Add: raise the terrain as it is. Max: raise it to the curve's height plus the hill, leaving higher ground alone. Smooth max: the same, with rounded seams. Replace: set it to the curve's height plus the hill. The curve's height is that of its lowest point." },
		{ key = "material", label = "Material", type = "enum", options = TerrainSettings.MATERIALS_AUTO, default = "Auto", tooltip = "Material of the raised terrain. Auto: the material of the surface below." },
	}, "polygon"),
})

function RaisePolygon:buildEdits(curve: TerrainCurveTool.Curve): { TerrainCurveTool.Edit }
	local s = self.ctx.settings
	return {
		{
			fn = SDK.Terrain.raise,
			shape = self:shapeOf(curve),
			options = {
				height = s.height,
				falloff = TerrainSettings.falloff(s.falloff),
				falloffWidth = if s.falloffWidth > 0 then s.falloffWidth else nil,
				maxHeight = if s.maxHeight > 0 then s.maxHeight else nil,
				mode = TerrainSettings.mode(s.mode),
				base = curve.planeY,
				material = TerrainSettings.material(s.material),
			},
		},
	}
end

return RaisePolygon
