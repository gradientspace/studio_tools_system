--[[
	Heights: combining heights, and writing new surface heights into the
	voxel columns (see Columns for how heights map to occupancy).

	Raising fills from just below the old surface up to the new one
	(occupancy = max(old, new)), so caves further down stay.

	Lowering either cuts (occupancy = min(old, new)) or, by default, pushes
	the top of the column down. Pushing warps the column vertically: the
	terrain from the surface S down to S - pushDepth moves down by the drop
	d, and the band of compressionDepth (C) below that is squeezed into
	C - d, so everything below it stays put. A layer thinner than the drop
	then moves down instead of being cut through. On a column that's solid
	all the way down it gives the same result as cutting.

	The warp is applied to the occupancy as a density along the column
	(each voxel filling [c, c + 4) by its occupancy): the new voxel at c'
	is the mean of the old density over the source span of [c', c' + 4),
	computed exactly from the density's running integral, so a clean
	heightfield column comes out as a clean heightfield column.
]]

local Falloff = require(script.Parent.Falloff)
local Columns = require(script.Parent.Columns)

local VOXEL = Columns.VOXEL
local EPSILON = 0.01 -- studs: smaller height changes are skipped
local OCC_EPSILON = 1 / 512 -- occupancy is stored in 1/256 steps

local Heights = {}

export type WriteOptions = {
	material: Enum.Material?,
	pushDepth: number?,
	compressionDepth: number?,
	emptyHeight: number?,
	snapshot: { any }?, -- see Columns.apply
}

-- Combines a target V with the height H by mode, then mixes the result
-- with H by weight. stamp adds V * multiplier * weight.
function Heights.combine(mode: string, h: number, v: number, weight: number, multiplier: number, blendRadius: number): number
	local target
	if mode == "replace" then
		target = v
	elseif mode == "max" then
		target = math.max(h, v)
	elseif mode == "min" then
		target = math.min(h, v)
	elseif mode == "stamp" then
		return h + v * multiplier * weight
	elseif mode == "blend" then
		target = Falloff.smoothMax(h, v, blendRadius)
	elseif mode == "blendMin" then
		target = Falloff.smoothMin(h, v, blendRadius)
	else
		error(`unknown combine mode '{tostring(mode)}'`, 0)
	end
	return h + (target - h) * weight
end

local function checkMode(mode: any)
	if mode ~= "replace" and mode ~= "max" and mode ~= "min" and mode ~= "stamp" and mode ~= "blend" and mode ~= "blendMin" then
		error(`unknown combine mode '{tostring(mode)}'`, 4)
	end
end
Heights.checkMode = checkMode

local function raiseColumn(n: number, occ: { number }, mat: { Enum.Material }, bottom: number, floor: number, newHeight: number, fillMaterial: Enum.Material, forceMaterial: boolean): boolean
	local changed = false
	for m = 1, n do
		local c = bottom + VOXEL * m - 2
		if c >= floor and c < newHeight then
			local target = math.min(1, (newHeight - c) / VOXEL)
			if target > occ[m] + OCC_EPSILON then
				if forceMaterial or occ[m] <= 0 or mat[m] == Enum.Material.Air then
					mat[m] = fillMaterial
				end
				occ[m] = target
				changed = true
			end
		end
	end
	return changed
end

-- Whether there's water just above the surface at `height`.
local function waterAbove(n: number, liq: { number }, bottom: number, height: number): boolean
	local m = math.floor((height - (bottom + 2)) / VOXEL) + 1
	for k = m, m + 1 do
		if k >= 1 and k <= n and liq[k] >= 0.5 then
			return true
		end
	end
	return false
end

local function cutColumn(n: number, occ: { number }, mat: { Enum.Material }, liq: { number }, bottom: number, height: number, newHeight: number, material: Enum.Material?): boolean
	local flood = waterAbove(n, liq, bottom, height)
	local changed = false
	for m = 1, n do
		local c = bottom + VOXEL * m - 2
		if c >= newHeight - VOXEL then
			local target = math.clamp((newHeight - c) / VOXEL, 0, 1)
			if occ[m] > target + OCC_EPSILON then
				occ[m] = target
				if flood then
					liq[m] = 1
				end
				changed = true
			end
			if material and target > 0 and c >= newHeight - 2 * VOXEL and mat[m] ~= material then
				mat[m] = material
				changed = true
			end
		end
	end
	return changed
end

-- scratch arrays for pushColumn
local source: { number } = {}
local sourceMaterial: { Enum.Material } = {}
local running: { number } = {}

