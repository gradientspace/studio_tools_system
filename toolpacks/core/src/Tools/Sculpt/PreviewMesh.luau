--[[
	PreviewMesh: shows a SculptMesh in the viewport through an EditableMesh
	and a MeshPart made from it, placed exactly where the source MeshPart is.

	The EditableMesh has one vertex per SculptMesh vertex, at the local
	position minus the mesh's starting bounds center (the MeshPart's pivot is
	the center of its mesh, so the part goes at source.CFrame * center).
	Moving a vertex later doesn't rescale the part: it renders the vertex
	where it is.

	Display modes:
	  Textured     the source's material, color, texture, SurfaceAppearance
	               and UVs, with smooth (vertex) normals
	  Untextured   plain "clay" material, smooth normals
	  Flat shaded  plain clay material, one normal per triangle

	Normals are only written when asked (updateNormals), which the tool does
	at the end of a stroke; during a stroke only positions change.
]]

local AssetService = game:GetService("AssetService")

local PreviewMesh = {}
PreviewMesh.__index = PreviewMesh

export type DisplayMode = "Textured" | "Untextured" | "Flat shaded"

-- Builds the preview. Yields (the engine creates the MeshPart). `own` takes
-- objects to destroy when the tool deactivates (ctx:addCleanup).
function PreviewMesh.new(sm: any, source: MeshPart, parent: Instance, mode: string, clayColor: Color3, own: (any) -> ())
	local self = setmetatable({}, PreviewMesh)
	self.sm = sm
	self.source = source
	self.offset = sm.center
	self.mode = mode
	self.clayColor = clayColor

	local editable = AssetService:CreateEditableMesh({})
	if not editable then
		error("couldn't create an EditableMesh", 0)
	end
	own(editable)
	self.editable = editable

	local mesh, pos, tris = sm.mesh, sm.pos, sm.tris
	local ox, oy, oz = self.offset.X, self.offset.Y, self.offset.Z

	local evid = table.create(sm.maxVertex) -- sculpt vertex + 1 -> editable vertex id
	for v = 0, sm.maxVertex - 1 do
		if mesh:IsVertex(v) and #sm.vtris[v + 1] > 0 then
			local p = 3 * v
			evid[v + 1] = editable:AddVertex(Vector3.new(pos[p + 1] - ox, pos[p + 2] - oy, pos[p + 3] - oz))
		end
	end
	self.evid = evid

	local fids = table.create(sm.maxTriangle) -- triangle + 1 -> face id
	for t = 0, sm.maxTriangle - 1 do
		if mesh:IsTriangle(t) then
			local k = 3 * t
			fids[t + 1] = editable:AddTriangle(evid[tris[k + 1] + 1], evid[tris[k + 2] + 1], evid[tris[k + 3] + 1])
		end
	end
	self.fids = fids

	-- UVs, shared per vertex where the corners agree.
	local attribs = if mesh:HasAttributes() then mesh:Attribs() else nil
	self.hasUVs = attribs ~= nil and attribs:HasTriUVChannel(0)
	if self.hasUVs then
		local channel = attribs:TriUVChannel(0)
		local perVertex = {} -- vertex -> { { u, v, id } }
		local function uvId(v: number, uv: any): number
			local list = perVertex[v]
			if not list then
				list = {}
				perVertex[v] = list
			end
			for _, entry in list do
				if entry[1] == uv.x and entry[2] == uv.y then
					return entry[3]
				end
			end
			local id = editable:AddUV(Vector2.new(uv.x, uv.y))
			table.insert(list, { uv.x, uv.y, id })
			return id
		end
		for t = 0, sm.maxTriangle - 1 do
			local fid = fids[t + 1]
			if fid then
				local uvs = channel:GetValue(t)
				local k = 3 * t
				editable:SetFaceUVs(fid, {
					uvId(tris[k + 1], uvs.A),
					uvId(tris[k + 2], uvs.B),
					uvId(tris[k + 3], uvs.C),
				})
			end
		end
	end

	self:_buildNormals()

	local part = AssetService:CreateMeshPartAsync(Content.fromObject(editable), {
		CollisionFidelity = Enum.CollisionFidelity.Box,
		RenderFidelity = Enum.RenderFidelity.Precise,
	})
	own(part)
	part.Name = source.Name .. " (Sculpt)"
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = source.CastShadow
	self.part = part

	local surfaceAppearance = source:FindFirstChildWhichIsA("SurfaceAppearance")
	if surfaceAppearance then
		local ok, clone = pcall(surfaceAppearance.Clone, surfaceAppearance)
		if ok and clone then
			own(clone)
			self.surfaceAppearance = clone
		end
	end

	self:_applyAppearance()
	self:updatePlacement()
	part.Parent = parent
	return self
