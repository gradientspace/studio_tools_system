--[[
	RemeshJob: the computation behind the Remesh tool, with geometry3luau.

	load() reads an editable copy of the part's mesh into a DMesh3 in
	part-local space (studs, with the part's scale; see
	Shared/MeshPartUpdate.luau), welding vertices that are split at UV and
	normal seams so the seams don't become holes. UVs, normals and colors
	aren't read: remeshing makes new triangles, so the old UVs don't carry
	over.

	run() remeshes a copy of it toward a triangle count. Isotropic remeshing
	(Remesher: split, flip, collapse, smooth, project back onto the original
	surface) works from an edge length, so the target edge length comes from
	the area: an equilateral triangle with edge L covers (sqrt(3)/4) L^2, so
	N triangles over area A need L = sqrt(4 A / (sqrt(3) N)). That only gets
	close to N, so if the count is off by more than 5% after the passes, L
	is scaled by sqrt(count / N) and a few more passes run (twice at most).
	If the result has more than MAX_TRIANGLES (the EditableMesh limit used
	here), Reducer simplifies it down to that. Boundary loops of
	open meshes are kept on their original curves. The result is written to
	a new EditableMesh in mesh units, centered on its bounds, with smooth
	(area-weighted) normals.

	run() yields regularly (ProgressCancel.Yielding), so it neither freezes
	Studio nor hits the script timeout, and stops when isCancelled() says so.
]]

local AssetService = game:GetService("AssetService")

local Libraries = script:FindFirstAncestor("StudioTools").Libraries
local DMesh3 = require(Libraries.geometry3luau.DMesh3)
local MeshConstraintUtil = require(Libraries.geometry3luau.MeshConstraintUtil)
local MeshProjectionTarget = require(Libraries.geometry3luau.MeshProjectionTarget)
local ProgressCancel = require(Libraries.geometry3luau.ProgressCancel)
local Reducer = require(Libraries.geometry3luau.Reducer)
local Remesher = require(Libraries.geometry3luau.Remesher)
local RobloxMesh = require(Libraries.geometry3luau.RobloxMesh)

local MeshPartUpdate = require(script.Parent.Parent.Parent.Shared.MeshPartUpdate)

local MAX_TRIANGLES = 20000
local MAX_VERTICES = 60000
local YIELD_INTERVAL = 0.05 -- seconds of work between yields
-- correcting the edge length when the count is off by more than the tolerance
local CORRECTION_ROUNDS = 2
local CORRECTION_PASSES = 5
local CORRECTION_TOLERANCE = 0.05

local RemeshJob = {}
RemeshJob.MAX_TRIANGLES = MAX_TRIANGLES

export type Source = {
	mesh: any, -- DMesh3, part-local
	target: any, -- MeshProjectionTarget onto `mesh`
	area: number,
	scale: Vector3,
	failedTriangles: number, -- non-manifold triangles skipped when reading
}

export type Result = {
	editable: EditableMesh, -- mesh units, centered
	center: Vector3, -- subtracted from the positions (mesh units)
	size: Vector3, -- bounds size (mesh units)
	triangles: number,
	vertices: number,
	remeshedTriangles: number, -- before simplifying
	lines: { Vector3 }, -- edge endpoints in pairs, relative to a part showing `editable` at the source's scale
}

-- Reads the part's mesh. Yields; errors if it can't be loaded or has no
-- triangles.
function RemeshJob.load(part: MeshPart): Source
	local editable = AssetService:CreateEditableMeshAsync(part.MeshContent)
	local ok, result = pcall(function(): Source
		local scale = MeshPartUpdate.scaleOf(part)
		local sx, sy, sz = scale.X, scale.Y, scale.Z
		local center = editable:GetCenter()
		local cx, cy, cz = center.X, center.Y, center.Z
		local mesh, info = RobloxMesh.FromEditableMesh(editable, {
			weld = "positions",
			normals = "none",
			uvs = "none",
			transform = function(x: number, y: number, z: number): (number, number, number)
				return (x - cx) * sx, (y - cy) * sy, (z - cz) * sz
			end,
		})
		if mesh:TriangleCount() == 0 then
			error("the mesh has no triangles", 0)
		end
		local area = 0
		for tid in mesh:TriangleIndices() do
			area += mesh:GetTriArea(tid)
		end
		return {
			mesh = mesh,
			target = MeshProjectionTarget.new(mesh),
			area = area,
			scale = scale,
			failedTriangles = info and info.failed or 0,
		}
	end)
	editable:Destroy()
	if not ok then
		error(result, 0)
	end
	return result
