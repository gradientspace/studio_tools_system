--[[
	Columns: the voxel columns of an XZ area, read and written in tiles with
	Terrain:ReadVoxelChannels / WriteVoxelChannels.

	Voxel (i, j, k) covers [4i, 4i + 4) on each axis, so column (i, k) is
	centered at X = 4i + 2, Z = 4k + 2, and voxel j at Y = 4j + 2. A grid's
	columns are numbered row by row: idx = (iz - 1) * nx + ix.

	Surface height (measured in Studio, and what Terrain:FillBlock writes):
	with full voxels below it, a column whose topmost solid voxel is
	centered at c with occupancy o has its surface at c + 4 * o. So height h
	is written as occupancy clamp((h - c) / 4, 0, 1) at each voxel center c,
	and each voxel's occupancy can be read as filling the span [c, c + 4)
	from the bottom. Reading a height back finds the topmost solid voxel and
	adds up the partial voxels from there down to the first full (or empty)
	one: h = c_full + 4 + 4 * sum.
]]

local VOXEL = 4
local TILE = 32 -- columns per tile side
local FIRST_SLAB = 32 -- voxels in the first read while searching down for surfaces
local SLAB = 256 -- the most in later reads (each read doubles)
local PROBE = 4 -- probe every 4th column for where to start searching
local PROBE_MARGIN = 16 -- voxels above the highest probed terrain
local MAX_VOXELS = 4194304 -- per ReadVoxelChannels / WriteVoxelChannels call
local MAX_COLUMNS = 1024 * 1024
local FULL = 0.999
local CHANNELS = { "SolidMaterial", "SolidOccupancy", "LiquidOccupancy" }

export type Grid = {
	i0: number, -- voxel index of the first column on X
	k0: number, -- and on Z
	nx: number,
	nz: number,
	count: number,
}

-- fn(idx, n, occupancy, materials, liquid, bottom): one column's voxels
-- from Y = bottom up, voxel m centered at bottom + 4m - 2. Edits the arrays
-- in place and returns true if it changed anything.
export type ColumnFunction = (idx: number, n: number, occupancy: { number }, materials: { Enum.Material }, liquid: { number }, bottom: number) -> boolean

local Columns = {}
Columns.VOXEL = VOXEL
Columns.CHANNELS = CHANNELS

-- The columns whose centers lie within the XZ bounds, or nil if none do.
function Columns.grid(minX: number, minZ: number, maxX: number, maxZ: number): Grid?
	local i0 = math.ceil((minX - 2) / VOXEL)
	local i1 = math.floor((maxX - 2) / VOXEL)
	local k0 = math.ceil((minZ - 2) / VOXEL)
	local k1 = math.floor((maxZ - 2) / VOXEL)
	if i1 < i0 or k1 < k0 then
		return nil
	end
	local nx, nz = i1 - i0 + 1, k1 - k0 + 1
	if nx * nz > MAX_COLUMNS then
		error(`terrain edit too large: {nx * VOXEL} x {nz * VOXEL} studs (at most {MAX_COLUMNS} voxel columns)`, 3)
	end
	return { i0 = i0, k0 = k0, nx = nx, nz = nz, count = nx * nz }
end

-- The grid holding the single column at (x, z).
function Columns.gridAt(x: number, z: number): Grid
	return { i0 = math.floor(x / VOXEL), k0 = math.floor(z / VOXEL), nx = 1, nz = 1, count = 1 }
end

function Columns.x(grid: Grid, ix: number): number
	return VOXEL * (grid.i0 + ix - 1) + 2
end

function Columns.z(grid: Grid, iz: number): number
	return VOXEL * (grid.k0 + iz - 1) + 2
end

-- Returns a function to call between pieces of work: with `enabled`, it
-- yields once 50 ms have passed since the last yield.
function Columns.pacer(enabled: boolean?): () -> ()
	if not enabled then
		return function() end
	end
	local last = os.clock()
	return function()
		if os.clock() - last > 0.05 then
			task.wait()
			last = os.clock()
		end
	end
end

local function forEachTile(grid: Grid, fn: (tx0: number, tz0: number, tx1: number, tz1: number) -> ())
	for tz0 = 1, grid.nz, TILE do
		for tx0 = 1, grid.nx, TILE do
			fn(tx0, tz0, math.min(grid.nx, tx0 + TILE - 1), math.min(grid.nz, tz0 + TILE - 1))
		end
	end
end

local function tileRegion(grid: Grid, tx0: number, tz0: number, tx1: number, tz1: number, j0: number, j1: number): Region3
	return Region3.new(
		Vector3.new(VOXEL * (grid.i0 + tx0 - 1), VOXEL * j0, VOXEL * (grid.k0 + tz0 - 1)),
		Vector3.new(VOXEL * (grid.i0 + tx1), VOXEL * (j1 + 1), VOXEL * (grid.k0 + tz1))
	)
