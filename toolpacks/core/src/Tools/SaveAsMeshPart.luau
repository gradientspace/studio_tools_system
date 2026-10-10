--[[
	Save As MeshPart: uploads the selected MeshPart's mesh as a new Mesh
	asset (owned by the logged-in Studio user), so it becomes a regular
	MeshPart that is saved with the place. Meant for parts whose mesh only
	exists in memory as an EditableMesh (e.g. from Bake Transform), but it
	works on any mesh the user may edit.

	An Accept/Cancel tool with the asset's Name and a Replace Input option.
	Accept shows a progress dialog (ctx:showProgress) while ctx:uploadMesh
	uploads the mesh and loads the new asset back as a MeshPart. In one undo
	step it then either gives the input part the new mesh
	(MeshPart:ApplyMesh, keeping everything else), or adds a copy of the
	input with the new mesh next to it and selects that. Any failure is shown
	in a dialog and the tool stays open.
]]

local Selection = game:GetService("Selection")

local SDK = require(script.Parent.Parent.SDK)

local SaveAsMeshPart = SDK.Tool:extend({
	apiVersion = 1,
	id = "SaveAsMeshPart",
	name = "Save As MeshPart",
	version = "0.1.0",
	description = "Upload the selected MeshPart's mesh as a new Mesh asset, and either give the part the uploaded mesh or add a copy that uses it.",
	tab = "Model",
	section = "Mesh",
	order = 20,
	shutdown = {
		type = SDK.ShutdownType.AcceptCancel,
		accept = { text = "Upload", tooltip = "Upload the mesh as a new asset" },
		cancel = { tooltip = "Exit without uploading (Esc)" },
	},
	settings = {
		{
			key = "name",
			label = "Name",
			type = "string",
			default = "",
			tooltip = "Name of the new Mesh asset. Starts as the part's name.",
		},
		{
			key = "replaceInput",
			label = "Replace Input",
			type = "boolean",
			default = false,
			tooltip = "Give the selected part the uploaded mesh. Otherwise a copy of the part with the uploaded mesh is added next to it.",
		},
		{
			key = "help",
			label = "The asset is uploaded to your own inventory.",
			type = "label",
		},
	},
})

local function trim(text: string): string
	return (string.gsub(text, "^%s*(.-)%s*$", "%1"))
end

-- Error messages without the "Module:line:" prefix.
local function cleanError(err: any): string
	return (string.gsub(tostring(err), "^.-:%d+: ", ""))
end

function SaveAsMeshPart:canActivate(): (boolean, string?)
	local selected = Selection:Get()
	if #selected == 1 and selected[1]:IsA("MeshPart") then
		return true, nil
	end
	if #selected > 1 then
		return false, "Select a single MeshPart."
	end
	return false, "Select a MeshPart to save."
end

function SaveAsMeshPart:activate(ctx: SDK.ToolContext)
	self.closed = false
	local part = Selection:Get()[1]
	if not (part and part:IsA("MeshPart")) then
		ctx:setStatus("Select a MeshPart, then start Save As MeshPart again.")
		return
	end
	self.part = part :: MeshPart
	ctx:setSetting("name", part.Name)

	local content = part.MeshContent
	if content.SourceType == Enum.ContentSourceType.Object then
		ctx:setStatus(
			string.format("%s's mesh only exists in memory (an EditableMesh), so it isn't saved with the place. Uploading it makes it permanent.", part.Name)
		)
	elseif content.SourceType == Enum.ContentSourceType.Uri then
		ctx:setStatus(string.format("%s uses the mesh %s. Uploading saves a copy as a new asset.", part.Name, tostring(content.Uri)))
	else
		ctx:setStatus(string.format("%s has no mesh.", part.Name))
	end

	ctx:onSettingChanged(function()
		ctx:refreshShutdownButtons()
	end)
	ctx:connect(part.AncestryChanged, function()
		ctx:refreshShutdownButtons()
	end)
end

function SaveAsMeshPart:canAccept(): (boolean, string?)
	if not self.part or self.part.Parent == nil then
		return false, "The part is no longer in the place"
	end
	if self.part.MeshContent.SourceType == Enum.ContentSourceType.None then
		return false, "The part has no mesh"
	end
	if trim(self.ctx.settings.name) == "" then
		return false, "Enter a name for the asset"
	end
	return true, nil
end

-- Accept uploads first (this yields); deactivate() then changes the place.
-- A failure shows a dialog and keeps the tool open.
function SaveAsMeshPart:confirmShutdown(reason: SDK.ShutdownReason, _trigger: SDK.ShutdownTrigger): boolean
	if reason ~= SDK.ShutdownReason.Accept then
		return true
	end
	local ctx: SDK.ToolContext = self.ctx
	local part: MeshPart = self.part
	-- modal while uploading: no viewport input, shutdown buttons or Escape
	local progress = ctx:showProgress({ title = "Save As MeshPart", message = "Reading the mesh..." })
	local ok, result = pcall(ctx.uploadMesh, ctx, part, {
		name = trim(ctx.settings.name),
		description = string.format("Saved from %s with Save As MeshPart.", part.Name),
		onStatus = function(text: string)
			progress:setMessage(text)
		end,
	})
	progress:close()
	if self.closed then
		-- shut down (e.g. another tool picked) while uploading
		if ok then
			result.meshPart:Destroy()
			ctx:log(string.format("uploaded %s, but the tool closed before it was used; nothing in the place changed", result.uri))
		else
			ctx:log(cleanError(result))
		end
		return false
	end
	if not ok then
		local message = cleanError(result)
		ctx:setStatus("Upload failed: " .. message)
		ctx:alert({ title = "Couldn't save the mesh", message = message })
		return false
	end
	ctx:log(string.format("uploaded '%s' as %s", trim(ctx.settings.name), result.uri))
	self.prepared = result
	return true
end

function SaveAsMeshPart:deactivate(ctx: SDK.ToolContext, reason: SDK.ShutdownReason)
	self.closed = true
	local prepared = self.prepared
	self.prepared = nil
	if not prepared then
		return
	end
	if reason ~= SDK.ShutdownReason.Accept then
		prepared.meshPart:Destroy()
		return
	end

	local part: MeshPart = self.part
	local replace = ctx.settings.replaceInput
	local name = trim(ctx.settings.name)
	local ok, result = ctx:recordUndo("Save As MeshPart", function(): MeshPart
		if replace then
			part:ApplyMesh(prepared.meshPart)
			ctx:clearLocalMesh(part) -- it's an asset now, nothing to restore
			return part
		end
		local archivable = part.Archivable
		part.Archivable = true
		local copy = part:Clone() :: MeshPart
		part.Archivable = archivable
		copy.Archivable = archivable
		copy:ApplyMesh(prepared.meshPart)
		ctx:clearLocalMesh(copy)
		copy.Name = name
		copy.Parent = part.Parent
		return copy
	end)
	prepared.meshPart:Destroy()
	if ok then
		Selection:Set({ result })
		ctx:log(string.format("%s now uses %s", result:GetFullName(), prepared.uri))
	else
		-- after Accept the tool is gone, so the error can only go to the output
		warn(string.format("[Save As MeshPart] Uploaded %s, but couldn't apply it: %s", prepared.uri, cleanError(result)))
	end
end

return SaveAsMeshPart
