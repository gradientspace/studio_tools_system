--[[
	Brushes: what one brush dab does to a SculptMesh.

	A dab is a sphere on the stroke-start surface. Its vertices are found on
	that surface (SculptMesh:gatherVertices), each weighted by the falloff of
	its stroke-start distance from the center, and then moved from wherever
	they are now. Region normals and planes come from the stroke-start
	normals and positions too, so repeated dabs in one stroke agree with each
	other.

	Grab is different: it picks its vertices once, at the start of the drag,
	and places them at their start positions plus the drag offset times
	their weight.
]]

local sqrt = math.sqrt

local Brushes = {}

export type Dab = {
	cx: number, -- center, on the stroke-start surface (local space)
	cy: number,
	cz: number,
	nx: number, -- surface normal at the center (unit; fallback for the region normal)
	ny: number,
	nz: number,
	vx: number, -- view direction (unit, from the camera into the scene)
	vy: number,
	vz: number,
	radius: number,
	strength: number, -- 0..1
	invert: boolean,
	falloff: (number) -> number, -- weight for distance/radius in 0..1
	frontOnly: boolean, -- skip vertices facing away from the camera
	rateScale: number, -- scales per-dab amounts with the dab spacing
}

-- Per-dab rates, tuned for the default spacing (see rateScale).
local DRAW_RATE = 0.04 -- of the radius, at full strength
local CLAY_OFFSET = 0.15 -- plane height above the surface, of the radius, at full strength
local CLAY_RATE = 0.5 -- fraction of the way to the plane per dab
local FLATTEN_RATE = 0.3
local PINCH_RATE = 0.12

Brushes.Names = { "Clay", "Draw", "Flatten", "Smooth", "Inflate", "Pinch", "Crease", "Grab" }

Brushes.Falloffs = {
	Smooth = function(t: number): number
		return 1 - t * t * (3 - 2 * t)
	end,
	Sphere = function(t: number): number
		return sqrt(math.max(0, 1 - t * t))
	end,
	Linear = function(t: number): number
		return 1 - t
	end,
	Sharp = function(t: number): number
		return (1 - t) * (1 - t)
	end,
	Constant = function(_t: number): number
		return 1
	end,
}
Brushes.FalloffNames = { "Smooth", "Sphere", "Linear", "Sharp", "Constant" }

-- Scratch arrays shared by all dabs (dabs never overlap in time).
local regionVerts: { number } = {}
local regionWeights: { number } = {}
local smoothX: { number } = {}
local smoothY: { number } = {}
local smoothZ: { number } = {}

-- The dab's vertices with nonzero weight (into regionVerts/regionWeights),
-- plus the weighted center and unit normal of the region on the
-- stroke-start surface.
local function region(sm: any, dab: Dab): (number, number, number, number, number, number, number)
	local n = sm:gatherVertices(dab.cx, dab.cy, dab.cz, dab.radius, regionVerts)
	local hp, nrm = sm.hitPos, sm.hitNrm
	local cx, cy, cz, r = dab.cx, dab.cy, dab.cz, dab.radius
	local vx, vy, vz = dab.vx, dab.vy, dab.vz
	local falloff, frontOnly = dab.falloff, dab.frontOnly
	local count = 0
	local sw, px, py, pz, ax, ay, az = 0, 0, 0, 0, 0, 0, 0
	for i = 1, n do
		local v = regionVerts[i]
		local p = 3 * v
		local hx, hy, hz = hp[p + 1], hp[p + 2], hp[p + 3]
		local ex, ey, ez = hx - cx, hy - cy, hz - cz
		local t = sqrt(ex * ex + ey * ey + ez * ez) / r
		local w = falloff(if t > 1 then 1 else t)
		local nx, ny, nz = nrm[p + 1], nrm[p + 2], nrm[p + 3]
		if frontOnly and nx * vx + ny * vy + nz * vz > 0 then
			w = 0
		end
		if w > 0 then
			count += 1
			regionVerts[count] = v
			regionWeights[count] = w
			sw += w
			px += hx * w
			py += hy * w
			pz += hz * w
			ax += nx * w
			ay += ny * w
			az += nz * w
		end
	end
	if count == 0 then
		return 0, cx, cy, cz, dab.nx, dab.ny, dab.nz
	end
	local len = sqrt(ax * ax + ay * ay + az * az)
	if len < 1e-12 then
		ax, ay, az = dab.nx, dab.ny, dab.nz
	else
		ax, ay, az = ax / len, ay / len, az / len
	end
	return count, px / sw, py / sw, pz / sw, ax, ay, az
