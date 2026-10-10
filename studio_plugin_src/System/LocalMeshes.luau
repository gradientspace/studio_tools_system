--[[
	LocalMeshes: keeps EditableMesh-backed MeshParts across saves.

	Studio doesn't save EditableMesh content with the place: a MeshPart
	showing one is saved with an empty mesh. So when a tool makes such a part
	(ctx:saveLocalMesh), the part gets a mesh id (a UUID, in the attribute
	StudioToolsLocalMeshId, plus the CollectionService tag
	StudioToolsLocalMesh) and the mesh is uploaded to the dev server, which
	stores it per place (server/localmeshes.js). When the system starts (the
	place is opened, or a hot reload), and whenever a tagged part appears
	(pasted, inserted), tagged parts with an empty mesh are given their mesh
	back from the server.

	Ids and edits. Saving a part again under its id overwrites the stored
	mesh, as long as the id belongs to the same EditableMesh. A part whose id
	belongs to a different EditableMesh (a tool replaced the part with a copy,
	or the part was duplicated and then edited) gets a new id, so the
	original, which undo can bring back and which another part may still
	use, keeps its stored mesh. Duplicates of a part share its EditableMesh
	and its id until one of them is edited.

	Restoring sets each part's mesh with MeshPart:ApplyMesh, which undo
	tracks. It's done in its own undo recording ("Load local meshes"); when
	that's the only thing in the undo history (the place was just opened),
	the history is cleared so Ctrl+Z can't remove the meshes again.

	Uploads run in the background and outlive tools and hot reloads; a failed
	one is retried, then reported in the Output window.
]]

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local AssetService = game:GetService("AssetService")

local ServerApi = require(script.Parent.ServerApi)
local MeshCodec = require(script.Parent.MeshCodec)

local TAG = "StudioToolsLocalMesh"
local ATTRIBUTE = "StudioToolsLocalMeshId"
local ID_PATTERN = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"
local UPLOAD_ATTEMPTS = 3
-- An older dev server (started before local meshes existed) answers 404 "not found".
local OLD_SERVER = "the dev server needs a restart (npm start) for local meshes"
local RETRY_DELAY = 2

local LocalMeshes = {}
LocalMeshes.__index = LocalMeshes
LocalMeshes.TAG = TAG
LocalMeshes.ATTRIBUTE = ATTRIBUTE

local function isValidId(id: any): boolean
	return type(id) == "string" and string.match(id, ID_PATTERN) ~= nil
end

local function editableOf(part: MeshPart): EditableMesh?
	local content = part.MeshContent
	if content.SourceType == Enum.ContentSourceType.Object then
		local object = content.Object
		if object and object:IsA("EditableMesh") then
			return object :: EditableMesh
		end
	end
	return nil
end

-- A tagged part whose mesh is missing (an empty mesh after the place was
-- saved and opened again). A part with any other mesh, e.g. an asset
-- someone set by hand, is left alone.
local function needsRestore(part: Instance): boolean
	if not (part:IsA("MeshPart") and part.Parent ~= nil and isValidId(part:GetAttribute(ATTRIBUTE))) then
		return false
	end
	local content = (part :: MeshPart).MeshContent
	return content.SourceType == Enum.ContentSourceType.None
		or (content.SourceType == Enum.ContentSourceType.Uri and (content.Uri or "") == "")
end

function LocalMeshes.new(serverUrl: string)
	local self = setmetatable({}, LocalMeshes)
	self._serverUrl = serverUrl
	self._destroyed = false
	self._connections = {} :: { RBXScriptConnection }
	-- id -> the EditableMesh it belongs to (weak: forgotten with the mesh)
	self._owners = setmetatable({}, { __mode = "v" }) :: any
	self._restoring = {} :: { [Instance]: boolean }
	self._pendingAdded = nil :: { Instance }?
	self._uploads = {} :: { [string]: { editable: EditableMesh, meta: any } }
	self._uploading = false
	return self
end

-- Claims the ids of parts that already show their mesh (after a hot reload),
-- restores the parts missing theirs, and watches for tagged parts appearing.
function LocalMeshes:start()
	local missing = {}
	for _, part in CollectionService:GetTagged(TAG) do
		if part:IsA("MeshPart") then
			local id = part:GetAttribute(ATTRIBUTE)
			local editable = editableOf(part)
			if isValidId(id) and editable and not self._owners[id] then
				self._owners[id] = editable
			elseif needsRestore(part) then
				table.insert(missing, part)
			end
		end
	end
	table.insert(
		self._connections,
		CollectionService:GetInstanceAddedSignal(TAG):Connect(function(part)
			self:_onAdded(part)
		end)
	)
	if #missing > 0 then
		task.spawn(self._restore, self, missing, true)
	end