end

-- Where to start searching a tile for surfaces: reads every PROBE-th
-- column over the whole range (cheap: one voxel wide) and returns the
-- highest solid voxel found, plus PROBE_MARGIN; jMax if none is solid.
-- Searching from there instead of jMax skips reading the air above the
-- terrain. It misses only terrain that's narrower than the probe spacing,
-- higher than the margin above the probed columns and not connected to
-- anything below (connected terrain shows up at the top of the first read,
-- which restarts the search from jMax).
local function probeTop(grid: Grid, tx0: number, tz0: number, tx1: number, tz1: number, jMin: number, jMax: number): number
	local terrain = workspace.Terrain
	local highest = -math.huge
	local function probe(ix: number, iz: number)
		local x, z = grid.i0 + ix - 1, grid.k0 + iz - 1
		local top = jMax
		while top >= jMin do
			local bottom = math.max(jMin, top - 4095)
			local region = Region3.new(Vector3.new(VOXEL * x, VOXEL * bottom, VOXEL * z), Vector3.new(VOXEL * (x + 1), VOXEL * (top + 1), VOXEL * (z + 1)))
			local occupancy = terrain:ReadVoxelChannels(region, VOXEL, { "SolidOccupancy" }).SolidOccupancy[1]
			for y = top - bottom + 1, 1, -1 do
				if occupancy[y][1] > 0 then
					highest = math.max(highest, bottom + y - 1)
					return
				end
			end
			top = bottom - 1
		end
	end
	for iz = tz0, tz1 + PROBE - 1, PROBE do
		for ix = tx0, tx1 + PROBE - 1, PROBE do
			probe(math.min(ix, tx1), math.min(iz, tz1))
		end
	end
	if highest == -math.huge then
		return jMax
	end
	return math.min(jMax, highest + PROBE_MARGIN)
end

-- Whether any column of a read has solid in its top voxel.
local function topLayerSolid(occupancy: { { { number } } }, nx: number, nz: number, ny: number): boolean
	for x = 1, nx do
		local layer = occupancy[x][ny]
		for z = 1, nz do
			if layer[z] > 0 then
				return true
			end
		end
	end
	return false
end

-- Finds the topmost solid surface of each column (those in `mask`, or
-- all) between minY and maxY. Returns the heights (nil: no terrain) and
-- the material of each column's topmost solid voxel.
function Columns.findSurfaces(grid: Grid, mask: { boolean }?, minY: number, maxY: number, pace: () -> ()): ({ number? }, { Enum.Material? })
	local terrain = workspace.Terrain
	local heights: { number? } = table.create(grid.count)
	local materials: { Enum.Material? } = table.create(grid.count)
	local jMin = math.floor(minY / VOXEL)
	local jMax = math.ceil(maxY / VOXEL) - 1
	forEachTile(grid, function(tx0, tz0, tx1, tz1)
		-- per column: 0 searching, 1 adding up partial voxels, 2 done
		local state: { [number]: number } = {}
		local sums: { [number]: number } = {}
		local pending = 0
		for iz = tz0, tz1 do
			for ix = tx0, tx1 do
				local idx = (iz - 1) * grid.nx + ix
				if not mask or mask[idx] then
					state[idx] = 0
					sums[idx] = 0
					pending += 1
				end
			end
		end
		local top = probeTop(grid, tx0, tz0, tx1, tz1, jMin, jMax)
		local restarted = false
		local slab = FIRST_SLAB
		while pending > 0 and top >= jMin do
			local bottom = math.max(jMin, top - math.max(1, math.floor(MAX_VOXELS / ((tx1 - tx0 + 1) * (tz1 - tz0 + 1)))) + 1, top - slab + 1)
			slab = math.min(SLAB, slab * 2)
			local channels = terrain:ReadVoxelChannels(tileRegion(grid, tx0, tz0, tx1, tz1, bottom, top), VOXEL, CHANNELS)
			local occupancy, material = channels.SolidOccupancy, channels.SolidMaterial
			local ny = top - bottom + 1
			if top < jMax and not restarted and topLayerSolid(occupancy, tx1 - tx0 + 1, tz1 - tz0 + 1, ny) then
				-- the terrain goes above the probed estimate: search from the top
				restarted = true
				top = jMax
				continue
			end
			restarted = true
			for iz = tz0, tz1 do
				for ix = tx0, tx1 do
					local idx = (iz - 1) * grid.nx + ix
					local s = state[idx]
					if s ~= nil and s < 2 then
						local columnOcc = occupancy[ix - tx0 + 1]
						local columnMat = material[ix - tx0 + 1]
						local z = iz - tz0 + 1
						local sum = sums[idx]
						for y = ny, 1, -1 do
							local o = columnOcc[y][z]
							local c = VOXEL * (bottom + y - 1) + 2
							if s == 0 then
								if o > 0 then
									materials[idx] = columnMat[y][z]
									if o >= FULL then
										heights[idx] = c + VOXEL
										s = 2
										break
									end
									s = 1
									sum = o
								end
							elseif o >= FULL or o <= 0 then
								-- a full voxel, or air under the partial ones (counted as if full)
								heights[idx] = c + VOXEL + VOXEL * sum
								s = 2
								break
							else
								sum += o
							end
						end
						state[idx] = s
						sums[idx] = sum
						if s == 2 then
							pending -= 1
						end
					end
				end
			end
			top = bottom - 1
			pace()
		end
		for idx, s in state do
			if s == 1 then
				heights[idx] = VOXEL * jMin + 2 + VOXEL * sums[idx]
			end
		end
	end)
	return heights, materials