end

-- Puts the part where the source part is (call again if the source moves).
function PreviewMesh:updatePlacement()
	self.part.CFrame = self.source.CFrame * CFrame.new(self.offset)
end

local function isFlat(mode: string): boolean
	return mode == "Flat shaded"
end

-- Creates normals for the current mode, assigns them to every face and
-- drops the old ones.
function PreviewMesh:_buildNormals()
	local editable, sm, fids = self.editable, self.sm, self.fids
	local tris, nrm = sm.tris, sm.nrm
	if isFlat(self.mode) then
		local fnid = table.create(sm.maxTriangle)
		for t = 0, sm.maxTriangle - 1 do
			local fid = fids[t + 1]
			if fid then
				local id = editable:AddNormal(Vector3.new(sm:triangleNormal(t)))
				fnid[t + 1] = id
				editable:SetFaceNormals(fid, { id, id, id })
			end
		end
		self.fnid, self.vnid = fnid, nil
	else
		local vnid = table.create(sm.maxVertex)
		for v = 0, sm.maxVertex - 1 do
			if self.evid[v + 1] then
				local p = 3 * v
				vnid[v + 1] = editable:AddNormal(Vector3.new(nrm[p + 1], nrm[p + 2], nrm[p + 3]))
			end
		end
		for t = 0, sm.maxTriangle - 1 do
			local fid = fids[t + 1]
			if fid then
				local k = 3 * t
				editable:SetFaceNormals(fid, { vnid[tris[k + 1] + 1], vnid[tris[k + 2] + 1], vnid[tris[k + 3] + 1] })
			end
		end
		self.vnid, self.fnid = vnid, nil
	end
	editable:RemoveUnused()
end

function PreviewMesh:_applyAppearance()
	local part, source = self.part, self.source
	local textured = self.mode == "Textured"
	if textured then
		part.Material = source.Material
		part.MaterialVariant = source.MaterialVariant
		part.Color = source.Color
		part.Reflectance = source.Reflectance
		if not pcall(function()
			part.TextureContent = source.TextureContent
		end) then
			part.TextureID = source.TextureID
		end
	else
		part.Material = Enum.Material.SmoothPlastic
		part.MaterialVariant = ""
		part.Color = self.clayColor
		part.Reflectance = 0
		if not pcall(function()
			part.TextureContent = Content.none
		end) then
			part.TextureID = ""
		end
	end
	if self.surfaceAppearance then
		self.surfaceAppearance.Parent = if textured then part else nil
	end
end

-- Switches the display mode and/or clay color.
function PreviewMesh:setDisplay(mode: string, clayColor: Color3)
	local rebuild = isFlat(mode) ~= isFlat(self.mode)
	self.mode = mode
	self.clayColor = clayColor
	if rebuild then
		self:_buildNormals()
	end
	self:_applyAppearance()
end

-- Pushes the current positions of these vertices to the EditableMesh.
function PreviewMesh:setPositions(vids: { number }, count: number)
	local editable, evid, pos = self.editable, self.evid, self.sm.pos
	local ox, oy, oz = self.offset.X, self.offset.Y, self.offset.Z
	for i = 1, count do
		local v = vids[i]
		local id = evid[v + 1]
		if id then
			local p = 3 * v
			editable:SetPosition(id, Vector3.new(pos[p + 1] - ox, pos[p + 2] - oy, pos[p + 3] - oz))
		end
	end
end

-- Writes new normals for a region: per-triangle normals for these
-- triangles in Flat shaded mode, else the SculptMesh's vertex normals for
-- these vertices (compute those first).
function PreviewMesh:updateNormals(tris: { number }, triCount: number, verts: { number }, vertCount: number)
	local editable, sm = self.editable, self.sm
	if self.fnid then
		local fnid = self.fnid
		for i = 1, triCount do
			local t = tris[i]
			local id = fnid[t + 1]
			if id then
				editable:SetNormal(id, Vector3.new(sm:triangleNormal(t)))
			end
		end
	elseif self.vnid then
		local vnid, nrm = self.vnid, sm.nrm
		for i = 1, vertCount do
			local v = verts[i]
			local id = vnid[v + 1]
			if id then
				local p = 3 * v
				editable:SetNormal(id, Vector3.new(nrm[p + 1], nrm[p + 2], nrm[p + 3]))
			end
		end
	end
end

return PreviewMesh