end

-- The edge length that gives about `count` equilateral triangles over `area`.
function RemeshJob.edgeLength(area: number, count: number): number
	return math.sqrt(4 * area / (math.sqrt(3) * math.max(count, 1)))
end

-- Remeshes a copy of the source toward `targetCount` triangles, in `passes`
-- passes. Yields; returns nil if cancelled.
function RemeshJob.run(source: Source, targetCount: number, passes: number, onStatus: (string) -> (), isCancelled: () -> boolean): Result?
	local mesh = DMesh3.FromCopy(source.mesh, true, false, false, false)
	local progress = ProgressCancel.Yielding(YIELD_INTERVAL, isCancelled)

	local edgeLength = RemeshJob.edgeLength(source.area, targetCount)
	local remesher = Remesher.new(mesh)
	remesher:SetTargetEdgeLength(edgeLength)
	remesher:SetProjectionTarget(source.target)
	remesher.SmoothSpeedT = 0.5
	remesher.Progress = progress
	MeshConstraintUtil.PreserveBoundaryLoops(remesher, mesh)
	remesher:Precompute()
	for pass = 1, passes do
		onStatus(string.format("Remeshing: pass %d of %d (%d triangles)", pass, passes, mesh:TriangleCount()))
		remesher:BasicRemeshPass()
		if progress:Cancelled() then
			return nil
		end
	end

	-- The edge length only gets near the count (edges settle anywhere in a
	-- band around it): scale it by how far off the count is, and refine.
	for round = 1, CORRECTION_ROUNDS do
		local ratio = mesh:TriangleCount() / targetCount
		if math.abs(ratio - 1) <= CORRECTION_TOLERANCE then
			break
		end
		edgeLength *= math.sqrt(ratio)
		remesher:SetTargetEdgeLength(edgeLength)
		for pass = 1, CORRECTION_PASSES do
			onStatus(string.format("Adjusting the triangle count (%d of %d): %d triangles", round, CORRECTION_ROUNDS, mesh:TriangleCount()))
			remesher:BasicRemeshPass()
			if progress:Cancelled() then
				return nil
			end
		end
	end
	local remeshed = mesh:TriangleCount()

	if remeshed > MAX_TRIANGLES then
		onStatus(string.format("Simplifying %d triangles to %d...", remeshed, MAX_TRIANGLES))
		local reducer = Reducer.new(mesh)
		reducer:SetProjectionTarget(source.target)
		reducer.Progress = progress
		reducer:ReduceToTriangleCount(MAX_TRIANGLES)
		if progress:Cancelled() then
			return nil
		end
	end

	-- part-local to mesh units
	local sx, sy, sz = source.scale.X, source.scale.Y, source.scale.Z
	local pos = mesh.vertices.data
	for vid in mesh:VertexIndices() do
		local p = 3 * vid
		pos[p + 1], pos[p + 2], pos[p + 3] = pos[p + 1] / sx, pos[p + 2] / sy, pos[p + 3] / sz
	end
	local bounds = mesh:GetBounds()
	local center = Vector3.new((bounds.Min.x + bounds.Max.x) / 2, (bounds.Min.y + bounds.Max.y) / 2, (bounds.Min.z + bounds.Max.z) / 2)
	local size = Vector3.new(bounds.Max.x - bounds.Min.x, bounds.Max.y - bounds.Min.y, bounds.Max.z - bounds.Min.z)

	onStatus("Building the mesh...")
	local editable = RobloxMesh.ToEditableMesh(mesh, {
		center = true,
		normals = "computed",
		uvs = "none",
		colors = "none",
		maxTriangles = MAX_TRIANGLES,
		maxVertices = MAX_VERTICES,
	})

	-- wireframe lines, as a part showing this mesh at the source's scale sees them
	local lines = {}
	local cx, cy, cz = center.X, center.Y, center.Z
	for eid in mesh:EdgeIndices() do
		local ev = mesh:GetEdgeV(eid)
		for k = 1, 2 do
			local p = 3 * ev[k]
			table.insert(lines, Vector3.new((pos[p + 1] - cx) * sx, (pos[p + 2] - cy) * sy, (pos[p + 3] - cz) * sz))
		end
	end

	return {
		editable = editable,
		center = center,
		size = size,
		triangles = mesh:TriangleCount(),
		vertices = mesh:VertexCount(),
		remeshedTriangles = remeshed,
		lines = lines,
	}
end

return RemeshJob