end

-- Applies one dab of `brush` (one of Brushes.Names, except Grab) to the mesh.
-- smoothStrength is used by Smooth.
function Brushes.dab(sm: any, brush: string, dab: Dab, smoothStrength: number)
	local count, ox, oy, oz, ax, ay, az = region(sm, dab)
	if count == 0 then
		return
	end
	local pos = sm.pos
	local sign = if dab.invert then -1 else 1
	local s = dab.strength
	local r = dab.radius

	if brush == "Smooth" then
		-- Jacobi step toward the neighbor average, so the result doesn't depend
		-- on vertex order.
		local nbrs = sm.smoothNbrs
		local amount = math.clamp(smoothStrength, 0, 1)
		for i = 1, count do
			local v = regionVerts[i]
			local p = 3 * v
			local list = nbrs[v + 1]
			local m = #list
			if m > 0 then
				local sx, sy, sz = 0, 0, 0
				for _, u in list do
					local q = 3 * u
					sx += pos[q + 1]
					sy += pos[q + 2]
					sz += pos[q + 3]
				end
				local f = regionWeights[i] * amount
				smoothX[i] = pos[p + 1] + (sx / m - pos[p + 1]) * f
				smoothY[i] = pos[p + 2] + (sy / m - pos[p + 2]) * f
				smoothZ[i] = pos[p + 3] + (sz / m - pos[p + 3]) * f
			else
				smoothX[i], smoothY[i], smoothZ[i] = pos[p + 1], pos[p + 2], pos[p + 3]
			end
		end
		for i = 1, count do
			local v = regionVerts[i]
			local p = 3 * v
			pos[p + 1], pos[p + 2], pos[p + 3] = smoothX[i], smoothY[i], smoothZ[i]
			sm:moved(v)
		end
		return
	end

	if brush == "Draw" or brush == "Inflate" or brush == "Crease" then
		local h = r * s * DRAW_RATE * dab.rateScale * (if brush == "Crease" then -sign else sign)
		local nrm = sm.hitNrm
		local pinch = if brush == "Crease" then PINCH_RATE * s else 0
		local cx, cy, cz = dab.cx, dab.cy, dab.cz
		for i = 1, count do
			local v = regionVerts[i]
			local w = regionWeights[i]
			local p = 3 * v
			local dx, dy, dz
			if brush == "Inflate" then
				dx, dy, dz = nrm[p + 1], nrm[p + 2], nrm[p + 3]
			else
				dx, dy, dz = ax, ay, az
			end
			local x = pos[p + 1] + dx * h * w
			local y = pos[p + 2] + dy * h * w
			local z = pos[p + 3] + dz * h * w
			if pinch > 0 then
				-- pull toward the line through the center along the region normal
				local tx, ty, tz = cx - x, cy - y, cz - z
				local along = tx * ax + ty * ay + tz * az
				tx, ty, tz = tx - ax * along, ty - ay * along, tz - az * along
				x += tx * w * pinch
				y += ty * w * pinch
				z += tz * w * pinch
			end
			pos[p + 1], pos[p + 2], pos[p + 3] = x, y, z
			sm:moved(v)
		end
		return
	end

	if brush == "Clay" then
		-- Pull everything below a plane slightly above the region up to it
		-- (or, inverted, everything above a plane below it down).
		local offset = r * CLAY_OFFSET * s * sign
		local qx, qy, qz = ox + ax * offset, oy + ay * offset, oz + az * offset
		for i = 1, count do
			local v = regionVerts[i]
			local p = 3 * v
			local d = (pos[p + 1] - qx) * ax + (pos[p + 2] - qy) * ay + (pos[p + 3] - qz) * az
			if d * sign < 0 then
				local m = -d * regionWeights[i] * CLAY_RATE
				pos[p + 1] += ax * m
				pos[p + 2] += ay * m
				pos[p + 3] += az * m
				sm:moved(v)
			end
		end
		return
	end

	if brush == "Flatten" then
		-- Toward the region's plane (inverted: away from it, adding contrast).
		local rate = FLATTEN_RATE * s * sign
		for i = 1, count do
			local v = regionVerts[i]
			local p = 3 * v
			local d = (pos[p + 1] - ox) * ax + (pos[p + 2] - oy) * ay + (pos[p + 3] - oz) * az
			local m = -d * regionWeights[i] * rate
			pos[p + 1] += ax * m
			pos[p + 2] += ay * m
			pos[p + 3] += az * m
			sm:moved(v)
		end
		return
	end

	if brush == "Pinch" then
		-- Toward the line through the center along the region normal
		-- (inverted: away from it).
		local rate = PINCH_RATE * s * sign
		local cx, cy, cz = dab.cx, dab.cy, dab.cz
		for i = 1, count do
			local v = regionVerts[i]
			local p = 3 * v
			local tx, ty, tz = cx - pos[p + 1], cy - pos[p + 2], cz - pos[p + 3]
			local along = tx * ax + ty * ay + tz * az
			local f = regionWeights[i] * rate
			pos[p + 1] += (tx - ax * along) * f
			pos[p + 2] += (ty - ay * along) * f
			pos[p + 3] += (tz - az * along) * f
			sm:moved(v)
		end
		return
	end
