--[[
	MeshCodec: encodes an EditableMesh to a compact binary form and back, for
	local meshes (see LocalMeshes.luau).

	Everything the mesh has is kept: vertex positions, normals, UVs, colors
	(with alpha), and each face's vertices, normals, UVs and colors. Ids are
	stored as 1-based indexes into those lists (0 = none).

	Format (little endian), then zstd-compressed:
	  "LMSH", u32 version
	  u32 vertexCount, normalCount, uvCount, colorCount, faceCount
	  vertices  f32 x, y, z
	  normals   f32 x, y, z
	  uvs       f32 u, v
	  colors    f32 r, g, b, alpha
	  faces     u32 v1, v2, v3, n1, n2, n3, uv1, uv2, uv3, c1, c2, c3
]]

local AssetService = game:GetService("AssetService")
local EncodingService = game:GetService("EncodingService")

local MAGIC = "LMSH"
local VERSION = 1
local HEADER_BYTES = 8 + 5 * 4
local FACE_BYTES = 12 * 4

local MeshCodec = {}

local function indexOf(ids: { number }): { [number]: number }
	local index = {}
	for i, id in ids do
		index[id] = i
	end
	return index
end

-- Encodes the mesh; the result is compressed.
function MeshCodec.encode(editable: EditableMesh): buffer
	local vids, nids, uids, cids, fids = editable:GetVertices(), editable:GetNormals(), editable:GetUVs(), editable:GetColors(), editable:GetFaces()
	local nv, nn, nu, nc, nf = #vids, #nids, #uids, #cids, #fids
	local b = buffer.create(HEADER_BYTES + nv * 12 + nn * 12 + nu * 8 + nc * 16 + nf * FACE_BYTES)
	buffer.writestring(b, 0, MAGIC)
	buffer.writeu32(b, 4, VERSION)
	buffer.writeu32(b, 8, nv)
	buffer.writeu32(b, 12, nn)
	buffer.writeu32(b, 16, nu)
	buffer.writeu32(b, 20, nc)
	buffer.writeu32(b, 24, nf)
	local o = HEADER_BYTES

	for _, id in vids do
		local p = editable:GetPosition(id)
		buffer.writef32(b, o, p.X)
		buffer.writef32(b, o + 4, p.Y)
		buffer.writef32(b, o + 8, p.Z)
		o += 12
	end
	for _, id in nids do
		local n = editable:GetNormal(id)
		buffer.writef32(b, o, n.X)
		buffer.writef32(b, o + 4, n.Y)
		buffer.writef32(b, o + 8, n.Z)
		o += 12
	end
	for _, id in uids do
		local uv = editable:GetUV(id)
		buffer.writef32(b, o, uv.X)
		buffer.writef32(b, o + 4, uv.Y)
		o += 8
	end
	for _, id in cids do
		local c = editable:GetColor(id)
		buffer.writef32(b, o, c.R)
		buffer.writef32(b, o + 4, c.G)
		buffer.writef32(b, o + 8, c.B)
		buffer.writef32(b, o + 12, editable:GetColorAlpha(id) or 1)
		o += 16
	end

	local vindex, nindex, uindex, cindex = indexOf(vids), indexOf(nids), indexOf(uids), indexOf(cids)
	local function writeIds(ids: { number }, index: { [number]: number }, at: number)
		for k = 1, 3 do
			local id = ids[k]
			buffer.writeu32(b, at + (k - 1) * 4, if id then index[id] or 0 else 0)
		end
	end
	for _, fid in fids do
		writeIds(editable:GetFaceVertices(fid), vindex, o)
		writeIds(editable:GetFaceNormals(fid), nindex, o + 12)
		writeIds(editable:GetFaceUVs(fid), uindex, o + 24)
		writeIds(editable:GetFaceColors(fid), cindex, o + 36)
		o += FACE_BYTES
	end

	return EncodingService:CompressBuffer(b, Enum.CompressionAlgorithm.Zstd, 3)
