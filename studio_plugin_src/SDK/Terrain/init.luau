--[[
	SDK.Terrain: higher-level edits of the place's smooth terrain, for tools
	that edit terrain procedurally (raise a hill inside a drawn polygon,
	carve a river along a path and fill it with water, ...). See "Terrain"
	in docs/TOOLPACKS.md, and the Terrain types in Types.luau for every
	option.

	Everything works on voxel columns (4 x 4 studs) and their surface
	height, the top of the topmost solid terrain in the column:
	- Height edits (combineWithHeightField, modifyHeights, raise, lower,
	  flatten, smooth) compute a new surface height per column and write it
	  (Heights).
	- Shapes (polygons and paths) give each column a coverage from their
	  distance field, shaped by a falloff profile (Shapes, Falloff).
	- paint and fill change materials and water near the surface.
	The edits don't yield (unless `yield` is set) and don't record undo:
	call them inside ctx:recordUndo / ctx:beginUndo.
]]

local Types = require(script.Parent.Types)
local Columns = require(script.Columns)
local Falloff = require(script.Falloff)
local HeightFieldSampler = require(script.HeightFieldSampler)
local Heights = require(script.Heights)
local Shapes = require(script.Shapes)

type Shape = Types.TerrainShape
type HeightField = Types.TerrainHeightField
type EditResult = Types.TerrainEditResult

local VOXEL = Columns.VOXEL
local DEFAULT_SEARCH_MIN_Y = -1024
local DEFAULT_SEARCH_MAX_Y = 2048
local EPSILON = 0.01

local Terrain = {}
Terrain.VOXEL_SIZE = VOXEL

-- Shapes ---------------------------------------------------------------------

-- A polygon (at least 3 points; a repeated first point at the end is ignored).
function Terrain.polygon(points: Types.TerrainPoints): Shape
	local list, hasY = Shapes.toPoints(points, 3, "a polygon")
	if #list > 3 and (list[1] - list[#list]).Magnitude < 1e-6 then
		table.remove(list)
	end
	return { kind = "polygon", points = list, hasY = hasY, closed = true, radius = 0 }
end

local function checkScale(values: any, name: string): { number }?
	if values == nil then
		return nil
	end
	if type(values) ~= "table" then
		error(`{name} must be a list of numbers`, 4)
	end
	for i, v in values do
		if type(v) ~= "number" then
			error(`{name}[{i}] must be a number`, 4)
		end
	end
	return values
end

-- A path through the points (1 point: a dot).
function Terrain.path(points: Types.TerrainPoints, options: Types.TerrainPathOptions?): Shape
	local list, hasY = Shapes.toPoints(points, 1, "a path")
	local o: Types.TerrainPathOptions = options or {}
	local radius = o.radius or 0
	if type(radius) ~= "number" or radius < 0 then
		error("a path's radius must be a number >= 0", 2)
	end
	return {
		kind = "path",
		points = list,
		hasY = hasY,
		closed = o.closed == true,
		radius = radius,
		widthScale = checkScale(o.widthScale, "widthScale"),
		heightScale = checkScale(o.heightScale, "heightScale"),
	}
end

-- Points around a circle (default: one about every 8 studs, 12 to 128).
function Terrain.circle(center: Vector3 | Vector2, radius: number, segments: number?): { Vector3 }
	local c = if typeof(center) == "Vector2" then Vector3.new(center.X, 0, center.Y) else center :: Vector3
	local count = segments or math.clamp(math.ceil(2 * math.pi * radius / 8), 12, 128)
	local points = table.create(count)
	for i = 1, count do
		local angle = 2 * math.pi * (i - 1) / count
		points[i] = c + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
	end
	return points
end

function Terrain.smoothPath(points: Types.TerrainPoints, options: { closed: boolean?, iterations: number? }?): { Vector3 }
	local list = Shapes.toPoints(points, 1, "a path")
	local o = options or {}
	return Shapes.smoothPath(list, o.closed == true, o.iterations or 3)
