--[[
	HeightFieldSampler: interpolates a TerrainHeightField (values on a
	regular XZ grid spanning min to max) at any point inside it.

	"cubic" is Catmull-Rom: it passes through the values and is smooth
	between them. Where one of the 16 values it needs is a hole (nil), it
	falls back to "linear" (bilinear), and that to nil if one of its 4
	values is a hole.
]]

local Types = require(script.Parent.Parent.Types)

local HeightFieldSampler = {}

export type Sampler = {
	field: Types.TerrainHeightField,
	countX: number,
	countZ: number,
	cubic: boolean,
}

function HeightFieldSampler.new(field: Types.TerrainHeightField, interpolation: string?): Sampler
	if type(field) ~= "table" or typeof(field.min) ~= "Vector2" or typeof(field.max) ~= "Vector2" or type(field.values) ~= "table" then
		error("a height field needs min and max (Vector2) and values", 3)
	end
	local countX = #field.values
	if countX == 0 or type(field.values[1]) ~= "table" then
		error("a height field needs values[i][j]", 3)
	end
	local countZ = #field.values[1]
	for i = 1, countX do
		local row = field.values[i]
		if type(row) ~= "table" then
			error(`height field values[{i}] is missing`, 3)
		end
	end
	if interpolation ~= nil and interpolation ~= "cubic" and interpolation ~= "linear" then
		error(`unknown interpolation '{tostring(interpolation)}'`, 3)
	end
	return { field = field, countX = countX, countZ = math.max(countZ, 1), cubic = interpolation ~= "linear" }
end

-- Grid coordinates (from 1) of a world position, or nil outside the field.
local function gridCoords(sampler: Sampler, x: number, z: number): (number?, number?)
	local field = sampler.field
	local minX, minZ, maxX, maxZ = field.min.X, field.min.Y, field.max.X, field.max.Y
	local eps = 1e-6
	if x < minX - eps or x > maxX + eps or z < minZ - eps or z > maxZ + eps then
		return nil, nil
	end
	local u = if sampler.countX > 1 and maxX > minX then (x - minX) / (maxX - minX) * (sampler.countX - 1) + 1 else 1
	local v = if sampler.countZ > 1 and maxZ > minZ then (z - minZ) / (maxZ - minZ) * (sampler.countZ - 1) + 1 else 1
	return math.clamp(u, 1, sampler.countX), math.clamp(v, 1, sampler.countZ)
end

local function catmullRom(p0: number, p1: number, p2: number, p3: number, t: number): number
	local t2, t3 = t * t, t * t * t
	return 0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (-p0 + 3 * p1 - 3 * p2 + p3) * t3)
end

local function bilinear(grid: { { number? } }, countX: number, countZ: number, u: number, v: number): number?
	local i, j = math.min(math.floor(u), countX - 1), math.min(math.floor(v), countZ - 1)
	i, j = math.max(i, 1), math.max(j, 1)
	local fu, fv = u - i, v - j
	local i2, j2 = math.min(i + 1, countX), math.min(j + 1, countZ)
	local a, b, c, d = grid[i][j], grid[i2][j], grid[i][j2], grid[i2][j2]
	if a == nil or b == nil or c == nil or d == nil then
		-- exactly on a sample: that value alone is enough
		if fu < 1e-6 and fv < 1e-6 then
			return a
		end
		return nil
	end
	return (a * (1 - fu) + b * fu) * (1 - fv) + (c * (1 - fu) + d * fu) * fv
end

local function sampleGrid(sampler: Sampler, grid: { { number? } }, u: number, v: number, cubic: boolean): number?
	local countX, countZ = sampler.countX, sampler.countZ
	if not cubic or countX < 2 or countZ < 2 then
		return bilinear(grid, countX, countZ, u, v)
	end
	local i, j = math.clamp(math.floor(u), 1, countX - 1), math.clamp(math.floor(v), 1, countZ - 1)
	local fu, fv = u - i, v - j
	local rows = table.create(4, 0)
	for dj = -1, 2 do
		local jj = math.clamp(j + dj, 1, countZ)
		local p = table.create(4, 0)
		for di = -1, 2 do
			local value = grid[math.clamp(i + di, 1, countX)][jj]
			if value == nil then
				return bilinear(grid, countX, countZ, u, v)
			end
			p[di + 2] = value
		end
		rows[dj + 2] = catmullRom(p[1], p[2], p[3], p[4], fu)
	end
	return catmullRom(rows[1], rows[2], rows[3], rows[4], fv)
end

-- The interpolated value at (x, z), or nil outside the field or at a hole.
function HeightFieldSampler.sample(sampler: Sampler, x: number, z: number): number?
	local u, v = gridCoords(sampler, x, z)
	if not u or not v then
		return nil
	end
	return sampleGrid(sampler, sampler.field.values, u, v, sampler.cubic)
end

-- The field's own weight at (x, z) (bilinear; 1 without weights).
function HeightFieldSampler.weight(sampler: Sampler, x: number, z: number): number
	local weights = sampler.field.weights
	if not weights then
		return 1
	end
	local u, v = gridCoords(sampler, x, z)
	if not u or not v then
		return 0
	end
	return math.clamp(bilinear(weights :: any, sampler.countX, sampler.countZ, u, v) or 0, 0, 1)
end

-- Distance from (x, z) to the nearest edge of the field's bounds.
function HeightFieldSampler.edgeDistance(sampler: Sampler, x: number, z: number): number
	local field = sampler.field
	return math.min(x - field.min.X, field.max.X - x, z - field.min.Y, field.max.Y - z)
end

return HeightFieldSampler