end

-- Tagged parts appearing in the same frame are restored together.
function LocalMeshes:_onAdded(part: Instance)
	if self._pendingAdded then
		table.insert(self._pendingAdded, part)
		return
	end
	self._pendingAdded = { part }
	task.defer(function()
		local parts = self._pendingAdded
		self._pendingAdded = nil
		if self._destroyed or not parts then
			return
		end
		local missing = {}
		for _, added in parts do
			if needsRestore(added) then
				table.insert(missing, added)
			end
		end
		if #missing > 0 then
			self:_restore(missing, false)
		end
	end)
end

-- Downloads and applies the meshes of `parts`. Parts sharing an id share one
-- EditableMesh, as they did before saving. Yields.
function LocalMeshes:_restore(parts: { MeshPart }, atStartup: boolean)
	local started = os.clock()
	local groups: { [string]: { MeshPart } } = {}
	for _, part in parts do
		if not self._restoring[part] then
			self._restoring[part] = true
			local id = part:GetAttribute(ATTRIBUTE) :: string
			groups[id] = groups[id] or {}
			table.insert(groups[id], part)
		end
	end

	local ready = {} -- { { parts, temps: { [fidelityKey]: MeshPart }, id, editable } }
	local failures = {}
	for id, group in groups do
		local loaded, result = self:_download(id)
		if self._destroyed then
			if loaded then
				result.editable:Destroy()
			end
			break
		end
		if not loaded then
			table.insert(failures, string.format("%s (%s)", group[1]:GetFullName(), result))
			continue
		end
		if result.failedFaces > 0 then
			warn(string.format("[StudioTools] Local mesh %s: %d face(s) couldn't be restored", id, result.failedFaces))
		end
		-- one MeshPart per distinct collision/render fidelity in the group
		local temps = {}
		local ok, err = pcall(function()
			for _, part in group do
				local key = tostring(part.CollisionFidelity) .. "|" .. tostring(part.RenderFidelity)
				if not temps[key] then
					temps[key] = AssetService:CreateMeshPartAsync(Content.fromObject(result.editable), {
						CollisionFidelity = part.CollisionFidelity,
						RenderFidelity = part.RenderFidelity,
					})
				end
			end
		end)
		if not ok then
			for _, temp in temps do
				temp:Destroy()
			end
			result.editable:Destroy()
			table.insert(failures, string.format("%s (%s)", group[1]:GetFullName(), tostring(err)))
			continue
		end
		table.insert(ready, { parts = group, temps = temps, id = id, editable = result.editable })
	end

	if not self._destroyed and #ready > 0 then
		-- ApplyMesh is tracked by undo: give it its own waypoint, rather than
		-- letting it merge into the user's next change
		local historyWasEmpty = not ChangeHistoryService:GetCanUndo() and not ChangeHistoryService:GetCanRedo()
		local recording = ChangeHistoryService:TryBeginRecording("Load local meshes", "Load local meshes")
		local restored = 0
		for _, item in ready do
			for _, part in item.parts do
				if needsRestore(part) then
					local key = tostring(part.CollisionFidelity) .. "|" .. tostring(part.RenderFidelity)
					local ok, err = pcall(part.ApplyMesh, part, item.temps[key])
					if ok then
						restored += 1
					else
						table.insert(failures, string.format("%s (%s)", part:GetFullName(), tostring(err)))
					end
				end
			end
			if not self._owners[item.id] then
				self._owners[item.id] = item.editable
			end
		end
		if recording then
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end
		if atStartup and historyWasEmpty and recording then
			ChangeHistoryService:ResetWaypoints()
		end
		print(string.format("[StudioTools] Restored %d local mesh part(s) in %.2fs", restored, os.clock() - started))
	end
	for _, item in ready do
		for _, temp in item.temps do
			temp:Destroy()
		end
	end
	for _, part in parts do
		self._restoring[part] = nil
	end
	if #failures > 0 then
		warn(string.format("[StudioTools] Couldn't restore %d local mesh(es):\n  %s", #failures, table.concat(failures, "\n  ")))
	end
end

-- -> true, { editable, failedFaces } or false, message
function LocalMeshes:_download(id: string): (boolean, any)
	local path = string.format("/localmesh/load?place=%d&id=%s", game.PlaceId, id)
	local ok, data, status = ServerApi.request(self._serverUrl, "GET", path, nil)
	if not ok then
		if status == 404 then
			return false, if data == "not found" then OLD_SERVER else "not stored on this computer"
		end
		return false, tostring(data)
	end
	if type(data) ~= "table" or type(data.data) ~= "string" then
		return false, "bad response from the server"
	end
	local decoded, editable, failedFaces = pcall(function()
		return MeshCodec.decode(MeshCodec.fromBase64(data.data))
	end)
	if not decoded then
		return false, "couldn't decode: " .. tostring(editable)
	end
	return true, { editable = editable, failedFaces = failedFaces }
end

-- Saving --------------------------------------------------------------------

-- Is `id` used by another part in the place that shows a different mesh?
local function usedByOther(id: string, part: MeshPart, editable: EditableMesh): boolean
	for _, other in CollectionService:GetTagged(TAG) do
		if other ~= part and other:IsA("MeshPart") and other:GetAttribute(ATTRIBUTE) == id then
			local otherEditable = editableOf(other)
			if otherEditable and otherEditable ~= editable then
				return true
			end
		end
	end
	return false
end

-- Marks the part as a local mesh and uploads its EditableMesh (in the
-- background). Returns the mesh id. The part must show an EditableMesh.
-- Sets an attribute and a tag on the part, so call it inside the undo
-- recording that made the part.
function LocalMeshes:save(part: MeshPart): string
	local editable = editableOf(part)
	if not editable then
		error("the part's mesh isn't an EditableMesh", 2)
	end
	local id = part:GetAttribute(ATTRIBUTE)
	if not isValidId(id) then
		id = nil
	elseif self._owners[id] and self._owners[id] ~= editable then
		id = nil -- the id belongs to another mesh (this part is a copy)
	elseif usedByOther(id, part, editable) then
		id = nil
	end
	local meshId: string = id or string.lower(HttpService:GenerateGUID(false))
	self._owners[meshId] = editable
	part:SetAttribute(ATTRIBUTE, meshId)
	CollectionService:AddTag(part, TAG)

	self._uploads[meshId] = {
		editable = editable,
		meta = { part = part:GetFullName(), place = game.Name },
	}
	if not self._uploading then
		self._uploading = true
		task.spawn(self._uploadAll, self)
	end
	return meshId
end

-- Stops treating the part as a local mesh (e.g. it now has an uploaded
-- asset). The stored mesh is kept: undo may bring the old mesh back.
function LocalMeshes:clear(part: MeshPart)
	part:SetAttribute(ATTRIBUTE, nil)
	CollectionService:RemoveTag(part, TAG)
end

-- Uploads queued meshes one at a time; the latest state of each mesh is
-- what gets uploaded.
function LocalMeshes:_uploadAll()
	while true do
		local id, upload = next(self._uploads)
		if not id then
			break
		end
		self._uploads[id] = nil
		local editable: EditableMesh = upload.editable
		local encoded, data = pcall(MeshCodec.encode, editable)
		if not encoded then
			warn(string.format("[StudioTools] Couldn't save local mesh %s (%s): %s", id, upload.meta.part, tostring(data)))
			continue
		end
		local meta = table.clone(upload.meta)
		meta.vertices = #editable:GetVertices()
		meta.triangles = #editable:GetFaces()
		local body = { placeId = game.PlaceId, id = id, data = MeshCodec.toBase64(data), meta = meta }
		local saved, err, status
		for attempt = 1, UPLOAD_ATTEMPTS do
			saved, err, status = ServerApi.request(self._serverUrl, "POST", "/localmesh/save", body)
			if status == 404 then
				err = OLD_SERVER
				break
			end
			if saved or self._uploads[id] then
				break -- done, or superseded by a newer save of the same mesh
			end
			if attempt < UPLOAD_ATTEMPTS then
				task.wait(RETRY_DELAY)
			end
		end
		if not saved and not self._uploads[id] then
			warn(
				string.format(
					"[StudioTools] Couldn't store local mesh %s (%s) on the dev server: %s. It won't be restored if the place is closed; edit the part again once the server is running.",
					id,
					upload.meta.part,
					tostring(err)
				)
			)
		end
	end
	self._uploading = false
end

-- Stops restoring; queued uploads still finish.
function LocalMeshes:destroy()
	self._destroyed = true
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)
end

return LocalMeshes