end

-- Shared plumbing -------------------------------------------------------------

type Context = {
	minY: number,
	maxY: number,
	emptyHeight: number,
	pace: () -> (),
	snapshot: { any }?,
}

local function contextOf(options: any): Context
	local o = options or {}
	return {
		minY = o.searchMinY or DEFAULT_SEARCH_MIN_Y,
		maxY = o.searchMaxY or DEFAULT_SEARCH_MAX_Y,
		emptyHeight = o.emptyHeight or 0,
		pace = Columns.pacer(o.yield),
		snapshot = if o.snapshot and not o.dryRun then {} else nil,
	}
end

-- Adds the snapshot (if one was asked for) to a result.
local function withSnapshot(result: EditResult, context: Context): EditResult
	if context.snapshot then
		result.snapshot = { tiles = context.snapshot }
	end
	return result
end

local function emptyResult(): EditResult
	return { columns = 0 }
end

-- A height field of per-column heights over the grid.
local function heightFieldOf(grid: Columns.Grid, heights: { number? }): HeightField
	local values = table.create(grid.nx)
	for ix = 1, grid.nx do
		local row = table.create(grid.nz)
		for iz = 1, grid.nz do
			row[iz] = heights[(iz - 1) * grid.nx + ix]
		end
		values[ix] = row
	end
	return {
		min = Vector2.new(Columns.x(grid, 1), Columns.z(grid, 1)),
		max = Vector2.new(Columns.x(grid, grid.nx), Columns.z(grid, grid.nz)),
		values = values,
	}
end

-- Writes the new heights (unless dryRun) and builds the result.
local function finishHeights(grid: Columns.Grid, heights: { number? }, materials: { Enum.Material? }, newHeights: { number? }, options: any, context: Context): EditResult
	local o = options or {}
	local result: EditResult
	if o.dryRun then
		local count = 0
		for idx = 1, grid.count do
			local newHeight, old = newHeights[idx], heights[idx]
			if newHeight and (newHeight > (old or context.emptyHeight) + EPSILON or (old and newHeight < old - EPSILON)) then
				count += 1
			end
		end
		result = { columns = count }
	else
		local count, region = Heights.write(grid, heights, materials, newHeights, {
			material = o.material,
			pushDepth = o.pushDepth,
			compressionDepth = o.compressionDepth,
			emptyHeight = context.emptyHeight,
			snapshot = context.snapshot,
		}, context.pace)
		result = withSnapshot({ columns = count, region = region }, context)
	end
	if o.dryRun or o.returnHeights then
		local after = table.create(grid.count)
		for idx = 1, grid.count do
			after[idx] = newHeights[idx] or heights[idx]
		end
		result.heights = heightFieldOf(grid, after)
	end
	return result
end

local function checkShape(shape: any)
	if type(shape) ~= "table" or (shape.kind ~= "polygon" and shape.kind ~= "path") or type(shape.points) ~= "table" then
		error("expected a shape from SDK.Terrain.polygon or SDK.Terrain.path", 4)
	end
end

type Defaults = {
	falloff: Types.TerrainFalloff?,
	align: ("inside" | "outside" | "center")?,
	width: number?,
}