end

local function copyChannel<T>(channel: { { { T } } }): { { { T } } }
	local copy = table.create(#channel)
	for x, plane in channel do
		local planeCopy = table.create(#plane)
		for y, row in plane do
			planeCopy[y] = table.clone(row)
		end
		copy[x] = planeCopy
	end
	return copy
end

-- Runs fn on every column that has a range (lo[idx] to hi[idx], world Y),
-- reading and writing the voxels a tile at a time. Returns the number of
-- columns fn changed and the bounds of their voxels. With a snapshot
-- list, the original voxels of every tile it writes are added to it (see
-- Columns.restore).
function Columns.apply(grid: Grid, lo: { number? }, hi: { number? }, fn: ColumnFunction, pace: () -> (), snapshot: { any }?): (number, Region3?)
	local terrain = workspace.Terrain
	local changedColumns = 0
	local bMinX, bMinY, bMinZ = math.huge, math.huge, math.huge
	local bMaxX, bMaxY, bMaxZ = -math.huge, -math.huge, -math.huge
	local occ: { number }, mat: { Enum.Material }, liq: { number } = {}, {}, {}
	forEachTile(grid, function(tx0, tz0, tx1, tz1)
		local j0, j1 = math.huge, -math.huge
		for iz = tz0, tz1 do
			for ix = tx0, tx1 do
				local idx = (iz - 1) * grid.nx + ix
				local l, h = lo[idx], hi[idx]
				if l and h and h >= l then
					j0 = math.min(j0, math.floor(l / VOXEL))
					j1 = math.max(j1, math.floor(h / VOXEL))
				end
			end
		end
		if j0 > j1 then
			return
		end
		local columnsInTile = (tx1 - tx0 + 1) * (tz1 - tz0 + 1)
		if columnsInTile * (j1 - j0 + 1) > MAX_VOXELS then
			error(`terrain edit spans too much height ({(j1 - j0 + 1) * VOXEL} studs)`, 0)
		end
		local channels = terrain:ReadVoxelChannels(tileRegion(grid, tx0, tz0, tx1, tz1, j0, j1), VOXEL, CHANNELS)
		local occupancy, material, liquid = channels.SolidOccupancy, channels.SolidMaterial, channels.LiquidOccupancy
		local tileChanged = false
		for iz = tz0, tz1 do
			for ix = tx0, tx1 do
				local idx = (iz - 1) * grid.nx + ix
				local l, h = lo[idx], hi[idx]
				if l and h and h >= l then
					local cj0, cj1 = math.floor(l / VOXEL), math.floor(h / VOXEL)
					local n = cj1 - cj0 + 1
					local x, z = ix - tx0 + 1, iz - tz0 + 1
					local colOcc, colMat, colLiq = occupancy[x], material[x], liquid[x]
					local offset = cj0 - j0
					for m = 1, n do
						occ[m] = colOcc[offset + m][z]
						mat[m] = colMat[offset + m][z]
						liq[m] = colLiq[offset + m][z]
					end
					if fn(idx, n, occ, mat, liq, VOXEL * cj0) then
						if snapshot and not tileChanged then
							-- the tile's arrays are still as read: keep a copy
							table.insert(snapshot, {
								region = tileRegion(grid, tx0, tz0, tx1, tz1, j0, j1),
								channels = {
									SolidMaterial = copyChannel(material),
									SolidOccupancy = copyChannel(occupancy),
									LiquidOccupancy = copyChannel(liquid),
								},
							})
						end
						for m = 1, n do
							local o = math.clamp(occ[m], 0, 1)
							colOcc[offset + m][z] = o
							colMat[offset + m][z] = if o > 0 then mat[m] else Enum.Material.Air
							colLiq[offset + m][z] = math.clamp(liq[m], 0, 1)
						end
						tileChanged = true
						changedColumns += 1
						local cx, cz = grid.i0 + ix - 1, grid.k0 + iz - 1
						bMinX, bMaxX = math.min(bMinX, cx), math.max(bMaxX, cx)
						bMinZ, bMaxZ = math.min(bMinZ, cz), math.max(bMaxZ, cz)
						bMinY, bMaxY = math.min(bMinY, cj0), math.max(bMaxY, cj1)
					end
				end
			end
		end
		if tileChanged then
			terrain:WriteVoxelChannels(tileRegion(grid, tx0, tz0, tx1, tz1, j0, j1), VOXEL, {
				SolidMaterial = material,
				SolidOccupancy = occupancy,
				LiquidOccupancy = liquid,
			})
		end
		pace()
	end)
	if changedColumns == 0 then
		return 0, nil
	end
	return changedColumns,
		Region3.new(
			Vector3.new(VOXEL * bMinX, VOXEL * bMinY, VOXEL * bMinZ),
			Vector3.new(VOXEL * (bMaxX + 1), VOXEL * (bMaxY + 1), VOXEL * (bMaxZ + 1))
		)
end

-- Writes back the voxels a snapshot from Columns.apply holds, newest first.
function Columns.restore(snapshot: { any }, pace: () -> ())
	local terrain = workspace.Terrain
	for i = #snapshot, 1, -1 do
		local tile = snapshot[i]
		terrain:WriteVoxelChannels(tile.region, VOXEL, tile.channels)
		pace()
	end
end

-- Calls fn for every voxel of the region (expanded to the voxel grid) and
-- writes back what it returns. Returns the number of voxels changed.
function Columns.forEachVoxel(region: Region3, fn: (Vector3, Enum.Material, number, number) -> (Enum.Material?, number?, number?), pace: () -> ()): number
	local terrain = workspace.Terrain
	local r = region:ExpandToGrid(VOXEL)
	local minV = r.CFrame.Position - r.Size / 2
	local i0, j0, k0 = math.round(minV.X / VOXEL), math.round(minV.Y / VOXEL), math.round(minV.Z / VOXEL)
	local nx, ny, nz = math.round(r.Size.X / VOXEL), math.round(r.Size.Y / VOXEL), math.round(r.Size.Z / VOXEL)
	local changed = 0
	-- chunks of at most 32 x 32 columns and a height that fits the call limit
	local chunkY = math.max(1, math.floor(MAX_VOXELS / (TILE * TILE)))
	for ci = 0, nx - 1, TILE do
		for ck = 0, nz - 1, TILE do
			for cj = 0, ny - 1, chunkY do
				local cx, cy, cz = math.min(TILE, nx - ci), math.min(chunkY, ny - cj), math.min(TILE, nz - ck)
				local chunk = Region3.new(
					Vector3.new(VOXEL * (i0 + ci), VOXEL * (j0 + cj), VOXEL * (k0 + ck)),
					Vector3.new(VOXEL * (i0 + ci + cx), VOXEL * (j0 + cj + cy), VOXEL * (k0 + ck + cz))
				)
				local channels = terrain:ReadVoxelChannels(chunk, VOXEL, CHANNELS)
				local occupancy, material, liquid = channels.SolidOccupancy, channels.SolidMaterial, channels.LiquidOccupancy
				local chunkChanged = false
				for x = 1, cx do
					local px = VOXEL * (i0 + ci + x - 1) + 2
					for y = 1, cy do
						local py = VOXEL * (j0 + cj + y - 1) + 2
						for z = 1, cz do
							local m0, o0, l0 = material[x][y][z], occupancy[x][y][z], liquid[x][y][z]
							local m1, o1, l1 = fn(Vector3.new(px, py, VOXEL * (k0 + ck + z - 1) + 2), m0, o0, l0)
							m1, o1, l1 = m1 or m0, math.clamp(o1 or o0, 0, 1), math.clamp(l1 or l0, 0, 1)
							if m1 == Enum.Material.Air then
								o1 = 0
							elseif m1 == Enum.Material.Water then
								-- water lives in the liquid channel
								m1, l1, o1 = Enum.Material.Air, math.max(l1, o1), 0
							end
							if o1 <= 0 then
								m1 = Enum.Material.Air
							end
							if m1 ~= m0 or math.abs(o1 - o0) > 1e-4 or math.abs(l1 - l0) > 1e-4 then
								material[x][y][z], occupancy[x][y][z], liquid[x][y][z] = m1, o1, l1
								chunkChanged = true
								changed += 1
							end
						end
					end
				end
				if chunkChanged then
					terrain:WriteVoxelChannels(chunk, VOXEL, {
						SolidMaterial = material,
						SolidOccupancy = occupancy,
						LiquidOccupancy = liquid,
					})
				end
				pace()
			end
		end
	end
	return changed
end

return Columns
