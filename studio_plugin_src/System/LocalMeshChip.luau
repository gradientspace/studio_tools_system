--[[
	LocalMeshChip: the "N Local Meshes" chip in the viewport's bottom-right
	corner (ViewportOverlay:setChip), shown while the place has at least one
	local mesh (a MeshPart tagged by LocalMeshes). Its menu:

	  Show Boxes             toggles an orange box around each local mesh
	                         (remembered with plugin:SetSetting)
	  Save All As MeshParts  uploads every local mesh as a new Mesh asset
	                         (MeshUpload) and gives its parts the uploaded mesh
	                         in place, like Save As MeshPart with Replace
	                         Input, in one undo step. Parts sharing a mesh id
	                         (duplicates) share one upload. Asks first, shows
	                         a progress dialog while it runs, and lists any
	                         failures at the end. Not while a tool is active,
	                         and no tool can start while it runs.
]]

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local CollectionService = game:GetService("CollectionService")
local CoreGui = game:GetService("CoreGui")

local SDK = require(script.Parent.Parent.SDK)
local LocalMeshes = require(script.Parent.LocalMeshes)
local MeshUpload = require(script.Parent.MeshUpload)

local BOXES_SETTING = "StudioToolsSystem.LocalMeshBoxes"
local BOX_COLOR = Color3.fromRGB(255, 140, 30)
local MAX_BOXES = 500
local MAX_ASSET_NAME = 50

-- The 12 edges of a unit box, as pairs of corners (signs).
local BOX_EDGES: { { Vector3 } } = {}
do
	local corners = {}
	for _, x in { -1, 1 } do
		for _, y in { -1, 1 } do
			for _, z in { -1, 1 } do
				table.insert(corners, Vector3.new(x, y, z))
			end
		end
	end
	for i, a in corners do
		for j = i + 1, #corners do
			local d = a - corners[j]
			if (if d.X ~= 0 then 1 else 0) + (if d.Y ~= 0 then 1 else 0) + (if d.Z ~= 0 then 1 else 0) == 1 then
				table.insert(BOX_EDGES, { a, corners[j] })
			end
		end
	end
end

local LocalMeshChip = {}
LocalMeshChip.__index = LocalMeshChip

export type Options = {
	plugin: Plugin,
	overlay: any, -- ViewportOverlay
	localMeshes: any, -- LocalMeshes
	isToolActive: () -> boolean,
	toolChanged: SDK.Signal, -- fires when a tool activates or deactivates
	setBusy: (busy: boolean) -> (), -- no tool may start while busy
}

local function plural(count: number, singular: string, pluralForm: string?): string
	return string.format("%d %s", count, if count == 1 then singular else (pluralForm or singular .. "s"))
end

local function isLoaded(part: MeshPart): boolean
	local content = part.MeshContent
	return content.SourceType == Enum.ContentSourceType.Object and content.Object ~= nil and content.Object:IsA("EditableMesh")
end

function LocalMeshChip.new(options: Options)
	local self = setmetatable({}, LocalMeshChip)
	self._options = options
	self._maid = SDK.Maid.new()
	self._parts = {} :: { MeshPart }
	self._boxes = {} :: { [MeshPart]: { lines: { LineHandleAdornment }, connection: RBXScriptConnection } }
	self._saving = false
	self._refreshPending = false
	local ok, saved = pcall(options.plugin.GetSetting, options.plugin, BOXES_SETTING)
	self._showBoxes = ok and saved == true

	local folder = Instance.new("Folder")
	folder.Name = "StudioToolsLocalMeshBoxes"
	folder.Parent = CoreGui
	self._boxFolder = self._maid:add(folder)

	self._maid:add(CollectionService:GetInstanceAddedSignal(LocalMeshes.TAG):Connect(function()
		self:_scheduleRefresh()
	end))
	self._maid:add(CollectionService:GetInstanceRemovedSignal(LocalMeshes.TAG):Connect(function()
		self:_scheduleRefresh()
	end))
	self._maid:add(options.toolChanged:connect(function()
		self:_scheduleRefresh()
	end))
	self._maid:add(function()
		self:_clearBoxes()
		options.overlay:setChip(nil)
	end)
	self:_refresh()
	return self
