--[[
	MeshPartUpdate: gives a MeshPart a new mesh in place, so that the new
	geometry shows exactly where it was made. Used by Sculpt and Remesh.

	A MeshPart shows its mesh centered on the mesh's bounds and scaled by
	s = Size / MeshSize (scaleOf), so a mesh vertex m is at s * (m - c)
	relative to the part's CFrame. A tool that edits the geometry in that
	part-local space writes the new mesh in mesh units (local / s), with its
	bounds center `center` subtracted (or not: pass 0 if the mesh is written
	as is and is already centered). apply() then gives the part the mesh
	(MeshPart:ApplyMesh), with Size = s * size and CFrame = CFrame * (s *
	center). The pivot, the part's attachments and its joints' C0/C1 are
	re-expressed in the new frame so nothing else moves; joints and weld
	constraints are switched off while the part moves, or moving it would
	drag what it's welded to.
]]

local MeshPartUpdate = {}

-- The part's scale: Size / MeshSize (1 on axes where the mesh is flat).
function MeshPartUpdate.scaleOf(part: MeshPart): Vector3
	local size, meshSize = part.Size, part.MeshSize
	return Vector3.new(
		if meshSize.X > 1e-6 then size.X / meshSize.X else 1,
		if meshSize.Y > 1e-6 then size.Y / meshSize.Y else 1,
		if meshSize.Z > 1e-6 then size.Z / meshSize.Z else 1
	)
end

local function isJoint(instance: Instance): boolean
	return instance:IsA("JointInstance") or instance:IsA("WeldConstraint")
end

-- The joints and weld constraints connected to the part, including
-- disabled ones (GetJoints only returns active ones).
local function jointsOf(part: BasePart): { any }
	local found: { [Instance]: boolean } = {}
	local list = {}
	local function add(joint: any)
		if not found[joint] and isJoint(joint) and (joint.Part0 == part or joint.Part1 == part) then
			found[joint] = true
			table.insert(list, joint)
		end
	end
	for _, joint in part:GetJoints() do
		add(joint)
	end
	local root: Instance = part
	while root.Parent and root.Parent ~= game do
		root = root.Parent
	end
	for _, instance in root:GetDescendants() do
		if isJoint(instance) then
			add(instance)
		end
	end
	return list
end

-- Gives the part the mesh of `built` (a MeshPart made from the new mesh),
-- whose bounds have this center (subtracted when the mesh was written) and
-- size, in mesh units. Uses the part's current scale, so if the part was
-- resized meanwhile the mesh follows. Call inside an undo recording; doesn't
-- yield.
function MeshPartUpdate.apply(part: MeshPart, built: MeshPart, center: Vector3, size: Vector3)
	local scale = MeshPartUpdate.scaleOf(part)
	local offset = CFrame.new(scale * center)
	local inverse = offset:Inverse()

	local joints = jointsOf(part)
	local enabled = {}
	for i, joint in joints do
		enabled[i] = joint.Enabled
		joint.Enabled = false
	end

	part:ApplyMesh(built)
	part.Size = scale * size
	part.CFrame = part.CFrame * offset
	part.PivotOffset = inverse * part.PivotOffset
	for _, child in part:GetChildren() do
		if child:IsA("Attachment") then
			child.CFrame = inverse * child.CFrame
		end
	end

	for i, joint in joints do
		if joint:IsA("JointInstance") then
			if joint.Part0 == part then
				joint.C0 = inverse * joint.C0
			end
			if joint.Part1 == part then
				joint.C1 = inverse * joint.C1
			end
		end
		-- a weld constraint keeps the offset it finds when it's enabled again
		joint.Enabled = enabled[i]
	end
end

return MeshPartUpdate
