--[[
	Lower Polygon: draw a polygon on the terrain to lower it into a basin,
	optionally filled with water (a lake). See TerrainCurveTool for drawing
	and live adjusting.
]]

local SDK = require(script.Parent.Parent.SDK)
local TerrainCurveTool = require(script.Parent.Parent.Shared.TerrainCurveTool)
local TerrainSettings = require(script.Parent.Parent.Shared.TerrainSettings)

local LowerPolygon = TerrainCurveTool:extend({
	apiVersion = 1,
	id = "LowerPolygon",
	name = "Lower Polygon",
	version = "0.1.0",
	description = "Draw a polygon on the terrain (drag, or click its points) to lower it into a basin, optionally filled with water. Settings changed afterwards adjust it.",
	order = 130,
	curveKind = "polygon",
	curveColor = Color3.fromRGB(90, 180, 255),
	settings = TerrainCurveTool.settingsWith({
		{ key = "depth", label = "Depth", type = "number", default = 20, min = 0, max = 400, step = 0.5, extended = { widget = "slider" }, tooltip = "How much the middle of the polygon is lowered, in studs." },
		{ key = "falloff", label = "Falloff", type = "enum", options = TerrainSettings.FALLOFFS, default = "Smooth", tooltip = TerrainSettings.FALLOFF_TOOLTIP },
		{ key = "falloffWidth", label = "Falloff width", type = "number", default = 0, min = 0, max = 400, step = 1, extended = { widget = "slider" }, tooltip = "How far in from the edge the slope reaches full depth, in studs. 0: to the middle of the polygon." },
		{ key = "maxDepth", label = "Flat bottom at", type = "number", default = 0, min = 0, max = 400, step = 0.5, extended = { widget = "slider" }, tooltip = "Caps the depth at this many studs, for a flat bottom. 0: no cap." },
		{ key = "mode", label = "Mode", type = "enum", options = TerrainSettings.LOWER_MODES, default = "Subtract", tooltip = "Subtract: lower the terrain as it is. Min: lower it to the curve's height minus the basin, leaving lower ground alone. Smooth min: the same, with rounded seams. Replace: set it to the curve's height minus the basin. The curve's height is that of its lowest point." },
		{ key = "keepLayers", label = "Push down", type = "boolean", default = true, tooltip = "On: the top of the terrain is pushed down, so thin terrain (a bridge, an overhang) sinks instead of being cut through. Off: cut it away." },
		{ key = "material", label = "Floor material", type = "enum", options = TerrainSettings.MATERIALS_AUTO, default = "Auto", tooltip = "Material of the lowered surface. Auto: unchanged." },
		{ key = "fillWater", label = "Fill with water", type = "boolean", default = false, tooltip = "Fill the basin with water, up to just below the lowest point of its rim." },
		{ key = "waterBelowRim", label = "Water below rim", type = "number", default = 1, min = 0, max = 100, step = 0.5, tooltip = "How far below the lowest point of the rim the water surface is, in studs." },
	}, "polygon"),
})

function LowerPolygon:activate(ctx: SDK.ToolContext)
	TerrainCurveTool.activate(self, ctx)
	local function refresh()
		ctx:setSettingState("waterBelowRim", { enabled = ctx.settings.fillWater })
	end
	refresh()
	ctx:onSettingChanged(refresh)
end

function LowerPolygon:buildEdits(curve: TerrainCurveTool.Curve): { TerrainCurveTool.Edit }
	local s = self.ctx.settings
	local shape = self:shapeOf(curve)
	local edits: { TerrainCurveTool.Edit } = {
		{
			fn = SDK.Terrain.lower,
			shape = shape,
			options = {
				height = s.depth,
				falloff = TerrainSettings.falloff(s.falloff),
				falloffWidth = if s.falloffWidth > 0 then s.falloffWidth else nil,
				maxHeight = if s.maxDepth > 0 then s.maxDepth else nil,
				mode = TerrainSettings.mode(s.mode),
				base = curve.planeY,
				material = TerrainSettings.material(s.material),
				pushDepth = if s.keepLayers then nil else 0,
				compressionDepth = if s.keepLayers then nil else 0,
			},
		},
	}
	if s.fillWater then
		table.insert(edits, {
			fn = SDK.Terrain.fill,
			shape = shape,
			options = { level = "boundaryMin", levelOffset = -s.waterBelowRim },
		})
	end
	return edits
end

return LowerPolygon