end

-- Decodes encode()'s output into a new EditableMesh. Errors on bad data.
-- Returns the mesh and the number of faces that couldn't be added.
function MeshCodec.decode(data: buffer): (EditableMesh, number)
	local b = EncodingService:DecompressBuffer(data, Enum.CompressionAlgorithm.Zstd)
	if buffer.len(b) < HEADER_BYTES or buffer.readstring(b, 0, 4) ~= MAGIC then
		error("not a local mesh")
	end
	local version = buffer.readu32(b, 4)
	if version ~= VERSION then
		error(string.format("unsupported local mesh version %d", version))
	end
	local nv, nn, nu, nc, nf = buffer.readu32(b, 8), buffer.readu32(b, 12), buffer.readu32(b, 16), buffer.readu32(b, 20), buffer.readu32(b, 24)
	if buffer.len(b) ~= HEADER_BYTES + nv * 12 + nn * 12 + nu * 8 + nc * 16 + nf * FACE_BYTES then
		error("local mesh data is truncated")
	end

	local editable = AssetService:CreateEditableMesh({})
	local ok, failed = pcall(function(): number
		local o = HEADER_BYTES
		local vids, nids, uids, cids = table.create(nv), table.create(nn), table.create(nu), table.create(nc)
		for i = 1, nv do
			vids[i] = editable:AddVertex(Vector3.new(buffer.readf32(b, o), buffer.readf32(b, o + 4), buffer.readf32(b, o + 8)))
			o += 12
		end
		for i = 1, nn do
			nids[i] = editable:AddNormal(Vector3.new(buffer.readf32(b, o), buffer.readf32(b, o + 4), buffer.readf32(b, o + 8)))
			o += 12
		end
		for i = 1, nu do
			uids[i] = editable:AddUV(Vector2.new(buffer.readf32(b, o), buffer.readf32(b, o + 4)))
			o += 8
		end
		for i = 1, nc do
			cids[i] = editable:AddColor(
				Color3.new(buffer.readf32(b, o), buffer.readf32(b, o + 4), buffer.readf32(b, o + 8)),
				buffer.readf32(b, o + 12)
			)
			o += 16
		end

		-- the three ids at `at`, or nil if the face has none
		local function readIds(ids: { number }, at: number): { number }?
			local a, c, d = buffer.readu32(b, at), buffer.readu32(b, at + 4), buffer.readu32(b, at + 8)
			if a == 0 or c == 0 or d == 0 then
				return nil
			end
			return { ids[a], ids[c], ids[d] }
		end
		local failedFaces = 0
		for _ = 1, nf do
			local corners = readIds(vids, o)
			local added, fid = false, nil
			if corners then
				added, fid = pcall(editable.AddTriangle, editable, corners[1], corners[2], corners[3])
			end
			if added and fid then
				local normals = readIds(nids, o + 12)
				if normals then
					editable:SetFaceNormals(fid, normals)
				end
				local uvs = readIds(uids, o + 24)
				if uvs then
					editable:SetFaceUVs(fid, uvs)
				end
				local colors = readIds(cids, o + 36)
				if colors then
					editable:SetFaceColors(fid, colors)
				end
			else
				failedFaces += 1
			end
			o += FACE_BYTES
		end
		-- AddTriangle creates default normals (and possibly UVs/colors) that the
		-- stored ones replaced
		editable:RemoveUnused()
		return failedFaces
	end)
	if not ok then
		editable:Destroy()
		error(failed, 0)
	end
	return editable, failed
end

-- Text-safe forms for JSON transport.
function MeshCodec.toBase64(data: buffer): string
	return buffer.tostring(EncodingService:Base64Encode(data))
end

function MeshCodec.fromBase64(text: string): buffer
	return EncodingService:Base64Decode(buffer.fromstring(text))
end

return MeshCodec