local function pushColumn(n: number, occ: { number }, mat: { Enum.Material }, liq: { number }, bottom: number, height: number, newHeight: number, pushDepth: number, compression: number, material: Enum.Material?): boolean
	local drop = height - newHeight
	local band = if compression > 0 then math.max(compression, 1.25 * drop) else 0
	local a = height - pushDepth - band -- bottom of the moving terrain; nothing below moves
	local flood = waterAbove(n, liq, bottom, height)

	local c1 = bottom + 2 -- center of voxel 1: its span is [c1, c1 + 4)
	running[1] = 0
	for m = 1, n do
		source[m] = occ[m]
		sourceMaterial[m] = mat[m]
		running[m + 1] = running[m] + VOXEL * occ[m]
	end
	-- integral of the old density from c1 to y
	local function integral(y: number): number
		local m = math.floor((y - c1) / VOXEL) + 1
		if m < 1 then
			return (y - c1) * source[1]
		elseif m > n then
			return running[n + 1] + (y - (c1 + VOXEL * n)) * source[n]
		end
		return running[m] + (y - (c1 + VOXEL * (m - 1))) * source[m]
	end

	-- the inverse warp, in pieces: on [from, to], new y' came from y' * slope + offset
	local pieces
	if band > 0 then
		local k = band / (band - drop)
		pieces = {
			{ -math.huge, a, 1, 0 },
			{ a, a + band - drop, k, a - a * k },
			{ a + band - drop, math.huge, 1, drop },
		}
	else
		pieces = {
			{ -math.huge, a - drop, 1, 0 },
			{ a - drop, math.huge, 1, drop },
		}
	end
	local function sourceOf(y: number): number
		for _, piece in pieces do
			if y <= piece[2] then
				return y * piece[3] + piece[4]
			end
		end
		return y + drop
	end

	local changed = false
	for m = 1, n do
		local y0 = c1 + VOXEL * (m - 1)
		local y1 = y0 + VOXEL
		if y1 > a - drop then
			local total = 0
			for _, piece in pieces do
				local s0, s1 = math.max(y0, piece[1]), math.min(y1, piece[2])
				if s1 > s0 then
					local slope, offset = piece[3], piece[4]
					total += (integral(s1 * slope + offset) - integral(s0 * slope + offset)) / slope
				end
			end
			local o = math.clamp(total / VOXEL, 0, 1)
			local newMaterial = Enum.Material.Air
			if o > 0 then
				local from = math.clamp(math.floor((sourceOf(y0 + VOXEL / 2) - c1) / VOXEL) + 1, 1, n)
				newMaterial = sourceMaterial[from]
				if newMaterial == Enum.Material.Air then
					newMaterial = sourceMaterial[math.max(1, from - 1)]
				end
				if newMaterial == Enum.Material.Air then
					newMaterial = sourceMaterial[math.min(n, from + 1)]
				end
				if material and y0 >= newHeight - 2 * VOXEL then
					newMaterial = material
				end
				if newMaterial == Enum.Material.Air then
					newMaterial = Enum.Material.Ground
				end
			end
			if math.abs(o - occ[m]) > OCC_EPSILON or (o > 0 and newMaterial ~= mat[m]) then
				if flood and o < occ[m] and y0 >= newHeight - VOXEL and y0 < height + VOXEL then
					liq[m] = 1
				end
				occ[m] = o
				mat[m] = newMaterial
				changed = true
			end
		end
	end
	return changed
end

-- Writes new surface heights: newHeights[idx] (nil: leave the column).
-- oldHeights[idx] is the current surface (nil: no terrain, then
-- emptyHeight is used); surfaceMaterials[idx] its material. Returns the
-- changed column count and region.
function Heights.write(grid: Columns.Grid, oldHeights: { number? }, surfaceMaterials: { Enum.Material? }, newHeights: { number? }, options: WriteOptions, pace: () -> ()): (number, Region3?)
	local emptyHeight = options.emptyHeight or 0
	local pushDepth = math.max(0, options.pushDepth or 8)
	local compression = math.max(0, options.compressionDepth or 16)
	local material = options.material
	local lo: { number? }, hi: { number? } = table.create(grid.count), table.create(grid.count)
	for idx = 1, grid.count do
		local newHeight = newHeights[idx]
		if newHeight then
			local old = oldHeights[idx]
			local base = old or emptyHeight
			if newHeight > base + EPSILON then
				lo[idx] = if old then old - 2 * VOXEL else emptyHeight
				hi[idx] = newHeight + VOXEL
			elseif old and newHeight < old - EPSILON then
				if pushDepth + compression > 0 then
					local drop = old - newHeight
					local band = if compression > 0 then math.max(compression, 1.25 * drop) else 0
					lo[idx] = old - pushDepth - band - drop - 2 * VOXEL
				else
					lo[idx] = newHeight - 2 * VOXEL
				end
				hi[idx] = old + 2 * VOXEL
			end
		end
	end
	return Columns.apply(grid, lo, hi, function(idx, n, occ, mat, liq, bottom)
		local old = oldHeights[idx]
		local newHeight = newHeights[idx] :: number
		local base = old or emptyHeight
		if newHeight > base then
			local fillMaterial = material or surfaceMaterials[idx] or Enum.Material.Grass
			local floor = if old then old - 2 * VOXEL else emptyHeight
			return raiseColumn(n, occ, mat, bottom, floor, newHeight, fillMaterial, material ~= nil)
		elseif pushDepth + compression > 0 then
			return pushColumn(n, occ, mat, liq, bottom, base, newHeight, pushDepth, compression, material)
		else
			return cutColumn(n, occ, mat, liq, bottom, base, newHeight, material)
		end
	end, pace, options.snapshot)
end

return Heights
