--[[
	BakeTarget: one MeshPart for Bake Transform. Loads an editable copy of
	the part's mesh, works out what baking does to it (plan), builds the
	baked mesh (build) and swaps a baked copy of the part into the place
	(apply).

	Coordinates. A MeshPart shows its mesh (mesh space, centered on the
	mesh's bounds) scaled by s = Size / MeshSize and placed at CFrame P, so a
	mesh vertex m is at P * (s * (m - c)) in the world, c being the mesh's
	bounds center (0 for meshes from assets). Baking picks a new rotation R'
	(identity when rotation is baked) and a residual scale s' (1 when scale is
	baked) for the new part, and rewrites the vertices as
	m' = (R'^T R (s * (m - c))) / s', recentered on their new bounds center c';
	the new part is at P' = (P.Position, R') * (s' * c') with Size s' * size(m').
	The geometry stays exactly where it was in the world. Normals use the
	inverse transpose: n' = normalize(s' * (R'^T R (n / s))).

	Rotation and non-uniform scale don't commute, so a part whose rotation is
	baked has its scale baked too unless the scale is uniform.
]]

local AssetService = game:GetService("AssetService")

local EPSILON = 1e-5

local BakeTarget = {}
BakeTarget.__index = BakeTarget

export type Options = {
	bakeRotation: boolean,
	bakeScale: boolean,
	pivot: string, -- "Unchanged" | "Center" | "Base"
}

export type Plan = {
	-- the part as the plan saw it; apply() skips the part if it changed since
	cframe0: CFrame,
	size0: Vector3,
	pivot0: CFrame,
	meshChanged: boolean, -- the mesh is rewritten (otherwise only the pivot may change)
	pivotChanged: boolean,
	scaleForced: boolean, -- non-uniform scale baked because the rotation is
	-- the new part
	cframe: CFrame,
	size: Vector3,
	pivotOffset: CFrame,
	-- mesh rewrite: m' = L * (m - c) - center, n' = normalize(N * n)
	L: { number },
	N: { number },
	c: Vector3,
	center: Vector3,
}

local function isIdentityRotation(cframe: CFrame): boolean
	local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cframe:GetComponents()
	return math.abs(r00 - 1) < EPSILON
		and math.abs(r11 - 1) < EPSILON
		and math.abs(r22 - 1) < EPSILON
		and math.abs(r01) < EPSILON
		and math.abs(r02) < EPSILON
		and math.abs(r10) < EPSILON
		and math.abs(r12) < EPSILON
		and math.abs(r20) < EPSILON
		and math.abs(r21) < EPSILON
end

local function nearlyEqual(a: Vector3, b: Vector3, tolerance: number): boolean
	return math.abs(a.X - b.X) <= tolerance and math.abs(a.Y - b.Y) <= tolerance and math.abs(a.Z - b.Z) <= tolerance
end

local function sameCFrame(a: CFrame, b: CFrame): boolean
	local ac, bc = { a:GetComponents() }, { b:GetComponents() }
	for i = 1, 12 do
		if math.abs(ac[i] - bc[i]) > EPSILON then
			return false
		end
	end
	return true
end

