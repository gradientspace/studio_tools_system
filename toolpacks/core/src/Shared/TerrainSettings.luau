--[[
	TerrainSettings: setting options shared by the terrain tools, and the
	maps from their labels to SDK.Terrain values.
]]

local SDK = require(script.Parent.Parent.SDK)

local TerrainSettings = {}

-- The terrain materials, in palette order.
TerrainSettings.MATERIALS = {
	"Grass",
	"LeafyGrass",
	"Ground",
	"Mud",
	"Sand",
	"Sandstone",
	"Rock",
	"Slate",
	"Basalt",
	"Limestone",
	"Salt",
	"Snow",
	"Glacier",
	"Ice",
	"CrackedLava",
	"Asphalt",
	"Concrete",
	"Pavement",
	"Brick",
	"Cobblestone",
	"WoodPlanks",
}

-- "Auto" followed by the materials.
TerrainSettings.MATERIALS_AUTO = { "Auto", table.unpack(TerrainSettings.MATERIALS) }

-- The material named by a setting value, or nil for "Auto" / unknown names.
function TerrainSettings.material(name: string?): Enum.Material?
	if not name or name == "Auto" then
		return nil
	end
	local ok, material = pcall(function()
		return (Enum.Material :: any)[name]
	end)
	return if ok then material else nil
end

local FALLOFFS: { [string]: SDK.TerrainFalloff } = {
	Smooth = "smooth",
	Linear = "linear",
	Smoothstep = "smoothstep",
	Round = "round",
	Square = "square",
	Sqrt = "sqrt",
	Constant = "constant",
}

-- Falloff options for shapes (with the blurred "Smooth"), and for brushes.
TerrainSettings.FALLOFFS = { "Smooth", "Linear", "Smoothstep", "Round", "Square", "Sqrt", "Constant" }
TerrainSettings.BRUSH_FALLOFFS = { "Smoothstep", "Linear", "Round", "Square", "Sqrt", "Constant" }
TerrainSettings.FALLOFF_TOOLTIP =
	"How the edit fades out over the falloff width. Smooth: linear over a blurred distance field, rounding ridges, corners and peaks. Smoothstep: eased at both ends. Round: a dome. Square: gentle at the edge, steep inside. Sqrt: steep at the edge, rounded on top. Constant: a hard edge."

function TerrainSettings.falloff(label: string?): SDK.TerrainFalloff
	return FALLOFFS[label or ""] or "linear"
end

local MODES: { [string]: SDK.TerrainCombineMode } = {
	Add = "stamp",
	Subtract = "stamp",
	Max = "max",
	Min = "min",
	["Smooth max"] = "blend",
	["Smooth min"] = "blendMin",
	Replace = "replace",
}

TerrainSettings.RAISE_MODES = { "Add", "Max", "Smooth max", "Replace" }
TerrainSettings.LOWER_MODES = { "Subtract", "Min", "Smooth min", "Replace" }

function TerrainSettings.mode(label: string?): SDK.TerrainCombineMode
	return MODES[label or ""] or "stamp"
end

return TerrainSettings
