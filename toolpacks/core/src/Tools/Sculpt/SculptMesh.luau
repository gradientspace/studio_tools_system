--[[
	SculptMesh: the mesh being sculpted, in the source MeshPart's local space
	(studs, scaled; the part's CFrame maps it to the world).

	Two copies of the geometry:
	  mesh      a DMesh3 holding the current positions; brushes move these.
	  hitMesh   a DMesh3 copy holding the positions at the start of the
	            current stroke, with an AABB tree over it. Brushes find their
	            vertices and hit points on it, so a stroke works against the
	            surface as it was when the stroke began. endStroke() copies the
	            moved vertices into it and refits the tree.

	Topology never changes, so the tree's boxes can be refit in place instead
	of rebuilt, and per-vertex neighbor and triangle lists are computed once.

	Positions are flat arrays (DMesh3's own storage): vertex v is at
	[3v+1], [3v+2], [3v+3]. Vertex normals use the same layout, in two
	copies like the positions: nrm follows the current positions (recomputed
	for the moved region while a stroke runs, for display), and hitNrm holds
	the stroke-start normals the brushes use (synced when a stroke ends).

	A stroke is a list of moved vertices with their deltas ("records"), so
	undo and redo apply or subtract the deltas instead of storing meshes.
]]

local DMesh3 = require(script:FindFirstAncestor("StudioTools").Libraries.geometry3luau.DMesh3)
local DMeshAABBTree3 = require(script:FindFirstAncestor("StudioTools").Libraries.geometry3luau.DMeshAABBTree3)
local RobloxMesh = require(script:FindFirstAncestor("StudioTools").Libraries.geometry3luau.RobloxMesh)
local Ray3d = require(script:FindFirstAncestor("StudioTools").Libraries.geometry3luau.Ray3d)
local Vector3d = require(script:FindFirstAncestor("StudioTools").Libraries.geometry3luau.Vector3d)
local IntrRay3Triangle3 = require(script:FindFirstAncestor("StudioTools").Libraries.geometry3luau.IntrRay3Triangle3)

local sqrt = math.sqrt
local HUGE = math.huge

local SculptMesh = {}
SculptMesh.__index = SculptMesh

-- A stroke's undo record: flat { v, dx, dy, dz, v, dx, dy, dz, ... }.
export type Record = { number }

-- Reads a MeshPart's mesh (an EditableMesh) into a SculptMesh in part-local
-- space: mesh vertex m goes to scale * (m - center). vertexMap maps each
-- editable vertex id to the SculptMesh vertex it was welded into. Errors if
-- the mesh has no triangles.
function SculptMesh.fromEditable(editable: EditableMesh, scale: Vector3, center: Vector3)
	local sx, sy, sz = scale.X, scale.Y, scale.Z
	local cx, cy, cz = center.X, center.Y, center.Z
	local mesh, info = RobloxMesh.FromEditableMesh(editable, {
		weld = "positions", -- join vertices split at UV/normal seams, so seams don't tear
		normals = "none",
		uvs = "triangle",
		transform = function(x: number, y: number, z: number): (number, number, number)
			return (x - cx) * sx, (y - cy) * sy, (z - cz) * sz
		end,
	})
	if mesh:TriangleCount() == 0 then
		error("the mesh has no triangles", 0)
	end
	local self = setmetatable({}, SculptMesh)
	self:_init(mesh)
	self.failedTriangles = info and info.failed or 0
	self.vertexMap = info and info.vertexMap or {}
	return self
end

function SculptMesh:_init(mesh: any)
	self.mesh = mesh
	self.pos = mesh.vertices.data
	self.tris = mesh.triangles.data
	self.maxVertex = mesh:MaxVertexID()
	self.maxTriangle = mesh:MaxTriangleID()
	self.vertexCount = mesh:VertexCount()
	self.triangleCount = mesh:TriangleCount()

	self.hitMesh = DMesh3.FromCopy(mesh, false, false, false, false)
	self.hitPos = self.hitMesh.vertices.data
	self.tree = DMeshAABBTree3.new(self.hitMesh, true)

	-- The original positions, for resetting.
	self.origPos = table.clone(self.pos)

	local nV, nT = self.maxVertex, self.maxTriangle
	local tris = self.tris

	-- Per-vertex triangle lists (1-based by vertex id + 1).
	local vtris = table.create(nV)
	for v = 1, nV do
		vtris[v] = {}
	end
	for t = 0, nT - 1 do
		if mesh:IsTriangle(t) then
			local k = 3 * t
			for j = 1, 3 do
				local list = vtris[tris[k + j] + 1]
				list[#list + 1] = t
			end
		end
	end
	self.vtris = vtris

	-- Neighbors used for smoothing. Boundary vertices only follow their
	-- boundary neighbors, so open edges keep their shape instead of shrinking.
	local nbrs = table.create(nV)
	for v = 0, nV - 1 do
		local list = {}
		if mesh:IsVertex(v) then
			local boundary = mesh:IsBoundaryVertex(v)
			for eid in mesh:VtxEdgesItr(v) do
				if not boundary or mesh:IsBoundaryEdge(eid) then
					list[#list + 1] = mesh:edge_other_v(eid, v)
				end
			end
		end
		nbrs[v + 1] = list
	end
	self.smoothNbrs = nbrs

	self.nrm = table.create(3 * nV, 0)
	self:computeNormals(nil)
	self.hitNrm = table.clone(self.nrm)

	-- Scratch marks: a mark array plus a counter avoids clearing per query.
	self._queryMark = table.create(nV, 0)
	self._queryStamp = 0
	self._touchMark = table.create(nV, 0)
	self._strokeId = 0
	self._touched = {}
	self._touchedCount = 0
	self._dirtyMark = table.create(nV, 0)
	self._flushId = 1
	self._dirty = {}
	self._dirtyCount = 0
	self._stack = {}

	local bounds = mesh:GetBounds()
	self.center = Vector3.new((bounds.Min.x + bounds.Max.x) / 2, (bounds.Min.y + bounds.Max.y) / 2, (bounds.Min.z + bounds.Max.z) / 2)
	self.size = Vector3.new(bounds.Max.x - bounds.Min.x, bounds.Max.y - bounds.Min.y, bounds.Max.z - bounds.Min.z)
end

-- Normals ----------------------------------------------------------------

-- Area-weighted vertex normals from the current positions, for the given
-- vertices (an array of ids, `count` long) or for all of them (vids nil).
function SculptMesh:computeNormals(vids: { number }?, count: number?)
	local pos, tris, nrm, vtris = self.pos, self.tris, self.nrm, self.vtris
	local function one(v: number)
		local sx, sy, sz = 0, 0, 0
		for _, t in vtris[v + 1] do
			local k = 3 * t
			local a, b, c = 3 * tris[k + 1], 3 * tris[k + 2], 3 * tris[k + 3]
			local ax, ay, az = pos[a + 1], pos[a + 2], pos[a + 3]
			local e1x, e1y, e1z = pos[b + 1] - ax, pos[b + 2] - ay, pos[b + 3] - az
			local e2x, e2y, e2z = pos[c + 1] - ax, pos[c + 2] - ay, pos[c + 3] - az
			sx += e1y * e2z - e1z * e2y
			sy += e1z * e2x - e1x * e2z
			sz += e1x * e2y - e1y * e2x
		end
		local len = sqrt(sx * sx + sy * sy + sz * sz)
		local i = 3 * v
		if len > 1e-20 then
			nrm[i + 1], nrm[i + 2], nrm[i + 3] = sx / len, sy / len, sz / len
		else
			nrm[i + 1], nrm[i + 2], nrm[i + 3] = 0, 1, 0
		end
	end
	if vids then
		for i = 1, count or #vids do
			one(vids[i])
		end
	else
		for v = 0, self.maxVertex - 1 do
			one(v)
		end
	end
end

-- Copies the current normals of these vertices into the stroke-start normals.
function SculptMesh:syncHitNormals(vids: { number }, count: number)
	local nrm, hitNrm = self.nrm, self.hitNrm
	for i = 1, count do
		local p = 3 * vids[i]
		hitNrm[p + 1], hitNrm[p + 2], hitNrm[p + 3] = nrm[p + 1], nrm[p + 2], nrm[p + 3]
	end
end

-- Unit normal of triangle t from the current positions.
function SculptMesh:triangleNormal(t: number): (number, number, number)
	local pos, tris = self.pos, self.tris
	local k = 3 * t
	local a, b, c = 3 * tris[k + 1], 3 * tris[k + 2], 3 * tris[k + 3]
	local ax, ay, az = pos[a + 1], pos[a + 2], pos[a + 3]
	local e1x, e1y, e1z = pos[b + 1] - ax, pos[b + 2] - ay, pos[b + 3] - az
	local e2x, e2y, e2z = pos[c + 1] - ax, pos[c + 2] - ay, pos[c + 3] - az
	local nx, ny, nz = e1y * e2z - e1z * e2y, e1z * e2x - e1x * e2z, e1x * e2y - e1y * e2x
	local len = sqrt(nx * nx + ny * ny + nz * nz)
	if len < 1e-20 then
		return 0, 1, 0
	end
	return nx / len, ny / len, nz / len
end

-- The triangles that touch the given vertices, and the vertices of those
-- triangles: what needs new normals after the vertices moved.
function SculptMesh:affectedRegion(vids: { number }, count: number): ({ number }, number, { number }, number)
	self._queryStamp += 1
	local stamp = self._queryStamp
	local mark = self._queryMark
	-- Triangle marks share the vertex mark array's stamp but need their own array.
	local triMark = self._triMark
	if not triMark then
		triMark = table.create(self.maxTriangle, 0)
		self._triMark = triMark
	end
	local tris, vtris = self.tris, self.vtris
	local outT, nT = {}, 0
	local outV, nV = {}, 0
	for i = 1, count do
		for _, t in vtris[vids[i] + 1] do
			if triMark[t + 1] ~= stamp then
				triMark[t + 1] = stamp
				nT += 1
				outT[nT] = t
				local k = 3 * t
				for j = 1, 3 do
					local v = tris[k + j]
					if mark[v + 1] ~= stamp then
						mark[v + 1] = stamp
						nV += 1
						outV[nV] = v
					end
				end
			end
		end
	end
	return outT, nT, outV, nV
end

-- Queries on the stroke-start surface ----------------------------------------

-- Nearest hit of a local-space ray (unit direction) with the stroke-start
-- surface: distance along the ray and triangle id, or nil.
function SculptMesh:raycast(origin: Vector3, direction: Vector3): (number?, number?)
	-- Vector3 is single precision, so a "unit" Vector3 can fail the tree's
	-- double-precision normalization check: renormalize in doubles.
	local dx, dy, dz = direction.X, direction.Y, direction.Z
	local len = sqrt(dx * dx + dy * dy + dz * dz)
	if len < 1e-12 then
		return nil, nil
	end
	dx, dy, dz = dx / len, dy / len, dz / len
	local ray = Ray3d.new(Vector3d.new(origin.X, origin.Y, origin.Z), Vector3d.new(dx, dy, dz), true)
	local tid = self.tree:FindNearestHitTriangle(ray)
	if tid < 0 then
		return nil, nil
	end
	local hp, tris = self.hitPos, self.tris
	local k = 3 * tid
	local a, b, c = 3 * tris[k + 1], 3 * tris[k + 2], 3 * tris[k + 3]
	local hit, t = IntrRay3Triangle3.IntersectsXYZ(
		origin.X,
		origin.Y,
		origin.Z,
		dx,
		dy,
		dz,
		hp[a + 1],
		hp[a + 2],
		hp[a + 3],
		hp[b + 1],
		hp[b + 2],
		hp[b + 3],
		hp[c + 1],
		hp[c + 2],
		hp[c + 3]
	)
	if not hit then
		return nil, nil
	end
	return t / len, tid -- in units of the given direction
end

-- Unit normal of triangle t on the stroke-start surface.
function SculptMesh:hitTriangleNormal(t: number): (number, number, number)
	local hp, tris = self.hitPos, self.tris
	local k = 3 * t
	local a, b, c = 3 * tris[k + 1], 3 * tris[k + 2], 3 * tris[k + 3]
	local ax, ay, az = hp[a + 1], hp[a + 2], hp[a + 3]
	local e1x, e1y, e1z = hp[b + 1] - ax, hp[b + 2] - ay, hp[b + 3] - az
	local e2x, e2y, e2z = hp[c + 1] - ax, hp[c + 2] - ay, hp[c + 3] - az
	local nx, ny, nz = e1y * e2z - e1z * e2y, e1z * e2x - e1x * e2z, e1x * e2y - e1y * e2x
	local len = sqrt(nx * nx + ny * ny + nz * nz)
	if len < 1e-20 then
		return 0, 1, 0
	end
	return nx / len, ny / len, nz / len
end

-- Collects the vertices whose stroke-start positions are within r of
-- (cx, cy, cz) into `out`; returns how many. Walks the AABB tree's boxes
-- directly (see DMeshAABBTree3's storage notes), testing each box against
-- the sphere.
function SculptMesh:gatherVertices(cx: number, cy: number, cz: number, r: number, out: { number }): number
	local tree = self.tree
	local btoi, ilist, bb, tend = tree.box_to_index, tree.index_list, tree.box_bounds, tree.triangles_end
	local tris, hp = self.tris, self.hitPos
	self._queryStamp += 1
	local stamp = self._queryStamp
	local mark = self._queryMark
	local r2 = r * r
	local stack = self._stack
	local top = 1
	stack[1] = tree.root_index
	local n = 0
	while top > 0 do
		local iBox = stack[top]
		top -= 1
		local o = 6 * iBox
		local dx = if cx < bb[o + 1] then bb[o + 1] - cx elseif cx > bb[o + 4] then cx - bb[o + 4] else 0
		local dy = if cy < bb[o + 2] then bb[o + 2] - cy elseif cy > bb[o + 5] then cy - bb[o + 5] else 0
		local dz = if cz < bb[o + 3] then bb[o + 3] - cz elseif cz > bb[o + 6] then cz - bb[o + 6] else 0
		if dx * dx + dy * dy + dz * dz <= r2 then
			local idx = btoi[iBox + 1]
			if idx < tend then -- leaf: [N t1 ... tN]
				for i = 1, ilist[idx + 1] do
					local k = 3 * ilist[idx + i + 1]
					for j = 1, 3 do
						local v = tris[k + j]
						if mark[v + 1] ~= stamp then
							mark[v + 1] = stamp
							local p = 3 * v
							local ex, ey, ez = hp[p + 1] - cx, hp[p + 2] - cy, hp[p + 3] - cz
							if ex * ex + ey * ey + ez * ez <= r2 then
								n += 1
								out[n] = v
							end
						end
					end
				end
			else -- internal node: one child (encoded negative) or two
				local child1 = ilist[idx + 1]
				if child1 < 0 then
					top += 1
					stack[top] = -child1 - 1
				else
					top += 1
					stack[top] = child1 - 1
					top += 1
					stack[top] = ilist[idx + 2] - 1
				end
			end
		end
	end
	return n
end

-- Recomputes every box of the AABB tree from the stroke-start positions,
-- keeping its structure (valid because the topology never changes).
function SculptMesh:refitTree()
	local tree = self.tree
	local btoi, ilist, bc, be, tend = tree.box_to_index, tree.index_list, tree.box_centers, tree.box_extents, tree.triangles_end
	local tris, hp = self.tris, self.hitPos

	local function fit(iBox: number): (number, number, number, number, number, number)
		local idx = btoi[iBox + 1]
		local minx, miny, minz, maxx, maxy, maxz = HUGE, HUGE, HUGE, -HUGE, -HUGE, -HUGE
		if idx < tend then
			for i = 1, ilist[idx + 1] do
				local k = 3 * ilist[idx + i + 1]
				for j = 1, 3 do
					local p = 3 * tris[k + j]
					local x, y, z = hp[p + 1], hp[p + 2], hp[p + 3]
					if x < minx then
						minx = x
					end
					if x > maxx then
						maxx = x
					end
					if y < miny then
						miny = y
					end
					if y > maxy then
						maxy = y
					end
					if z < minz then
						minz = z
					end
					if z > maxz then
						maxz = z
					end
				end
			end
		else
			local child1 = ilist[idx + 1]
			if child1 < 0 then
				minx, miny, minz, maxx, maxy, maxz = fit(-child1 - 1)
			else
				local aminx, aminy, aminz, amaxx, amaxy, amaxz = fit(child1 - 1)
				local bminx, bminy, bminz, bmaxx, bmaxy, bmaxz = fit(ilist[idx + 2] - 1)
				minx, miny, minz = math.min(aminx, bminx), math.min(aminy, bminy), math.min(aminz, bminz)
				maxx, maxy, maxz = math.max(amaxx, bmaxx), math.max(amaxy, bmaxy), math.max(amaxz, bmaxz)
			end
		end
		if minx <= maxx then -- empty leaves keep their old box
			local k = 3 * iBox
			bc[k + 1], bc[k + 2], bc[k + 3] = 0.5 * (minx + maxx), 0.5 * (miny + maxy), 0.5 * (minz + maxz)
			be[k + 1], be[k + 2], be[k + 3] = 0.5 * (maxx - minx), 0.5 * (maxy - miny), 0.5 * (maxz - minz)
		end
		return minx, miny, minz, maxx, maxy, maxz
	end

	fit(tree.root_index)
	tree:finalize_boxes()
	tree.mesh_timestamp = self.hitMesh:ShapeTimestamp()
end

-- Strokes -------------------------------------------------------------------

function SculptMesh:beginStroke()
	self._strokeId += 1
	self._touchedCount = 0
end

-- Records that vertex v moved: it joins the stroke's undo record and the
-- list of positions to push to the preview.
function SculptMesh:moved(v: number)
	local i = v + 1
	if self._touchMark[i] ~= self._strokeId then
		self._touchMark[i] = self._strokeId
		local n = self._touchedCount + 1
		self._touchedCount = n
		self._touched[n] = v
	end
	if self._dirtyMark[i] ~= self._flushId then
		self._dirtyMark[i] = self._flushId
		local n = self._dirtyCount + 1
		self._dirtyCount = n
		self._dirty[n] = v
	end
end

-- The vertices moved since the last call (array, count). The array is
-- reused by the next call.
function SculptMesh:takeDirty(): ({ number }, number)
	local list, count = self._dirty, self._dirtyCount
	self._dirty = {}
	self._dirtyCount = 0
	self._flushId += 1
	return list, count
end

-- Ends the stroke: returns its undo record (nil if nothing moved) and the
-- moved vertices, and makes the current positions the new stroke-start
-- surface (the caller refits the tree).
function SculptMesh:endStroke(): (Record?, { number }, number)
	local pos, hp = self.pos, self.hitPos
	local record = {}
	local moved, count = {}, 0
	for i = 1, self._touchedCount do
		local v = self._touched[i]
		local p = 3 * v
		local dx, dy, dz = pos[p + 1] - hp[p + 1], pos[p + 2] - hp[p + 2], pos[p + 3] - hp[p + 3]
		if dx ~= 0 or dy ~= 0 or dz ~= 0 then
			local r = #record
			record[r + 1], record[r + 2], record[r + 3], record[r + 4] = v, dx, dy, dz
			hp[p + 1], hp[p + 2], hp[p + 3] = pos[p + 1], pos[p + 2], pos[p + 3]
			count += 1
			moved[count] = v
		end
	end
	self._touchedCount = 0
	return if count > 0 then record else nil, moved, count
end

-- Applies a record forward (sign 1) or backward (sign -1) to both the
-- current and the stroke-start positions. Returns the vertices it moved.
function SculptMesh:applyRecord(record: Record, sign: number): ({ number }, number)
	local pos, hp = self.pos, self.hitPos
	local moved, count = {}, 0
	for r = 1, #record, 4 do
		local v = record[r]
		local p = 3 * v
		local x = pos[p + 1] + sign * record[r + 1]
		local y = pos[p + 2] + sign * record[r + 2]
		local z = pos[p + 3] + sign * record[r + 3]
		pos[p + 1], pos[p + 2], pos[p + 3] = x, y, z
		hp[p + 1], hp[p + 2], hp[p + 3] = x, y, z
		count += 1
		moved[count] = v
	end
	return moved, count
end

-- A record that takes every vertex back to its original position (nil if
-- nothing has moved).
function SculptMesh:resetRecord(): Record?
	local pos, orig = self.pos, self.origPos
	local record = {}
	for v = 0, self.maxVertex - 1 do
		local p = 3 * v
		local dx, dy, dz = orig[p + 1] - pos[p + 1], orig[p + 2] - pos[p + 2], orig[p + 3] - pos[p + 3]
		if dx ~= 0 or dy ~= 0 or dz ~= 0 then
			local r = #record
			record[r + 1], record[r + 2], record[r + 3], record[r + 4] = v, dx, dy, dz
		end
	end
	return if #record > 0 then record else nil
end

return SculptMesh