-- Loads the part's mesh into an editable copy. Yields; errors if the mesh
-- can't be loaded (e.g. an asset the user has no permission to edit).
function BakeTarget.load(part: MeshPart)
	local editable = AssetService:CreateEditableMeshAsync(part.MeshContent)
	local self = setmetatable({}, BakeTarget)
	self.part = part
	self.editable = editable

	local vids = editable:GetVertices()
	local positions = table.create(#vids * 3)
	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	for i, vid in vids do
		local p = editable:GetPosition(vid)
		local x, y, z = p.X, p.Y, p.Z
		positions[3 * i - 2], positions[3 * i - 1], positions[3 * i] = x, y, z
		minX, minY, minZ = math.min(minX, x), math.min(minY, y), math.min(minZ, z)
		maxX, maxY, maxZ = math.max(maxX, x), math.max(maxY, y), math.max(maxZ, z)
	end
	if #vids == 0 then
		editable:Destroy()
		error("the mesh has no vertices")
	end
	self.vids = vids
	self.positions = positions
	self.meshCenter = Vector3.new((minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2)

	local nids = editable:GetNormals()
	local normals = table.create(#nids * 3)
	for i, nid in nids do
		local n = editable:GetNormal(nid)
		normals[3 * i - 2], normals[3 * i - 1], normals[3 * i] = n.X, n.Y, n.Z
	end
	self.nids = nids
	self.normals = normals
	return self
end

function BakeTarget:vertexCount(): number
	return #self.vids
end

-- What baking with these options does to the part as it is now.
function BakeTarget:plan(options: Options): Plan
	local part: MeshPart = self.part
	local P, size0, O = part.CFrame, part.Size, part.PivotOffset
	local meshSize = part.MeshSize
	local s = Vector3.new(
		if meshSize.X > 1e-6 then size0.X / meshSize.X else 1,
		if meshSize.Y > 1e-6 then size0.Y / meshSize.Y else 1,
		if meshSize.Z > 1e-6 then size0.Z / meshSize.Z else 1
	)

	local R = P.Rotation
	local rotate = options.bakeRotation and not isIdentityRotation(R)
	local newRotation = if rotate then CFrame.identity else R
	local uniform = math.max(s.X, s.Y, s.Z) - math.min(s.X, s.Y, s.Z) <= EPSILON * math.max(s.X, s.Y, s.Z)
	local scaleForced = rotate and not options.bakeScale and not uniform
	local residual: Vector3
	if options.bakeScale or scaleForced then
		residual = Vector3.one
	elseif rotate then
		local average = (s.X + s.Y + s.Z) / 3
		residual = Vector3.new(average, average, average)
	else
		residual = s
	end
	local meshChanged = rotate or not nearlyEqual(residual, s, EPSILON * math.max(s.X, s.Y, s.Z, 1))

	-- L = diag(1/s') rel diag(s), N = diag(s') rel diag(1/s), rel = R'^T R
	local rel = newRotation:Inverse() * R
	local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = rel:GetComponents()
	local r = { r00, r01, r02, r10, r11, r12, r20, r21, r22 }
	local sv, rv = { s.X, s.Y, s.Z }, { residual.X, residual.Y, residual.Z }
	local L, N = table.create(9), table.create(9)
	for i = 1, 3 do
		for j = 1, 3 do
			local k = 3 * (i - 1) + j
			L[k] = r[k] * sv[j] / rv[i]
			N[k] = r[k] * rv[i] / sv[j]
		end
	end

	local newCFrame, newSize, center
	if meshChanged then
		local positions, c = self.positions, self.meshCenter
		local cx, cy, cz = c.X, c.Y, c.Z
		local l1, l2, l3, l4, l5, l6, l7, l8, l9 = table.unpack(L)
		local minX, minY, minZ = math.huge, math.huge, math.huge
		local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
		for i = 1, #positions, 3 do
			local x, y, z = positions[i] - cx, positions[i + 1] - cy, positions[i + 2] - cz
			local nx = l1 * x + l2 * y + l3 * z
			local ny = l4 * x + l5 * y + l6 * z
			local nz = l7 * x + l8 * y + l9 * z
			minX, minY, minZ = math.min(minX, nx), math.min(minY, ny), math.min(minZ, nz)
			maxX, maxY, maxZ = math.max(maxX, nx), math.max(maxY, ny), math.max(maxZ, nz)
		end
		center = Vector3.new((minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2)
		newSize = Vector3.new(maxX - minX, maxY - minY, maxZ - minZ) * residual
		newCFrame = CFrame.new(P.Position) * newRotation * CFrame.new(center * residual)
	else
		center = Vector3.zero
		newSize = size0
		newCFrame = P
	end

	local pivotOffset: CFrame
	if options.pivot == "Center" then
		pivotOffset = CFrame.identity
	elseif options.pivot == "Base" then
		pivotOffset = CFrame.new(0, -newSize.Y / 2, 0)
	else
		-- the pivot stays where it is in the world, keeping its rotation relative to the part
		pivotOffset = CFrame.new(newCFrame:PointToObjectSpace((P * O).Position)) * O.Rotation
	end

	return {
		cframe0 = P,
		size0 = size0,
		pivot0 = O,
		meshChanged = meshChanged,
		pivotChanged = not sameCFrame(pivotOffset, if meshChanged then (newCFrame:Inverse() * P * O) else O),
		scaleForced = scaleForced,
		cframe = newCFrame,
		size = newSize,
		pivotOffset = pivotOffset,
		L = L,
		N = N,
		c = self.meshCenter,
		center = center,
	}
end

-- Writes the planned mesh into the editable and makes a MeshPart from it
-- (unparented), for apply(). Yields.
function BakeTarget:build(plan: Plan): MeshPart
	local editable: EditableMesh = self.editable
	local positions, vids = self.positions, self.vids
	local l1, l2, l3, l4, l5, l6, l7, l8, l9 = table.unpack(plan.L)
	local cx, cy, cz = plan.c.X, plan.c.Y, plan.c.Z
	local ox, oy, oz = plan.center.X, plan.center.Y, plan.center.Z
	for i, vid in vids do
		local x, y, z = positions[3 * i - 2] - cx, positions[3 * i - 1] - cy, positions[3 * i] - cz
		editable:SetPosition(
			vid,
			Vector3.new(l1 * x + l2 * y + l3 * z - ox, l4 * x + l5 * y + l6 * z - oy, l7 * x + l8 * y + l9 * z - oz)
		)
	end
	local normals, nids = self.normals, self.nids
	local n1, n2, n3, n4, n5, n6, n7, n8, n9 = table.unpack(plan.N)
	for i, nid in nids do
		local x, y, z = normals[3 * i - 2], normals[3 * i - 1], normals[3 * i]
		local n = Vector3.new(n1 * x + n2 * y + n3 * z, n4 * x + n5 * y + n6 * z, n7 * x + n8 * y + n9 * z)
		if n.Magnitude > 1e-12 then
			editable:SetNormal(nid, n.Unit)
		end
	end
	local part: MeshPart = self.part
	return AssetService:CreateMeshPartAsync(Content.fromObject(editable), {
		CollisionFidelity = part.CollisionFidelity,
		RenderFidelity = part.RenderFidelity,
	})
end

-- Can apply() still use this plan?
function BakeTarget:isCurrent(plan: Plan): boolean
	local part: MeshPart = self.part
	return part.Parent ~= nil
		and sameCFrame(part.CFrame, plan.cframe0)
		and nearlyEqual(part.Size, plan.size0, EPSILON)
		and sameCFrame(part.PivotOffset, plan.pivot0)
end

-- Pairs each instance under `a` with its copy under `b` (b = a:Clone(),
-- which skips non-archivable instances).
local function pairCopies(a: Instance, b: Instance, map: { [Instance]: Instance })
	map[a] = b
	local originals = {}
	for _, child in a:GetChildren() do
		if child.Archivable then
			table.insert(originals, child)
		end
	end
	local copies = b:GetChildren()
	if #originals ~= #copies then
		return
	end
	for i, child in originals do
		if copies[i].ClassName == child.ClassName then
			pairCopies(child, copies[i], map)
		end
	end
end

-- Instance-reference properties that may point at the part or its children.
local REFERENCES: { { className: string, properties: { string } } } = {
	{ className = "JointInstance", properties = { "Part0", "Part1" } },
	{ className = "WeldConstraint", properties = { "Part0", "Part1" } },
	{ className = "NoCollisionConstraint", properties = { "Part0", "Part1" } },
	{ className = "Constraint", properties = { "Attachment0", "Attachment1" } },
	{ className = "Beam", properties = { "Attachment0", "Attachment1" } },
	{ className = "Trail", properties = { "Attachment0", "Attachment1" } },
	{ className = "ObjectValue", properties = { "Value" } },
	{ className = "Model", properties = { "PrimaryPart" } },
}

export type Swaps = {
	map: { [Instance]: Instance }, -- original part and descendants -> copies
	rel: { [Instance]: CFrame }, -- copy -> old part frame expressed in the new one
	roots: { [Instance]: boolean }, -- where to look for references
}

function BakeTarget.newSwaps(): Swaps
	return { map = {}, rel = {}, roots = {} }
end

-- Replaces the part with a copy that has the baked mesh (from build()), or,
-- when only the pivot changes, sets the pivot. Returns the part that's in
-- the place afterwards. Call BakeTarget.finishSwaps once all parts are
-- applied. Call inside an undo recording; doesn't yield.
function BakeTarget:apply(plan: Plan, built: MeshPart?, swaps: Swaps): MeshPart
	local part: MeshPart = self.part
	if not plan.meshChanged then
		part.PivotOffset = plan.pivotOffset
		return part
	end
	assert(built, "BakeTarget:apply: the baked mesh wasn't built")

	local archivable = part.Archivable
	part.Archivable = true
	local copy = part:Clone() :: MeshPart
	part.Archivable = archivable
	copy.Archivable = archivable

	copy:ApplyMesh(built)
	copy.Size = plan.size
	copy.CFrame = plan.cframe
	copy.PivotOffset = plan.pivotOffset

	-- offsets relative to the part (attachments, joint C0/C1) are re-expressed
	-- in the new part's frame so nothing attached to it moves
	local rel = plan.cframe:Inverse() * plan.cframe0
	for _, child in copy:GetChildren() do
		if child:IsA("Attachment") then
			child.CFrame = rel * child.CFrame
		end
	end
	pairCopies(part, copy, swaps.map)
	swaps.rel[copy] = rel
	local root: Instance = part
	while root.Parent and root.Parent ~= game do
		root = root.Parent
	end
	swaps.roots[root] = true

	copy.Parent = part.Parent
	part.Parent = nil
	self.applied = true
	return copy
end

-- Points references to the replaced parts (and their children) at the
-- copies: joints, constraints, beams, ObjectValues, Model.PrimaryPart. One
-- pass over the place for all parts.
function BakeTarget.finishSwaps(swaps: Swaps)
	local map, rel = swaps.map, swaps.rel
	if next(rel) == nil then
		return
	end
	for root in swaps.roots do
		for _, instance in root:GetDescendants() do
			for _, entry in REFERENCES do
				if instance:IsA(entry.className) then
					for _, property in entry.properties do
						local value = (instance :: any)[property]
						local copy = value and map[value]
						if copy then
							(instance :: any)[property] = copy
						end
					end
				end
			end
			-- includes joints inside a copy, which Clone() already pointed at it
			if instance:IsA("JointInstance") then
				local joint = instance :: JointInstance
				local rel0 = joint.Part0 and rel[joint.Part0]
				if rel0 then
					joint.C0 = rel0 * joint.C0
				end
				local rel1 = joint.Part1 and rel[joint.Part1]
				if rel1 then
					joint.C1 = rel1 * joint.C1
				end
			end
		end
	end
end

-- Frees the editable copy, unless an applied part shows it.
function BakeTarget:destroy()
	if not self.applied and self.editable then
		self.editable:Destroy()
	end
	self.editable = nil
end

return BakeTarget