end

function LocalMeshChip:_scheduleRefresh()
	if self._refreshPending then
		return
	end
	self._refreshPending = true
	task.defer(function()
		self._refreshPending = false
		if not self._destroyed then
			self:_refresh()
		end
	end)
end

-- Re-reads the local meshes and updates the chip and the boxes.
function LocalMeshChip:_refresh()
	local parts = {}
	for _, instance in CollectionService:GetTagged(LocalMeshes.TAG) do
		if instance:IsA("MeshPart") then
			table.insert(parts, instance :: MeshPart)
		end
	end
	self._parts = parts
	self:_updateBoxes()

	local overlay = self._options.overlay
	if #parts == 0 then
		overlay:setChip(nil)
		return
	end
	local toolActive = self._options.isToolActive()
	overlay:setChip({
		text = plural(#parts, "Local Mesh", "Local Meshes"),
		items = {
			{ key = "boxes", text = "Show Boxes", checked = self._showBoxes, tooltip = "Outline every local mesh in the viewport." },
			{
				key = "saveAll",
				text = "Save All As MeshParts",
				enabled = not toolActive and not self._saving,
				tooltip = if toolActive
					then "Exit the current tool first."
					else "Uploads each local mesh (an EditableMesh kept only on this computer, by the dev server) to Roblox as a new Mesh asset in your inventory, then updates the MeshParts to use those assets, so they're saved with the place like any other MeshPart. One undo step.",
			},
		},
		onSelect = function(key: string)
			if key == "boxes" then
				self:_setShowBoxes(not self._showBoxes)
			elseif key == "saveAll" then
				self:_saveAll()
			end
		end,
	})
end

-- Boxes ---------------------------------------------------------------------

function LocalMeshChip:_setShowBoxes(show: boolean)
	self._showBoxes = show
	pcall(self._options.plugin.SetSetting, self._options.plugin, BOXES_SETTING, show)
	self:_refresh()
end

function LocalMeshChip:_clearBoxes()
	for part in self._boxes do
		self:_removeBox(part)
	end
end

function LocalMeshChip:_removeBox(part: MeshPart)
	local box = self._boxes[part]
	if box then
		box.connection:Disconnect()
		for _, line in box.lines do
			line:Destroy()
		end
		self._boxes[part] = nil
	end
end

-- Lines relative to the part (Adornee), so they follow it when it moves;
-- redrawn when its Size changes.
local function placeLines(part: MeshPart, lines: { LineHandleAdornment })
	local half = part.Size / 2
	for i, edge in BOX_EDGES do
		local a, b = edge[1] * half, edge[2] * half
		local line = lines[i]
		line.CFrame = CFrame.lookAt(a, b)
		line.Length = (b - a).Magnitude
	end
end

function LocalMeshChip:_updateBoxes()
	local wanted: { [MeshPart]: boolean } = {}
	if self._showBoxes then
		for i, part in self._parts do
			if i > MAX_BOXES then
				break
			end
			wanted[part] = true
		end
	end
	for part in self._boxes do
		if not wanted[part] then
			self:_removeBox(part)
		end
	end
	for part in wanted do
		if not self._boxes[part] then
			local lines = {}
			for i = 1, #BOX_EDGES do
				local line = Instance.new("LineHandleAdornment")
				line.Adornee = part
				line.Color3 = BOX_COLOR
				line.Thickness = 4
				line.Transparency = 0.1
				line.Parent = self._boxFolder
				lines[i] = line
			end
			placeLines(part, lines)
			self._boxes[part] = {
				lines = lines,
				connection = part:GetPropertyChangedSignal("Size"):Connect(function()
					placeLines(part, lines)
				end),
			}
		end
	end
end

-- Save All ------------------------------------------------------------------

function LocalMeshChip:_saveAll()
	local options = self._options
	local overlay = options.overlay
	if self._saving or options.isToolActive() then
		return
	end

	-- one upload per mesh id; parts whose mesh isn't loaded can't be uploaded
	local groups: { { id: string, parts: { MeshPart } } } = {}
	local byId: { [string]: { id: string, parts: { MeshPart } } } = {}
	local failures = {}
	for _, part in self._parts do
		local id = part:GetAttribute(LocalMeshes.ATTRIBUTE)
		if part.Parent == nil or type(id) ~= "string" then
			continue
		end
		if not isLoaded(part) then
			table.insert(failures, string.format("%s: its mesh isn't loaded (not stored on this computer?)", part:GetFullName()))
			continue
		end
		local group = byId[id]
		if not group then
			group = { id = id, parts = {} }
			byId[id] = group
			table.insert(groups, group)
		end
		table.insert(group.parts, part)
	end
	if #groups == 0 then
		overlay:alert({
			title = "Save All As MeshParts",
			message = "None of the local meshes can be uploaded.\n\n" .. table.concat(failures, "\n"),
		})
		return
	end

	local partCount = 0
	for _, group in groups do
		partCount += #group.parts
	end
	local confirmed = overlay:confirm({
		title = "Save All As MeshParts",
		message = string.format(
			"Upload %s as new Mesh assets in your inventory, and give the %s using them the uploaded meshes? This is one undo step.",
			plural(#groups, "mesh", "meshes"),
			plural(partCount, "part")
		),
		confirmText = "Upload",
	})
	if not confirmed or self._saving or options.isToolActive() then
		return
	end

	self._saving = true
	options.setBusy(true)
	self:_refresh()
	local started = os.clock()
	local progress = overlay:showProgress({ title = "Save All As MeshParts", message = "Starting..." })
	local uploaded = {} -- { group, result }
	for index, group in groups do
		local part = group.parts[1]
		local prefix = string.format("%d of %d: ", index, #groups)
		progress:setMessage(prefix .. string.format("Uploading '%s'...", part.Name))
		local ok, result = pcall(MeshUpload.upload, part, {
			name = string.sub(part.Name, 1, MAX_ASSET_NAME),
			description = string.format("Saved from %s with Save All As MeshParts.", part.Name),
			onStatus = function(text: string)
				progress:setMessage(prefix .. text)
			end,
			isCancelled = function()
				return self._destroyed
			end,
		})
		if self._destroyed then
			if ok then
				result.meshPart:Destroy()
			end
			break
		end
		if ok then
			table.insert(uploaded, { group = group, result = result })
		else
			table.insert(failures, string.format("%s: %s", part:GetFullName(), MeshUpload.cleanError(result)))
			if type(result) == "table" and result.fatal then
				-- e.g. the upload API isn't enabled: the rest would fail the same way
				break
			end
		end
	end
	progress:close()

	-- give the parts their uploaded meshes, in one undo step
	local applied = 0
	if not self._destroyed and #uploaded > 0 then
		local recording = ChangeHistoryService:TryBeginRecording("Save All As MeshParts", "Save All As MeshParts")
		for _, item in uploaded do
			for _, part in item.group.parts do
				-- skip parts deleted or changed while uploading
				if part.Parent ~= nil and part:GetAttribute(LocalMeshes.ATTRIBUTE) == item.group.id then
					local ok, err = pcall(function()
						part:ApplyMesh(item.result.meshPart)
						options.localMeshes:clear(part) -- it's an asset now, nothing to restore
					end)
					if ok then
						applied += 1
					else
						table.insert(failures, string.format("%s: uploaded as %s, but couldn't be applied: %s", part:GetFullName(), item.result.uri, MeshUpload.cleanError(err)))
					end
				end
			end
		end
		if recording then
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end
	end
	for _, item in uploaded do
		item.result.meshPart:Destroy()
	end

	self._saving = false
	options.setBusy(false)
	if self._destroyed then
		return
	end
	self:_refresh()
	print(
		string.format(
			"[StudioTools] Save All As MeshParts: uploaded %s and applied them to %s in %.1fs",
			plural(#uploaded, "mesh", "meshes"),
			plural(applied, "part"),
			os.clock() - started
		)
	)
	if #failures > 0 then
		overlay:alert({
			title = "Save All As MeshParts",
			message = string.format(
				"Saved %s of %d. Couldn't save:\n\n%s",
				plural(#uploaded, "mesh", "meshes"),
				#groups,
				table.concat(failures, "\n")
			),
		})
	end
end

function LocalMeshChip:destroy()
	self._destroyed = true
	self._maid:clean()
end

return LocalMeshChip
