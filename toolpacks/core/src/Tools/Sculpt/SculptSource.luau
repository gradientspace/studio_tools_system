--[[
	SculptSource: the sculpted MeshPart's own mesh, and writing the sculpt
	back into the part.

	load() makes an editable copy of the part's mesh
	(AssetService:CreateEditableMeshAsync, which also copies a mesh that is
	already an EditableMesh) and reads it into a SculptMesh in part-local
	space. A MeshPart shows its mesh centered on the mesh's bounds and scaled
	by s = Size / MeshSize, so a mesh vertex m is at s * (m - c) relative to
	the part's CFrame, c being the bounds center (0 for asset meshes).

	build() writes the sculpted positions into the copy and keeps everything
	else it has (UVs, colors, normal seams): each vertex takes the position
	of the sculpt vertex it was welded into, divided by s, and the mesh is
	recentered on its new bounds (center c', size S', in mesh units). Each
	normal is recomputed as the area-weighted average of the faces that use
	it, so hard edges stay hard. Then it makes a MeshPart from the copy.

	apply() gives the part that mesh in place, with Size = s * S' and
	CFrame = CFrame * (s * c'), so the mesh shows exactly where it was
	sculpted (Shared/MeshPartUpdate.luau).
]]

local AssetService = game:GetService("AssetService")

local MeshPartUpdate = require(script.Parent.Parent.Parent.Shared.MeshPartUpdate)
local SculptMesh = require(script.Parent.SculptMesh)

local SculptSource = {}
SculptSource.__index = SculptSource

-- Loads the part's mesh and the SculptMesh made from it (self.sm). Yields;
-- errors if the mesh can't be loaded or has no triangles.
function SculptSource.load(part: MeshPart)
	local editable = AssetService:CreateEditableMeshAsync(part.MeshContent)
	local ok, result = pcall(function()
		local self = setmetatable({}, SculptSource)
		self.part = part
		self.editable = editable
		self.applied = false
		self.scale = MeshPartUpdate.scaleOf(part)
		local center = editable:GetCenter()

		-- the original positions, relative to the bounds center, for vertices
		-- the sculpt doesn't cover
		local vids = editable:GetVertices()
		local positions = table.create(#vids * 3)
		for i, vid in vids do
			local p = editable:GetPosition(vid) - center
			positions[3 * i - 2], positions[3 * i - 1], positions[3 * i] = p.X, p.Y, p.Z
		end
		self.vids = vids
		self.positions = positions

		self.sm = SculptMesh.fromEditable(editable, self.scale, center)
		return self
	end)
	if not ok then
		editable:Destroy()
		error(result, 0)
	end
	return result
end

-- Writes the sculpt into the editable copy and makes a MeshPart from it
-- (unparented) for apply(). Yields.
function SculptSource:build(): MeshPart
	local editable: EditableMesh = self.editable
	local sm = self.sm
	local pos, map, orig = sm.pos, sm.vertexMap, self.positions
	local sx, sy, sz = self.scale.X, self.scale.Y, self.scale.Z

	local vids = self.vids
	local xs, ys, zs = table.create(#vids), table.create(#vids), table.create(#vids)
	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	for i, vid in vids do
		local v = map[vid]
		local x, y, z
		if v then
			local p = 3 * v
			x, y, z = pos[p + 1] / sx, pos[p + 2] / sy, pos[p + 3] / sz
		else
			x, y, z = orig[3 * i - 2], orig[3 * i - 1], orig[3 * i]
		end
		xs[i], ys[i], zs[i] = x, y, z
		minX, minY, minZ = math.min(minX, x), math.min(minY, y), math.min(minZ, z)
		maxX, maxY, maxZ = math.max(maxX, x), math.max(maxY, y), math.max(maxZ, z)
	end
	if #vids == 0 then
		error("the mesh has no vertices", 0)
	end
	local ox, oy, oz = (minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2
	self.newCenter = Vector3.new(ox, oy, oz)
	self.newSize = Vector3.new(maxX - minX, maxY - minY, maxZ - minZ)

	local index = {} -- vertex id -> i
	for i, vid in vids do
		local x, y, z = xs[i] - ox, ys[i] - oy, zs[i] - oz
		xs[i], ys[i], zs[i] = x, y, z
		index[vid] = i
		editable:SetPosition(vid, Vector3.new(x, y, z))
	end

	-- area-weighted face normals, summed into the normals each face uses
	local sums: { [number]: { number } } = {}
	for _, fid in editable:GetFaces() do
		local nids = editable:GetFaceNormals(fid)
		if nids and #nids == 3 then
			local fv = editable:GetFaceVertices(fid)
			local a, b, c = index[fv[1]], index[fv[2]], index[fv[3]]
			if a and b and c then
				local ax, ay, az = xs[a], ys[a], zs[a]
				local e1x, e1y, e1z = xs[b] - ax, ys[b] - ay, zs[b] - az
				local e2x, e2y, e2z = xs[c] - ax, ys[c] - ay, zs[c] - az
				local nx, ny, nz = e1y * e2z - e1z * e2y, e1z * e2x - e1x * e2z, e1x * e2y - e1y * e2x
				for k = 1, 3 do
					local nid = nids[k]
					-- a face using one normal for all corners (flat shading) counts once
					if nid and (k == 1 or nid ~= nids[1]) and (k < 3 or nid ~= nids[2]) then
						local sum = sums[nid]
						if sum then
							sum[1] += nx
							sum[2] += ny
							sum[3] += nz
						else
							sums[nid] = { nx, ny, nz }
						end
					end
				end
			end
		end
	end
	for nid, sum in sums do
		local len = math.sqrt(sum[1] * sum[1] + sum[2] * sum[2] + sum[3] * sum[3])
		if len > 1e-20 then
			editable:SetNormal(nid, Vector3.new(sum[1] / len, sum[2] / len, sum[3] / len))
		end
	end

	local part: MeshPart = self.part
	return AssetService:CreateMeshPartAsync(Content.fromObject(editable), {
		CollisionFidelity = part.CollisionFidelity,
		RenderFidelity = part.RenderFidelity,
	})
end

-- Gives the part the mesh from build(), keeping it where it was sculpted.
-- Call inside an undo recording; doesn't yield.
function SculptSource:apply(built: MeshPart)
	MeshPartUpdate.apply(self.part, built, self.newCenter, self.newSize)
	self.applied = true
end

-- Frees the editable copy, unless the part now shows it.
function SculptSource:destroy()
	if not self.applied and self.editable then
		self.editable:Destroy()
	end
	self.editable = nil
end

return SculptSource
