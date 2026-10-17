--[[
	Terrain Brush: raise, lower, smooth or flatten the terrain by brushing
	over it. Raising and lowering build up while the mouse is held, at a
	rate set by the strength; flatten levels toward the height where the
	stroke started. See TerrainBrushTool for strokes and the cursor.
]]

local SDK = require(script.Parent.Parent.SDK)
local TerrainBrushTool = require(script.Parent.Parent.Shared.TerrainBrushTool)
local TerrainSettings = require(script.Parent.Parent.Shared.TerrainSettings)

local Terrain = SDK.Terrain

local RATE = 1.5 -- raise/lower speed at full strength, in radii per second
local SMOOTH_RATE = 6 -- smooth and flatten blend per second at full strength

local COLORS = {
	Raise = Color3.fromRGB(0, 170, 255),
	Lower = Color3.fromRGB(255, 95, 70),
	Smooth = Color3.fromRGB(80, 220, 120),
	Flatten = Color3.fromRGB(255, 200, 40),
}

local TerrainBrush = TerrainBrushTool:extend({
	apiVersion = 1,
	id = "TerrainBrush",
	name = "Terrain Brush",
	version = "0.1.0",
	description = "Raise, lower, smooth or flatten the terrain with a brush. Ctrl inverts, Shift smooths, [ and ] resize.",
	order = 110,
	settings = {
		{ key = "mode", label = "Brush", type = "enum", options = { "Raise", "Lower", "Smooth", "Flatten" }, default = "Raise", tooltip = "Raise and Lower build up while the mouse is held. Smooth evens out bumps. Flatten levels the terrain toward the height where the stroke started." },
		{ key = "radius", label = "Radius", type = "number", default = 16, min = 2, max = 200, step = 0.5, extended = { widget = "slider" }, tooltip = "Brush radius in studs. [ and ] change it." },
		{ key = "strength", label = "Strength", type = "number", default = 0.5, min = 0.01, max = 1, step = 0.01, extended = { widget = "slider" }, tooltip = "How fast the brush works." },
		{ key = "falloff", label = "Falloff", type = "enum", options = TerrainSettings.BRUSH_FALLOFFS, default = "Smoothstep", tooltip = "How the effect fades from the center of the brush to its edge." },
		{ key = "material", label = "Material", type = "enum", options = TerrainSettings.MATERIALS_AUTO, default = "Auto", tooltip = "Material of raised terrain. Auto: the material of the surface below." },
		{ key = "help", label = "Ctrl/Cmd: lower (or raise) instead · Shift: smooth · [ ]: size · C: center the view", type = "label" },
	},
})

-- The brush in effect with these modifiers.
function TerrainBrush:_mode(modifiers: SDK.Modifiers): string
	if modifiers.shift then
		return "Smooth"
	end
	local mode = self.ctx.settings.mode
	if modifiers.ctrl or modifiers.cmd then
		if mode == "Raise" then
			return "Lower"
		elseif mode == "Lower" then
			return "Raise"
		end
	end
	return mode
end

function TerrainBrush:cursorColor(modifiers: SDK.Modifiers): Color3
	return COLORS[self:_mode(modifiers)] or COLORS.Raise
end

function TerrainBrush:activate(ctx: SDK.ToolContext)
	TerrainBrushTool.activate(self, ctx)
	ctx:setStatus("Drag on the terrain to brush it.")
end

function TerrainBrush:applyStroke(stroke: any, centers: { Vector3 }, dt: number, modifiers: SDK.Modifiers)
	if dt <= 0 then
		return
	end
	local settings = self.ctx.settings
	local radius = settings.radius
	local points = table.create(#centers)
	for i, c in centers do
		points[i] = Vector2.new(c.X, c.Z)
	end
	local shape = Terrain.path(points)
	local falloff = TerrainSettings.falloff(settings.falloff)
	local mode = self:_mode(modifiers)
	if mode == "Raise" or mode == "Lower" then
		local edit = if mode == "Raise" then Terrain.raise else Terrain.lower
		edit(shape, {
			height = settings.strength * RATE * radius * dt,
			falloff = falloff,
			falloffWidth = radius,
			material = TerrainSettings.material(settings.material),
		})
	elseif mode == "Smooth" then
		Terrain.smooth(shape, {
			radius = math.max(4, radius / 3),
			strength = math.min(1, settings.strength * SMOOTH_RATE * dt),
			falloff = falloff,
			falloffWidth = radius,
		})
	else
		Terrain.flatten(shape, {
			level = stroke.start.Y,
			strength = math.min(1, settings.strength * SMOOTH_RATE * dt),
			falloff = falloff,
			falloffWidth = radius,
			material = TerrainSettings.material(settings.material),
		})
	end
end

return TerrainBrush