-- The shape's coverage of the columns around it, and the falloff profile.
-- margin: extra studs of columns around the shape (for smoothing).
local function prepareShape(shape: Shape, options: any, defaults: Defaults, margin: number, wantHeights: boolean): (Shapes.Evaluation?, (number) -> number)
	checkShape(shape)
	local o = options or {}
	local falloffName = o.falloff or defaults.falloff or "linear"
	local profile = Falloff.profile(falloffName)
	local align = o.falloffAlign or defaults.align or (if shape.kind == "polygon" then "inside" else "outside")
	if align ~= "inside" and align ~= "outside" and align ~= "center" then
		error(`unknown falloffAlign '{tostring(align)}'`, 3)
	end
	local width = o.falloffWidth or defaults.width
	if width ~= nil and (type(width) ~= "number" or width <= 0) then
		error("falloffWidth must be a number > 0", 3)
	end
	local smoothing = o.smoothing
	if smoothing == nil and falloffName == "smooth" then
		smoothing = math.max(VOXEL, 0.3 * Shapes.estimateWidth(shape :: any, { width = width, align = align, smoothing = 0 }))
	end
	local falloff: Shapes.Falloff = { width = width, align = align, smoothing = math.max(0, smoothing or 0) }
	local minX, minZ, maxX, maxZ = Shapes.bounds(shape :: any, falloff, margin)
	local grid = Columns.grid(minX, minZ, maxX, maxZ)
	if not grid then
		return nil, profile
	end
	return Shapes.evaluate(shape :: any, grid, falloff, wantHeights), profile
end

-- Columns covered by the shape (coverage above 0).
local function coverageMask(evaluation: Shapes.Evaluation): { boolean }
	local mask = table.create(evaluation.grid.count, false)
	for idx, e in evaluation.e do
		mask[idx] = e > 0
	end
	return mask
end

-- Grows a mask by `cells` columns in every direction (a square).
local function dilate(mask: { boolean }, grid: Columns.Grid, cells: number): { boolean }
	if cells <= 0 then
		return mask
	end
	local nx, nz = grid.nx, grid.nz
	local rows = table.create(grid.count, false)
	for iz = 1, nz do
		local base = (iz - 1) * nx
		local lastOn = -math.huge
		for ix = 1, nx do
			if mask[base + ix] then
				lastOn = ix
			end
			if ix - lastOn <= cells then
				rows[base + ix] = true
			end
		end
		lastOn = math.huge
		for ix = nx, 1, -1 do
			if mask[base + ix] then
				lastOn = ix
			end
			if lastOn - ix <= cells then
				rows[base + ix] = true
			end
		end
	end
	local result = table.create(grid.count, false)
	for ix = 1, nx do
		local lastOn = -math.huge
		for iz = 1, nz do
			if rows[(iz - 1) * nx + ix] then
				lastOn = iz
			end
			if iz - lastOn <= cells then
				result[(iz - 1) * nx + ix] = true
			end
		end
		lastOn = math.huge
		for iz = nz, 1, -1 do
			if rows[(iz - 1) * nx + ix] then
				lastOn = iz
			end
			if lastOn - iz <= cells then
				result[(iz - 1) * nx + ix] = true
			end
		end
	end
	return result
end

local function isBoundaryBase(base: any): boolean
	return base == "boundaryMin" or base == "boundaryMean" or base == "boundaryMax"
end

-- A reference height: one value, or per column (base "path").
local function resolveBase(base: any, evaluation: Shapes.Evaluation, heights: { number? }, context: Context): (number?, { number }?)
	if type(base) == "number" then
		return base, nil
	elseif base == "path" then
		if not evaluation.y then
			error("base/level \"path\" needs a path made from Vector3 points", 0)
		end
		return nil, evaluation.y
	elseif not isBoundaryBase(base) then
		error(`unknown base/level '{tostring(base)}'`, 0)
	end
	local columns = Shapes.boundaryColumns(evaluation)
	if #columns == 0 then
		for idx, e in evaluation.e do
			if e > 0 then
				table.insert(columns, idx)
			end
		end
	end
	local lowest, highest, sum = math.huge, -math.huge, 0
	for _, idx in columns do
		local h = heights[idx] or context.emptyHeight
		lowest, highest, sum = math.min(lowest, h), math.max(highest, h), sum + h
	end
	if #columns == 0 then
		return context.emptyHeight, nil
	elseif base == "boundaryMin" then
		return lowest, nil
	elseif base == "boundaryMax" then
		return highest, nil
	end
	return sum / #columns, nil
end

