--[[
	Raise Path: draw a path on the terrain to raise a ridge, dam or
	embankment along it. See TerrainCurveTool for drawing and live
	adjusting.
]]

local SDK = require(script.Parent.Parent.SDK)
local TerrainCurveTool = require(script.Parent.Parent.Shared.TerrainCurveTool)
local TerrainSettings = require(script.Parent.Parent.Shared.TerrainSettings)

local RaisePath = TerrainCurveTool:extend({
	apiVersion = 1,
	id = "RaisePath",
	name = "Raise Path",
	version = "0.1.0",
	description = "Draw a path on the terrain (drag, or click its points; end on the first point for a loop) to raise a ridge along it. Settings changed afterwards adjust it.",
	order = 140,
	curveKind = "path",
	settings = TerrainCurveTool.settingsWith({
		{ key = "height", label = "Height", type = "number", default = 20, min = 0, max = 400, step = 0.5, extended = { widget = "slider" }, tooltip = "How much the terrain along the path is raised, in studs." },
		{ key = "radius", label = "Top half-width", type = "number", default = 4, min = 0, max = 200, step = 0.5, extended = { widget = "slider" }, tooltip = "Half the width of the full-height top of the ridge, in studs." },
		{ key = "falloffWidth", label = "Falloff width", type = "number", default = 24, min = 1, max = 400, step = 1, extended = { widget = "slider" }, tooltip = "How wide each side slope is, in studs." },
		{ key = "falloff", label = "Falloff", type = "enum", options = TerrainSettings.FALLOFFS, default = "Smoothstep", tooltip = TerrainSettings.FALLOFF_TOOLTIP },
		{ key = "maxHeight", label = "Plateau at", type = "number", default = 0, min = 0, max = 400, step = 0.5, extended = { widget = "slider" }, tooltip = "Caps the raise at this many studs, for a flat top. 0: no cap." },
		{ key = "endWidth", label = "Width at end", type = "number", default = 1, min = 0.1, max = 5, step = 0.05, extended = { widget = "slider" }, tooltip = "Scales the width from the start of the path (1) to its end (this value)." },
		{ key = "endHeight", label = "Height at end", type = "number", default = 1, min = 0, max = 5, step = 0.05, extended = { widget = "slider" }, tooltip = "Scales the height from the start of the path (1) to its end (this value)." },
		{ key = "mode", label = "Mode", type = "enum", options = TerrainSettings.RAISE_MODES, default = "Add", tooltip = "Add: raise the terrain as it is. Max: raise it to the curve's height plus the ridge, leaving higher ground alone. Smooth max: the same, with rounded seams. Replace: set it to the curve's height plus the ridge. The curve's height is that of its lowest point." },
		{ key = "material", label = "Material", type = "enum", options = TerrainSettings.MATERIALS_AUTO, default = "Auto", tooltip = "Material of the raised terrain. Auto: the material of the surface below." },
	}, "path"),
})

function RaisePath:buildEdits(curve: TerrainCurveTool.Curve): { TerrainCurveTool.Edit }
	local s = self.ctx.settings
	local shape = self:shapeOf(curve, {
		radius = s.radius,
		widthScale = if s.endWidth ~= 1 then { 1, s.endWidth } else nil,
		heightScale = if s.endHeight ~= 1 then { 1, s.endHeight } else nil,
	})
	return {
		{
			fn = SDK.Terrain.raise,
			shape = shape,
			options = {
				height = s.height,
				falloff = TerrainSettings.falloff(s.falloff),
				falloffWidth = s.falloffWidth,
				maxHeight = if s.maxHeight > 0 then s.maxHeight else nil,
				mode = TerrainSettings.mode(s.mode),
				base = curve.planeY,
				material = TerrainSettings.material(s.material),
			},
		},
	}
end

return RaisePath
