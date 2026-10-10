--[[
	MeshUpload: uploads a MeshPart's mesh as a new Mesh asset (owned by the
	logged-in Studio user) and loads it back as a MeshPart, ready for
	MeshPart:ApplyMesh. Used by ctx:uploadMesh (Save As MeshPart) and by the
	local mesh chip's "Save All As MeshParts".

	An EditableMesh-backed part is uploaded directly; any other part from an
	editable copy of its mesh. The upload is AssetService:CreateAssetAsync,
	which Studio gates behind the beta feature "CreateAssetAsync Luau API".
	A just-uploaded asset can take a moment to become loadable, so loading
	it back (CreateMeshPartAsync) is retried for a while.
]]

local AssetService = game:GetService("AssetService")

-- A just-uploaded asset can take a moment to become loadable.
local LOAD_RETRY_DELAYS = { 1, 2, 3, 5, 8 }

local MeshUpload = {}

export type Options = {
	name: string,
	description: string?,
	onStatus: ((text: string) -> ())?, -- progress messages for the user
	isCancelled: (() -> boolean)?, -- checked between steps
}

export type Result = {
	assetId: number,
	uri: string,
	meshPart: MeshPart, -- unparented, made from the new asset; the caller destroys it
}

-- What upload() errors with.
export type Failure = {
	message: string, -- for the user
	uri: string?, -- set if the asset was uploaded before the failure
	fatal: boolean?, -- uploading anything else will fail the same way
	cancelled: boolean?,
}

-- Error messages without the "Module:line:" prefix.
function MeshUpload.cleanError(err: any): string
	if type(err) == "table" and type(err.message) == "string" then
		return err.message
	end
	return (string.gsub(tostring(err), "^.-:%d+: ", ""))
end

-- Uploads the part's mesh. Yields. Errors with a Failure.
function MeshUpload.upload(part: MeshPart, options: Options): Result
	local function status(text: string)
		if options.onStatus then
			options.onStatus(text)
		end
	end
	local function fail(message: string, extra: { [string]: any }?)
		local failure: { [string]: any } = { message = message }
		if extra then
			for key, value in extra do
				failure[key] = value
			end
		end
		error(failure, 0)
	end
	local function checkCancelled(uri: string?)
		if options.isCancelled and options.isCancelled() then
			fail("cancelled", { cancelled = true, uri = uri })
		end
	end

	local editable: EditableMesh
	local owned = false
	local content = part.MeshContent
	if content.SourceType == Enum.ContentSourceType.Object and content.Object and content.Object:IsA("EditableMesh") then
		editable = content.Object :: EditableMesh
	elseif content.SourceType == Enum.ContentSourceType.None then
		fail("The part has no mesh.")
		error("unreachable")
	else
		status(string.format("Reading the mesh of %s...", part.Name))
		local loaded, result = pcall(AssetService.CreateEditableMeshAsync, AssetService, content)
		if not loaded then
			fail("Couldn't read the part's mesh: " .. MeshUpload.cleanError(result))
		end
		editable, owned = result, true
	end
	local ok, cancelled = pcall(checkCancelled)
	if not ok then
		if owned then
			editable:Destroy()
		end
		error(cancelled, 0)
	end

	status(string.format("Uploading '%s'...", options.name))
	local called, result, idOrError = pcall(AssetService.CreateAssetAsync, AssetService, editable, Enum.AssetType.Mesh, {
		Name = options.name,
		Description = options.description or "",
	})
	if owned then
		editable:Destroy()
	end
	if not called then
		local message = MeshUpload.cleanError(result)
		if string.find(message, "not available yet", 1, true) then
			-- the API is gated behind a Studio beta, which can also turn itself off
			fail(
				"Uploading from plugins needs the Studio beta feature \"CreateAssetAsync Luau API\". Turn it on in File > Beta Features, restart Studio, and try again.\n\n("
					.. message
					.. ")",
				{ fatal = true }
			)
		end
		fail("The upload failed: " .. message)
	end
	if result ~= Enum.CreateAssetResult.Success then
		local detail = if idOrError ~= nil then tostring(idOrError) else "no details"
		if result == Enum.CreateAssetResult.PermissionDenied then
			fail("Permission denied: Studio isn't allowed to create assets for you (" .. detail .. ").", { fatal = true })
		end
		fail(string.format("The upload failed (%s): %s", tostring(result.Name), detail))
	end
	local assetId = tonumber(idOrError)
	if not assetId then
		fail("The upload succeeded but returned no asset id (" .. tostring(idOrError) .. ").")
		error("unreachable")
	end
	local uri = "rbxassetid://" .. tostring(assetId)

	-- Load it back as a MeshPart, waiting for the new asset to be available.
	local lastError
	for attempt = 1, #LOAD_RETRY_DELAYS + 1 do
		if attempt > 1 then
			status(string.format("Uploaded '%s' as %s. Waiting for the new asset to be available...", options.name, uri))
			task.wait(LOAD_RETRY_DELAYS[attempt - 1])
		end
		checkCancelled(uri)
		local loaded, meshPart = pcall(AssetService.CreateMeshPartAsync, AssetService, Content.fromAssetId(assetId), {
			CollisionFidelity = part.CollisionFidelity,
			RenderFidelity = part.RenderFidelity,
		})
		if loaded then
			return { assetId = assetId, uri = uri, meshPart = meshPart }
		end
		lastError = meshPart
	end
	fail(string.format("The mesh was uploaded as %s, but couldn't be loaded back: %s", uri, MeshUpload.cleanError(lastError)), { uri = uri })
	error("unreachable")
end

return MeshUpload