end

-- Grab --------------------------------------------------------------------

export type GrabRegion = {
	verts: { number },
	weights: { number },
	count: number,
	-- The drag offset is multiplied componentwise by this (mirrored regions
	-- flip one axis).
	mx: number,
	my: number,
	mz: number,
}

-- The vertices a grab at this dab picks up.
function Brushes.grabRegion(sm: any, dab: Dab, mx: number, my: number, mz: number): GrabRegion
	local count = region(sm, dab)
	return {
		verts = table.move(regionVerts, 1, count, 1, table.create(count)),
		weights = table.move(regionWeights, 1, count, 1, table.create(count)),
		count = count,
		mx = mx,
		my = my,
		mz = mz,
	}
end

-- Places the grabbed vertices at their stroke-start positions plus the
-- (local) drag offset times their weight. Where mirrored regions overlap, a
-- vertex gets the weight-averaged offset, scaled by its largest weight, so
-- points on the mirror plane stay on it.
function Brushes.updateGrab(sm: any, regions: { GrabRegion }, dx: number, dy: number, dz: number)
	local pos, hp = sm.pos, sm.hitPos
	if #regions == 1 then
		local g = regions[1]
		for i = 1, g.count do
			local v, w = g.verts[i], g.weights[i]
			local p = 3 * v
			pos[p + 1] = hp[p + 1] + dx * g.mx * w
			pos[p + 2] = hp[p + 2] + dy * g.my * w
			pos[p + 3] = hp[p + 3] + dz * g.mz * w
			sm:moved(v)
		end
		return
	end
	local sums = {} -- v -> { wdx, wdy, wdz, sumW, maxW }
	for _, g in regions do
		for i = 1, g.count do
			local v, w = g.verts[i], g.weights[i]
			local acc = sums[v]
			if not acc then
				acc = { 0, 0, 0, 0, 0 }
				sums[v] = acc
			end
			acc[1] += dx * g.mx * w
			acc[2] += dy * g.my * w
			acc[3] += dz * g.mz * w
			acc[4] += w
			acc[5] = math.max(acc[5], w)
		end
	end
	for v, acc in sums do
		local p = 3 * v
		local scale = acc[5] / acc[4]
		pos[p + 1] = hp[p + 1] + acc[1] * scale
		pos[p + 2] = hp[p + 2] + acc[2] * scale
		pos[p + 3] = hp[p + 3] + acc[3] * scale
		sm:moved(v)
	end
end

return Brushes