-- The mask of columns whose surface is needed: the covered ones, plus the
-- ring around them when the base is measured there.
local function heightMask(evaluation: Shapes.Evaluation, base: any): { boolean }
	local mask = coverageMask(evaluation)
	if isBoundaryBase(base) then
		for _, idx in Shapes.boundaryColumns(evaluation) do
			mask[idx] = true
		end
	end
	return mask
end

-- Reading ----------------------------------------------------------------------

-- The surface height and material at (x, z), or nil where there's no terrain.
function Terrain.surfaceHeight(x: number, z: number, options: Types.TerrainEditOptions?): (number?, Enum.Material?)
	local context = contextOf(options)
	local heights, materials = Columns.findSurfaces(Columns.gridAt(x, z), nil, context.minY, context.maxY, context.pace)
	return heights[1], materials[1]
end

-- The surface heights of the voxel columns within the bounds, as a height
-- field whose samples are the column centers (nil where there's no terrain).
function Terrain.readHeightField(min: Vector2, max: Vector2, options: Types.TerrainEditOptions?): HeightField
	local grid = Columns.grid(min.X, min.Y, max.X, max.Y)
	if not grid then
		grid = Columns.gridAt((min.X + max.X) / 2, (min.Y + max.Y) / 2)
	end
	local g = grid :: Columns.Grid
	local context = contextOf(options)
	local heights = Columns.findSurfaces(g, nil, context.minY, context.maxY, context.pace)
	return heightFieldOf(g, heights)
end

local samplers: { [any]: HeightFieldSampler.Sampler } = setmetatable({}, { __mode = "k" }) :: any

function Terrain.sampleHeightField(field: HeightField, x: number, z: number, interpolation: ("cubic" | "linear")?): number?
	local key = interpolation or "cubic"
	local sampler = samplers[field]
	if not sampler or sampler.cubic ~= (key == "cubic") then
		sampler = HeightFieldSampler.new(field, key)
		samplers[field] = sampler
	end
	return HeightFieldSampler.sample(sampler, x, z)
end

-- Generic edits ------------------------------------------------------------------

-- Calls fn(x, z, height) for each voxel column within the bounds (height
-- nil where there's no terrain) and moves the surface to the height it
-- returns (nil: leave the column).
function Terrain.modifyHeights(min: Vector2, max: Vector2, fn: (x: number, z: number, height: number?) -> number?, options: Types.TerrainHeightWriteOptions?): EditResult
	local grid = Columns.grid(min.X, min.Y, max.X, max.Y)
	if not grid then
		return emptyResult()
	end
	local context = contextOf(options)
	local heights, materials = Columns.findSurfaces(grid, nil, context.minY, context.maxY, context.pace)
	local newHeights = table.create(grid.count)
	for iz = 1, grid.nz do
		local z = Columns.z(grid, iz)
		for ix = 1, grid.nx do
			local idx = (iz - 1) * grid.nx + ix
			local h = fn(Columns.x(grid, ix), z, heights[idx])
			if type(h) == "number" and h == h and math.abs(h) < math.huge then
				newHeights[idx] = h
			end
		end
	end
	return finishHeights(grid, heights, materials, newHeights, options, context)
end

-- Calls fn for every voxel in the region (expanded to the voxel grid) and
-- writes back what it returns. Returns the number of voxels changed.
function Terrain.modifyVoxels(region: Region3, fn: Types.TerrainVoxelFunction, options: { yield: boolean? }?): number
	return Columns.forEachVoxel(region, fn, Columns.pacer(options and options.yield))
end

function Terrain.combineWithHeightField(field: HeightField, options: Types.TerrainHeightFieldOptions?): EditResult
	local o: any = options or {}
	local sampler = HeightFieldSampler.new(field, o.interpolation)
	local mode = o.mode or "replace"
	Heights.checkMode(mode)
	local multiplier = o.multiplier or 1
	local strength = o.strength or 1
	local blendRadius = o.blendRadius or 8
	local edgeFalloff = o.edgeFalloff or 0
	local grid = Columns.grid(field.min.X, field.min.Y, field.max.X, field.max.Y)
	if not grid then
		return emptyResult()
	end
	local values: { number? } = table.create(grid.count)
	local weights: { number } = table.create(grid.count, 0)
	local mask = table.create(grid.count, false)
	for iz = 1, grid.nz do
		local z = Columns.z(grid, iz)
		for ix = 1, grid.nx do
			local x = Columns.x(grid, ix)
			local idx = (iz - 1) * grid.nx + ix
			local v = HeightFieldSampler.sample(sampler, x, z)
			if v then
				local w = strength * HeightFieldSampler.weight(sampler, x, z)
				if edgeFalloff > 0 then
					local t = math.clamp(HeightFieldSampler.edgeDistance(sampler, x, z) / edgeFalloff, 0, 1)
					w *= t * t * (3 - 2 * t)
				end
				if w > 0 then
					values[idx] = v
					weights[idx] = w
					mask[idx] = true
				end
			end
		end
	end
	local context = contextOf(options)
	local heights, materials = Columns.findSurfaces(grid, mask, context.minY, context.maxY, context.pace)
	local newHeights = table.create(grid.count)
	for idx = 1, grid.count do
		local v = values[idx]
		if v then
			newHeights[idx] = Heights.combine(mode, heights[idx] or context.emptyHeight, v, weights[idx], multiplier, blendRadius)
		end
	end
	return finishHeights(grid, heights, materials, newHeights, options, context)
end

-- Shape edits ---------------------------------------------------------------------

local function raiseOrLower(shape: Shape, options: Types.TerrainRaiseOptions, sign: number): EditResult
	if type(options) ~= "table" or type(options.height) ~= "number" then
		error("raise/lower need options.height (studs)", 3)
	end
	local mode = options.mode or "stamp"
	Heights.checkMode(mode)
	local strength = options.strength or 1
	local blendRadius = options.blendRadius or 8
	local maxHeight = options.maxHeight
	local evaluation, profile = prepareShape(shape, options, {}, 0, true)
	if not evaluation then
		return emptyResult()
	end
	local base = options.base
	if base == nil and mode ~= "stamp" then
		if shape.kind == "path" and shape.hasY then
			base = "path"
		elseif mode == "max" or mode == "blend" then
			base = "boundaryMin"
		elseif mode == "min" or mode == "blendMin" then
			base = "boundaryMax"
		else
			base = "boundaryMean"
		end
	end
	local context = contextOf(options)
	local grid = evaluation.grid
	local heights, materials = Columns.findSurfaces(grid, heightMask(evaluation, base), context.minY, context.maxY, context.pace)
	local baseValue, baseColumns
	if mode ~= "stamp" then
		baseValue, baseColumns = resolveBase(base, evaluation, heights, context)
	end
	local heightScale = evaluation.heightScale
	local newHeights = table.create(grid.count)
	for idx, e in evaluation.e do
		if e > 0 then
			local w = profile(math.min(e, 1))
			local r = options.height * w * (if heightScale then heightScale[idx] else 1)
			if maxHeight then
				r = math.sign(r) * math.min(math.abs(r), maxHeight)
			end
			local h = heights[idx] or context.emptyHeight
			if mode == "stamp" then
				newHeights[idx] = h + sign * r * strength
			else
				local b = baseValue or (baseColumns :: { number })[idx]
				local weight = if mode == "replace" then strength * w else strength
				newHeights[idx] = Heights.combine(mode, h, b + sign * r, weight, 1, blendRadius)
			end
		end
	end
	return finishHeights(grid, heights, materials, newHeights, options, context)
end

-- Raises the terrain over the shape (see TerrainRaiseOptions).
function Terrain.raise(shape: Shape, options: Types.TerrainRaiseOptions): EditResult
	return raiseOrLower(shape, options, 1)
end

-- Lowers the terrain over the shape: the mirror image of raise. Pushes the
-- top of the terrain down rather than cutting it (pushDepth, compressionDepth).
function Terrain.lower(shape: Shape, options: Types.TerrainRaiseOptions): EditResult
	return raiseOrLower(shape, options, -1)
end

-- Moves the surface over the shape to a level.
function Terrain.flatten(shape: Shape, options: Types.TerrainFlattenOptions?): EditResult
	local o: Types.TerrainFlattenOptions = options or {}
	local evaluation, profile = prepareShape(shape, o, { falloff = "smoothstep", align = "outside", width = 8 }, 0, true)
	if not evaluation then
		return emptyResult()
	end
	local level = o.level or (if shape.kind == "path" and shape.hasY then "path" else "boundaryMean")
	local strength = o.strength or 1
	local context = contextOf(o)
	local grid = evaluation.grid
	local heights, materials = Columns.findSurfaces(grid, heightMask(evaluation, level), context.minY, context.maxY, context.pace)
	local levelValue, levelColumns = resolveBase(level, evaluation, heights, context)
	local newHeights = table.create(grid.count)
	for idx, e in evaluation.e do
		if e > 0 then
			local target = levelValue or (levelColumns :: { number })[idx]
			newHeights[idx] = Heights.combine("replace", heights[idx] or context.emptyHeight, target, strength * profile(math.min(e, 1)), 1, 0)
		end
	end
	return finishHeights(grid, heights, materials, newHeights, o, context)
end

-- Smooths the surface over the shape (a Gaussian blur of the heights).
function Terrain.smooth(shape: Shape, options: Types.TerrainSmoothOptions?): EditResult
	local o: Types.TerrainSmoothOptions = options or {}
	local radius = o.radius or 8
	if radius <= 0 then
		error("smooth radius must be > 0", 2)
	end
	local sigma = radius / 2 / VOXEL
	local evaluation, profile = prepareShape(shape, o, { falloff = "smoothstep", width = 16 }, 1.5 * radius, false)
	if not evaluation then
		return emptyResult()
	end
	local strength = o.strength or 1
	local context = contextOf(o)
	local grid = evaluation.grid
	local mask = dilate(coverageMask(evaluation), grid, math.ceil(3 * sigma))
	local heights, materials = Columns.findSurfaces(grid, mask, context.minY, context.maxY, context.pace)
	local blurred = Falloff.blur(heights, grid.nx, grid.nz, sigma)
	local newHeights = table.create(grid.count)
	for idx, e in evaluation.e do
		local h, b = heights[idx], blurred[idx]
		if e > 0 and h and b then
			newHeights[idx] = h + (b - h) * strength * profile(math.min(e, 1))
		end
	end
	return finishHeights(grid, heights, materials, newHeights, o, context)
end

local function hash01(i: number, k: number): number
	local h = math.sin(i * 12.9898 + k * 78.233) * 43758.5453
	return h - math.floor(h)
end

-- Paints the surface over the shape.
function Terrain.paint(shape: Shape, options: Types.TerrainPaintOptions): EditResult
	if type(options) ~= "table" or typeof(options.material) ~= "EnumItem" or options.material.EnumType ~= Enum.Material then
		error("paint needs options.material (an Enum.Material)", 2)
	end
	local material = options.material
	if material == Enum.Material.Water or material == Enum.Material.Air then
		error("paint sets solid materials; use fill for water", 2)
	end
	local depth = options.depth or 4
	local evaluation, profile = prepareShape(shape, options, { falloff = "constant", width = VOXEL / 2 }, VOXEL, false)
	if not evaluation then
		return emptyResult()
	end
	local only: { [Enum.Material]: boolean }? = nil
	if options.onlyMaterials then
		only = {}
		for _, m in options.onlyMaterials do
			(only :: any)[m] = true
		end
	end
	local minSlope, maxSlope = options.minSlope, options.maxSlope
	local useSlope = minSlope ~= nil or maxSlope ~= nil
	local context = contextOf(options)
	local grid = evaluation.grid
	local mask = coverageMask(evaluation)
	local heights = Columns.findSurfaces(grid, if useSlope then dilate(mask, grid, 1) else mask, context.minY, context.maxY, context.pace)
	local nx = grid.nx
	local lo: { number? }, hi: { number? } = table.create(grid.count), table.create(grid.count)
	local count = 0
	for idx, e in evaluation.e do
		local h = heights[idx]
		if e > 0 and h then
			local w = profile(math.min(e, 1))
			local ix, iz = (idx - 1) % nx + 1, (idx - 1) // nx + 1
			local paint = if options.dither then w > hash01(grid.i0 + ix, grid.k0 + iz) else w > 0
			if paint and useSlope then
				local function at(jx: number, jz: number): number?
					if jx < 1 or jx > nx or jz < 1 or jz > grid.nz then
						return nil
					end
					return heights[(jz - 1) * nx + jx]
				end
				local x0, x1 = at(ix - 1, iz) or h, at(ix + 1, iz) or h
				local z0, z1 = at(ix, iz - 1) or h, at(ix, iz + 1) or h
				local gx, gz = (x1 - x0) / (2 * VOXEL), (z1 - z0) / (2 * VOXEL)
				local slope = math.deg(math.atan(math.sqrt(gx * gx + gz * gz)))
				paint = slope >= (minSlope or 0) and slope <= (maxSlope or 90)
			end
			if paint then
				lo[idx] = h - depth - 2 * VOXEL
				hi[idx] = h + VOXEL
				count += 1
			end
		end
	end
	if options.dryRun then
		return { columns = count }
	end
	local changed, region = Columns.apply(grid, lo, hi, function(idx, n, occ, mat, _liq, bottom)
		local h = heights[idx] :: number
		local changed = false
		for m = 1, n do
			local c = bottom + VOXEL * m - 2
			if occ[m] > 0 and c < h and c + VOXEL > h - depth and mat[m] ~= material and (not only or only[mat[m]]) then
				mat[m] = material
				changed = true
			end
		end
		return changed
	end, context.pace, context.snapshot)
	return withSnapshot({ columns = changed, region = region }, context)
end

-- Fills the air above the surface over the shape, up to a level.
function Terrain.fill(shape: Shape, options: Types.TerrainFillOptions?): EditResult
	local o: Types.TerrainFillOptions = options or {}
	local material = o.material or Enum.Material.Water
	if typeof(material) ~= "EnumItem" or material.EnumType ~= Enum.Material then
		error("fill's material must be an Enum.Material", 2)
	end
	local evaluation = prepareShape(shape, o, { falloff = "constant", width = VOXEL / 2 }, 0, true)
	if not evaluation then
		return emptyResult()
	end
	local level = o.level or (if shape.kind == "path" and shape.hasY then "path" else "boundaryMin")
	local offset = o.levelOffset or 0
	local context = contextOf(o)
	local grid = evaluation.grid
	local heights = Columns.findSurfaces(grid, heightMask(evaluation, level), context.minY, context.maxY, context.pace)
	local levelValue, levelColumns = resolveBase(level, evaluation, heights, context)
	local levels: { number } = table.create(grid.count, 0)
	local floors: { number } = table.create(grid.count, 0)
	local lo: { number? }, hi: { number? } = table.create(grid.count), table.create(grid.count)
	local count = 0
	for idx, e in evaluation.e do
		if e > 0 then
			local l = (levelValue or (levelColumns :: { number })[idx]) + offset
			local h = heights[idx]
			local floor = if h then h - 2 * VOXEL else context.emptyHeight
			if l > (h or context.emptyHeight) + EPSILON or (material == Enum.Material.Air and l > floor) then
				levels[idx], floors[idx] = l, floor
				lo[idx], hi[idx] = floor, l + VOXEL
				count += 1
			end
		end
	end
	if o.dryRun then
		return { columns = count }
	end
	local isWater, isAir = material == Enum.Material.Water, material == Enum.Material.Air
	local changed, region = Columns.apply(grid, lo, hi, function(idx, n, occ, mat, liq, bottom)
		local l, floor = levels[idx], floors[idx]
		local changed = false
		for m = 1, n do
			local c = bottom + VOXEL * m - 2
			if c >= floor and c < l then
				local target = math.min(1, (l - c) / VOXEL)
				if isWater then
					if liq[m] < target - 1e-3 and occ[m] < 1 then
						liq[m] = target
						changed = true
					end
				elseif isAir then
					if liq[m] > 0 then
						liq[m] = 0
						changed = true
					end
				elseif occ[m] < target - 1e-3 then
					if occ[m] <= 0 or mat[m] == Enum.Material.Air then
						mat[m] = material
					end
					occ[m] = target
					changed = true
				end
			end
		end
		return changed
	end, context.pace, context.snapshot)
	return withSnapshot({ columns = changed, region = region }, context)
end

-- Puts back the terrain an edit made with `snapshot = true` changed.
function Terrain.restore(snapshot: Types.TerrainSnapshot, options: { yield: boolean? }?)
	if type(snapshot) ~= "table" or type(snapshot.tiles) ~= "table" then
		error("expected the snapshot of an edit's result", 2)
	end
	Columns.restore(snapshot.tiles, Columns.pacer(options and options.yield))
end

-- From points ---------------------------------------------------------------------

function Terrain.raiseWithinPolygon(points: Types.TerrainPoints, options: Types.TerrainRaiseOptions): EditResult
	return Terrain.raise(Terrain.polygon(points), options)
end

function Terrain.lowerWithinPolygon(points: Types.TerrainPoints, options: Types.TerrainRaiseOptions): EditResult
	return Terrain.lower(Terrain.polygon(points), options)
end

function Terrain.flattenWithinPolygon(points: Types.TerrainPoints, options: Types.TerrainFlattenOptions?): EditResult
	return Terrain.flatten(Terrain.polygon(points), options)
end

function Terrain.smoothWithinPolygon(points: Types.TerrainPoints, options: Types.TerrainSmoothOptions?): EditResult
	return Terrain.smooth(Terrain.polygon(points), options)
end

function Terrain.paintWithinPolygon(points: Types.TerrainPoints, options: Types.TerrainPaintOptions): EditResult
	return Terrain.paint(Terrain.polygon(points), options)
end

function Terrain.fillWithinPolygon(points: Types.TerrainPoints, options: Types.TerrainFillOptions?): EditResult
	return Terrain.fill(Terrain.polygon(points), options)
end

function Terrain.raiseAlongPath(points: Types.TerrainPoints, options: Types.TerrainRaiseOptions & Types.TerrainPathOptions): EditResult
	return Terrain.raise(Terrain.path(points, options), options)
end

function Terrain.lowerAlongPath(points: Types.TerrainPoints, options: Types.TerrainRaiseOptions & Types.TerrainPathOptions): EditResult
	return Terrain.lower(Terrain.path(points, options), options)
end

function Terrain.flattenAlongPath(points: Types.TerrainPoints, options: (Types.TerrainFlattenOptions & Types.TerrainPathOptions)?): EditResult
	return Terrain.flatten(Terrain.path(points, options), options)
end

function Terrain.smoothAlongPath(points: Types.TerrainPoints, options: (Types.TerrainSmoothOptions & Types.TerrainPathOptions)?): EditResult
	return Terrain.smooth(Terrain.path(points, options), options)
end

function Terrain.paintAlongPath(points: Types.TerrainPoints, options: Types.TerrainPaintOptions & Types.TerrainPathOptions): EditResult
	return Terrain.paint(Terrain.path(points, options), options)
end

function Terrain.fillAlongPath(points: Types.TerrainPoints, options: (Types.TerrainFillOptions & Types.TerrainPathOptions)?): EditResult
	return Terrain.fill(Terrain.path(points, options), options)
end

return table.freeze(Terrain)
