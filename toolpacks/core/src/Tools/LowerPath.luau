--[[
	Lower Path: draw a path on the terrain to carve a trench, valley or
	river bed along it, optionally filled with water. See TerrainCurveTool
	for drawing and live adjusting.
]]

local SDK = require(script.Parent.Parent.SDK)
local TerrainCurveTool = require(script.Parent.Parent.Shared.TerrainCurveTool)
local TerrainSettings = require(script.Parent.Parent.Shared.TerrainSettings)

local LowerPath = TerrainCurveTool:extend({
	apiVersion = 1,
	id = "LowerPath",
	name = "Lower Path",
	version = "0.1.0",
	description = "Draw a path on the terrain (drag, or click its points; end on the first point for a loop) to carve a trench or river bed along it. Settings changed afterwards adjust it.",
	order = 150,
	curveKind = "path",
	curveColor = Color3.fromRGB(90, 180, 255),
	settings = TerrainCurveTool.settingsWith({
		{ key = "depth", label = "Depth", type = "number", default = 10, min = 0, max = 400, step = 0.5, extended = { widget = "slider" }, tooltip = "How much the terrain along the path is lowered, in studs." },
		{ key = "radius", label = "Bottom half-width", type = "number", default = 4, min = 0, max = 200, step = 0.5, extended = { widget = "slider" }, tooltip = "Half the width of the full-depth bottom, in studs." },
		{ key = "falloffWidth", label = "Falloff width", type = "number", default = 12, min = 1, max = 400, step = 1, extended = { widget = "slider" }, tooltip = "How wide each bank is, in studs." },
		{ key = "falloff", label = "Falloff", type = "enum", options = TerrainSettings.FALLOFFS, default = "Smoothstep", tooltip = TerrainSettings.FALLOFF_TOOLTIP },
		{ key = "maxDepth", label = "Flat bottom at", type = "number", default = 0, min = 0, max = 400, step = 0.5, extended = { widget = "slider" }, tooltip = "Caps the depth at this many studs. 0: no cap." },
		{ key = "endWidth", label = "Width at end", type = "number", default = 1, min = 0.1, max = 5, step = 0.05, extended = { widget = "slider" }, tooltip = "Scales the width from the start of the path (1) to its end (this value)." },
		{ key = "endDepth", label = "Depth at end", type = "number", default = 1, min = 0, max = 5, step = 0.05, extended = { widget = "slider" }, tooltip = "Scales the depth from the start of the path (1) to its end (this value)." },
		{ key = "mode", label = "Mode", type = "enum", options = TerrainSettings.LOWER_MODES, default = "Subtract", tooltip = "Subtract: lower the terrain as it is. Min: lower it to the curve's height minus the trench, leaving lower ground alone. Smooth min: the same, with rounded seams. Replace: set it to the curve's height minus the trench. The curve's height is that of its lowest point." },
		{ key = "keepLayers", label = "Push down", type = "boolean", default = true, tooltip = "On: the top of the terrain is pushed down, so thin terrain (a bridge, an overhang) sinks instead of being cut through. Off: cut it away." },
		{ key = "material", label = "Bed material", type = "enum", options = TerrainSettings.MATERIALS_AUTO, default = "Auto", tooltip = "Material of the lowered surface. Auto: unchanged." },
		{ key = "fillWater", label = "Fill with water", type = "boolean", default = false, tooltip = "Fill the trench with water. The water surface follows the height the path was drawn at, so a river can run downhill." },
		{ key = "waterBelow", label = "Water below path", type = "number", default = 2, min = 0, max = 100, step = 0.5, tooltip = "How far below the drawn path the water surface is, in studs." },
	}, "path"),
})

function LowerPath:activate(ctx: SDK.ToolContext)
	TerrainCurveTool.activate(self, ctx)
	local function refresh()
		ctx:setSettingState("waterBelow", { enabled = ctx.settings.fillWater })
	end
	refresh()
	ctx:onSettingChanged(refresh)
end

function LowerPath:buildEdits(curve: TerrainCurveTool.Curve): { TerrainCurveTool.Edit }
	local s = self.ctx.settings
	local widthScale = if s.endWidth ~= 1 then { 1, s.endWidth } else nil
	local edits: { TerrainCurveTool.Edit } = {
		{
			fn = SDK.Terrain.lower,
			shape = self:shapeOf(curve, {
				radius = s.radius,
				widthScale = widthScale,
				heightScale = if s.endDepth ~= 1 then { 1, s.endDepth } else nil,
			}),
			options = {
				height = s.depth,
				falloff = TerrainSettings.falloff(s.falloff),
				falloffWidth = s.falloffWidth,
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
		-- water along the bed and the lower half of the banks, at the drawn height
		table.insert(edits, {
			fn = SDK.Terrain.fill,
			shape = self:shapeOf(curve, { radius = s.radius + s.falloffWidth / 2, widthScale = widthScale }, true),
			options = { level = "path", levelOffset = -s.waterBelow },
		})
	end
	return edits
end

return LowerPath
