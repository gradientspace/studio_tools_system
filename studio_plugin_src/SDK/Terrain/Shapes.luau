--[[
	Shapes: polygons and paths, and how strongly they cover each voxel
	column.

	Both are evaluated the same way, from a signed distance sd (negative
	inside): for a polygon, the distance to its edges; for a path, the
	distance to the polyline minus its radius (the full-strength core). The
	falloff ramp is `width` studs wide and lies inside the edge, outside it
	or across it (align), giving the coverage

		e = (offset - sd) / width     offset = 0, width / 2 or width

	which is clamped to [0, 1] and passed through the falloff profile by
	the edits. Columns with e <= 0 aren't touched.

	Paths can vary along their length: widthScale multiplies the radius and
	the width, heightScale the height of raise/lower, and points with Y give
	the path a height. These are interpolated at the nearest point of each
	segment; a column takes the segment that covers it most, so strokes of
	different widths join where they meet.

	Smoothing blurs the field (Gaussian) before the ramp is applied. A
	signed distance is linear across a straight edge, which a blur leaves
	as it is, so straight edges stay put while the creases of the distance
	field (along a polygon's medial axis, at its peak, and on the inside of
	a path's bends) and sharp corners are rounded.
]]

local Columns = require(script.Parent.Columns)
local Falloff = require(script.Parent.Falloff)

local DEFAULT_WIDTH = 16

local Shapes = {}
Shapes.DEFAULT_WIDTH = DEFAULT_WIDTH

export type Shape = {
	kind: "polygon" | "path",
	points: { Vector3 },
	hasY: boolean,
	closed: boolean,
	radius: number,
	widthScale: { number }?,
	heightScale: { number }?,
}

export type Falloff = {
	width: number?, -- nil: default (inradius for "inside" polygons)
	align: "inside" | "outside" | "center",
	smoothing: number, -- studs; 0 for none
}

export type Evaluation = {
	grid: Columns.Grid,
	e: { number }, -- coverage before clamping
	width: number,
	heightScale: { number }?, -- paths with heightScale
	y: { number }?, -- paths with heights
}

-- Points as Vector3s; Vector2s are (X, Z). Returns whether they had Y.
function Shapes.toPoints(points: any, minimum: number, what: string): ({ Vector3 }, boolean)
	if type(points) ~= "table" or #points < minimum then
		error(`{what} needs at least {minimum} point{if minimum == 1 then "" else "s"}`, 3)
	end
	local result = table.create(#points)
	local hasY = true
	for i, p in points do
		if typeof(p) == "Vector3" then
			result[i] = p
		elseif typeof(p) == "Vector2" then
			result[i] = Vector3.new(p.X, 0, p.Y)
			hasY = false
		else
			error(`{what} point {i} is a {typeof(p)}, not a Vector3 or Vector2`, 3)
		end
	end
	return result, hasY
end

-- Segment arrays: endpoints, heights, length, arc length at the start, and
-- the point indices at each end.
type Segments = {
	count: number,
	ax: { number },
	az: { number },
	bx: { number },
	bz: { number },
	ay: { number },
	by: { number },
	len: { number },
	s0: { number },
	ka: { number },
	kb: { number },
	total: number,
}

local function segmentsOf(shape: Shape): Segments
	local points = shape.points
	local n = #points
	local closed = shape.kind == "polygon" or (shape.closed and n > 2)
	local segs: Segments = { count = 0, ax = {}, az = {}, bx = {}, bz = {}, ay = {}, by = {}, len = {}, s0 = {}, ka = {}, kb = {}, total = 0 }
	local s = 0
	local last = if closed then n else math.max(1, n - 1)
	for k = 1, last do
		local k2 = if k == n then (if closed then 1 else k) else k + 1
		local a, b = points[k], points[k2]
		local len = math.sqrt((b.X - a.X) ^ 2 + (b.Z - a.Z) ^ 2)
		local i = segs.count + 1
		segs.count = i
		segs.ax[i], segs.az[i], segs.bx[i], segs.bz[i] = a.X, a.Z, b.X, b.Z
		segs.ay[i], segs.by[i] = a.Y, b.Y
		segs.len[i], segs.s0[i], segs.ka[i], segs.kb[i] = len, s, k, k2
		s += len
	end
	segs.total = s
	return segs
end

-- A value given along a path at the nearest point of segment i (t along it).
local function valueAt(values: { number }?, pointCount: number, segs: Segments, i: number, t: number): number
	if not values or #values == 0 then
		return 1
	end
	local count = #values
	if count == pointCount then
		local a, b = values[segs.ka[i]], values[segs.kb[i]]
		return a + (b - a) * t
	elseif count == 1 then
		return values[1]
	end
	local s = segs.s0[i] + segs.len[i] * t
	local f = (if segs.total > 0 then s / segs.total else 0) * (count - 1)
	local j = math.clamp(math.floor(f) + 1, 1, count - 1)
	return values[j] + (values[j + 1] - values[j]) * (f - (j - 1))
end

-- Squared distance from (x, z) to segment i, and the parameter of the
-- nearest point.
local function segmentDistance(segs: Segments, i: number, x: number, z: number): (number, number)
	local ax, az = segs.ax[i], segs.az[i]
	local dx, dz = segs.bx[i] - ax, segs.bz[i] - az
	local lenSq = dx * dx + dz * dz
	local t = 0
	if lenSq > 1e-12 then
		t = math.clamp(((x - ax) * dx + (z - az) * dz) / lenSq, 0, 1)
	end
	local px, pz = ax + dx * t - x, az + dz * t - z
	return px * px + pz * pz, t
end

-- A bucket grid over the segments, for finding the ones near a point.
type Index = {
	cell: number,
	minX: number,
	minZ: number,
	nbx: number,
	nbz: number,
	buckets: { { number } },
	stamp: { number },
	query: number,
}

local function buildIndex(segs: Segments, cell: number): Index
	local minX, minZ, maxX, maxZ = math.huge, math.huge, -math.huge, -math.huge
	for i = 1, segs.count do
		minX = math.min(minX, segs.ax[i], segs.bx[i])
		maxX = math.max(maxX, segs.ax[i], segs.bx[i])
		minZ = math.min(minZ, segs.az[i], segs.bz[i])
		maxZ = math.max(maxZ, segs.az[i], segs.bz[i])
	end
	local nbx = math.floor((maxX - minX) / cell) + 1
	local nbz = math.floor((maxZ - minZ) / cell) + 1
	local buckets = table.create(nbx * nbz)
	for b = 1, nbx * nbz do
		buckets[b] = {}
	end
	for i = 1, segs.count do
		local bx0 = math.floor((math.min(segs.ax[i], segs.bx[i]) - minX) / cell)
		local bx1 = math.floor((math.max(segs.ax[i], segs.bx[i]) - minX) / cell)
		local bz0 = math.floor((math.min(segs.az[i], segs.bz[i]) - minZ) / cell)
		local bz1 = math.floor((math.max(segs.az[i], segs.bz[i]) - minZ) / cell)
		for bz = bz0, bz1 do
			for bx = bx0, bx1 do
				table.insert(buckets[bz * nbx + bx + 1], i)
			end
		end
	end
	return { cell = cell, minX = minX, minZ = minZ, nbx = nbx, nbz = nbz, buckets = buckets, stamp = table.create(segs.count, 0), query = 0 }
end

-- Calls fn(i) once for each segment in the buckets within `range` of (x, z).
local function forEachNear(index: Index, x: number, z: number, range: number, fn: (number) -> ())
	index.query += 1
	local query, stamp = index.query, index.stamp
	local bx0 = math.max(0, math.floor((x - range - index.minX) / index.cell))
	local bx1 = math.min(index.nbx - 1, math.floor((x + range - index.minX) / index.cell))
	local bz0 = math.max(0, math.floor((z - range - index.minZ) / index.cell))
	local bz1 = math.min(index.nbz - 1, math.floor((z + range - index.minZ) / index.cell))
	for bz = bz0, bz1 do
		for bx = bx0, bx1 do
			for _, i in index.buckets[bz * index.nbx + bx + 1] do
				if stamp[i] ~= query then
					stamp[i] = query
					fn(i)
				end
			end
		end
	end
end

-- Distance from (x, z) to the nearest segment, searching rings of buckets
-- outward until no closer segment can remain.
local function nearestDistance(index: Index, segs: Segments, x: number, z: number): number
	index.query += 1
	local query, stamp = index.query, index.stamp
	local cell = index.cell
	local bx = math.floor((x - index.minX) / cell)
	local bz = math.floor((z - index.minZ) / cell)
	local maxRing = math.max(math.abs(bx), math.abs(bx - index.nbx + 1), math.abs(bz), math.abs(bz - index.nbz + 1))
	local best = math.huge
	for ring = 0, maxRing do
		for cz = bz - ring, bz + ring do
			if cz >= 0 and cz < index.nbz then
				local onEdge = cz == bz - ring or cz == bz + ring
				local step = if onEdge or ring == 0 then 1 else 2 * ring
				for cx = bx - ring, bx + ring, step do
					if cx >= 0 and cx < index.nbx then
						for _, i in index.buckets[cz * index.nbx + cx + 1] do
							if stamp[i] ~= query then
								stamp[i] = query
								local d = segmentDistance(segs, i, x, z)
								if d < best then
									best = d
								end
							end
						end
					end
				end
			end
		end
		-- every bucket not yet visited is at least ring * cell away
		if best <= (ring * cell) ^ 2 then
			break
		end
	end
	return math.sqrt(best)
end

local function maxScale(values: { number }?): number
	if not values or #values == 0 then
		return 1
	end
	local m = 0
	for _, v in values do
		m = math.max(m, v)
	end
	return m
end

-- How far the shape's effect reaches outside its points' bounds.
local function reach(shape: Shape, falloff: Falloff, width: number): number
	local offset = if falloff.align == "inside" then 0 elseif falloff.align == "center" then width / 2 else width
	if shape.kind == "path" then
		offset = (shape.radius + offset) * maxScale(shape.widthScale)
	end
	return offset + 1.5 * falloff.smoothing + Columns.VOXEL
end

-- The width the falloff will use before the field is known: for "inside"
-- polygons without a width, half the smaller side of the bounds (no less
-- than the inradius).
function Shapes.estimateWidth(shape: Shape, falloff: Falloff): number
	if falloff.width then
		return falloff.width
	elseif shape.kind == "polygon" and falloff.align == "inside" then
		local minX, minZ, maxX, maxZ = math.huge, math.huge, -math.huge, -math.huge
		for _, p in shape.points do
			minX, maxX = math.min(minX, p.X), math.max(maxX, p.X)
			minZ, maxZ = math.min(minZ, p.Z), math.max(maxZ, p.Z)
		end
		return math.max(Columns.VOXEL, math.min(maxX - minX, maxZ - minZ) / 2)
	end
	return DEFAULT_WIDTH
end

-- The XZ bounds of the columns the shape can affect, plus `margin`.
function Shapes.bounds(shape: Shape, falloff: Falloff, margin: number): (number, number, number, number)
	local r = reach(shape, falloff, Shapes.estimateWidth(shape, falloff)) + margin
	local minX, minZ, maxX, maxZ = math.huge, math.huge, -math.huge, -math.huge
	for _, p in shape.points do
		minX, maxX = math.min(minX, p.X), math.max(maxX, p.X)
		minZ, maxZ = math.min(minZ, p.Z), math.max(maxZ, p.Z)
	end
	return minX - r, minZ - r, maxX + r, maxZ + r
end

local function evaluatePolygon(shape: Shape, grid: Columns.Grid, falloff: Falloff): Evaluation
	local segs = segmentsOf(shape)
	local nx, nz = grid.nx, grid.nz
	local minX, minZ, maxX, maxZ = math.huge, math.huge, -math.huge, -math.huge
	for _, p in shape.points do
		minX, maxX = math.min(minX, p.X), math.max(maxX, p.X)
		minZ, maxZ = math.min(minZ, p.Z), math.max(maxZ, p.Z)
	end
	local area = math.max(1, (maxX - minX) * (maxZ - minZ))
	local index = buildIndex(segs, math.clamp(2 * math.sqrt(area / segs.count), 8, 256))
	-- outside a polygon that ramps inward, only the sign matters (unless blurred)
	local needOutside = falloff.align ~= "inside" or falloff.smoothing > 0
	local sd: { number } = table.create(grid.count, 0)
	local crossings: { number } = {}
	for iz = 1, nz do
		local z = Columns.z(grid, iz)
		-- inside test along the row (even-odd)
		table.clear(crossings)
		for i = 1, segs.count do
			local az, bz = segs.az[i], segs.bz[i]
			if (az > z) ~= (bz > z) then
				table.insert(crossings, segs.ax[i] + (z - az) * (segs.bx[i] - segs.ax[i]) / (bz - az))
			end
		end
		table.sort(crossings)
		local nextCrossing = 1
		local inside = false
		for ix = 1, nx do
			local x = Columns.x(grid, ix)
			while nextCrossing <= #crossings and crossings[nextCrossing] <= x do
				inside = not inside
				nextCrossing += 1
			end
			local idx = (iz - 1) * nx + ix
			if inside then
				sd[idx] = -nearestDistance(index, segs, x, z)
			elseif needOutside then
				sd[idx] = nearestDistance(index, segs, x, z)
			else
				sd[idx] = Columns.VOXEL
			end
		end
	end
	if falloff.smoothing > 0 then
		sd = Falloff.blur(sd, nx, nz, falloff.smoothing / 2 / Columns.VOXEL) :: { number }
	end
	local width = falloff.width
	if not width then
		if falloff.align == "inside" then
			local deepest = 0
			for idx = 1, grid.count do
				deepest = math.max(deepest, -sd[idx])
			end
			width = math.max(deepest, 1)
		else
			width = DEFAULT_WIDTH
		end
	end
	local w = width :: number
	local offset = if falloff.align == "inside" then 0 elseif falloff.align == "center" then w / 2 else w
	local e = table.create(grid.count, 0)
	for idx = 1, grid.count do
		e[idx] = (offset - sd[idx]) / w
	end
	return { grid = grid, e = e, width = w }
end

local function evaluatePath(shape: Shape, grid: Columns.Grid, falloff: Falloff, wantHeights: boolean): Evaluation
	local segs = segmentsOf(shape)
	local pointCount = #shape.points
	local width = falloff.width or DEFAULT_WIDTH
	local offset = if falloff.align == "inside" then 0 elseif falloff.align == "center" then width / 2 else width
	local scaleMax = maxScale(shape.widthScale)
	local range = (shape.radius + offset) * scaleMax + 1.5 * falloff.smoothing + Columns.VOXEL
	local index = buildIndex(segs, math.max(8, range))
	local nx = grid.nx
	local e = table.create(grid.count, 0)
	local heightScale = if shape.heightScale then table.create(grid.count, 1) else nil
	local ys = if wantHeights and shape.hasY then table.create(grid.count, 0) else nil
	local outside = -range / math.max(width, 1e-3)
	for iz = 1, grid.nz do
		local z = Columns.z(grid, iz)
		for ix = 1, nx do
			local x = Columns.x(grid, ix)
			local idx = (iz - 1) * nx + ix
			local best, bestSeg, bestT = outside, 0, 0
			forEachNear(index, x, z, range, function(i)
				local dSq, t = segmentDistance(segs, i, x, z)
				local scale = valueAt(shape.widthScale, pointCount, segs, i, t)
				local w = math.max(width * scale, 1e-3)
				local coverage = (offset * scale + shape.radius * scale - math.sqrt(dSq)) / w
				if coverage > best then
					best, bestSeg, bestT = coverage, i, t
				end
			end)
			e[idx] = best
			if bestSeg > 0 then
				if heightScale then
					heightScale[idx] = valueAt(shape.heightScale, pointCount, segs, bestSeg, bestT)
				end
				if ys then
					ys[idx] = segs.ay[bestSeg] + (segs.by[bestSeg] - segs.ay[bestSeg]) * bestT
				end
			end
		end
	end
	if falloff.smoothing > 0 then
		e = Falloff.blur(e, nx, grid.nz, falloff.smoothing / 2 / Columns.VOXEL) :: { number }
	end
	return { grid = grid, e = e, width = width, heightScale = heightScale, y = ys }
end

-- Coverage of every column of the grid. wantHeights: also interpolate the
-- path's Y (paths of Vector3s).
function Shapes.evaluate(shape: Shape, grid: Columns.Grid, falloff: Falloff, wantHeights: boolean): Evaluation
	if shape.kind == "polygon" then
		return evaluatePolygon(shape, grid, falloff)
	end
	return evaluatePath(shape, grid, falloff, wantHeights)
end

-- Columns just outside the shape (coverage <= 0, next to one above 0).
function Shapes.boundaryColumns(evaluation: Evaluation): { number }
	local grid, e = evaluation.grid, evaluation.e
	local nx, nz = grid.nx, grid.nz
	local result = {}
	for iz = 1, nz do
		for ix = 1, nx do
			local idx = (iz - 1) * nx + ix
			if e[idx] <= 0 then
				if (ix > 1 and e[idx - 1] > 0) or (ix < nx and e[idx + 1] > 0) or (iz > 1 and e[idx - nx] > 0) or (iz < nz and e[idx + nx] > 0) then
					table.insert(result, idx)
				end
			end
		end
	end
	return result
end

-- Rounds the corners of a polyline (Chaikin's corner cutting).
function Shapes.smoothPath(points: { Vector3 }, closed: boolean, iterations: number): { Vector3 }
	local current = points
	for _ = 1, iterations do
		local n = #current
		if n < 3 then
			break
		end
		local nextPoints = {}
		if not closed then
			table.insert(nextPoints, current[1])
		end
		local last = if closed then n else n - 1
		for i = 1, last do
			local a, b = current[i], current[i % n + 1]
			table.insert(nextPoints, a:Lerp(b, 0.25))
			table.insert(nextPoints, a:Lerp(b, 0.75))
		end
		if not closed then
			-- keep the end points exact: drop the cut nearest each end
			table.remove(nextPoints, 2)
			table.remove(nextPoints, #nextPoints)
			table.insert(nextPoints, current[n])
		end
		current = nextPoints
	end
	return current
end

return Shapes
