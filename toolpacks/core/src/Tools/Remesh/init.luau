--[[
	Remesh: rebuilds the selected MeshPart's mesh with evenly sized,
	well-shaped triangles, aiming for a triangle count (see RemeshJob.luau).

	Starting the tool needs exactly one MeshPart selected. Its mesh is read
	once; then every change to the target triangle count or the passes
	remeshes again in the background (the previous run is cancelled). The
	result is shown by a preview MeshPart in a temporary model in place of
	the part, which is hidden with LocalTransparencyModifier (local, not
	saved), with an optional wireframe. The resulting triangle count is
	shown in a read-only setting.

	An Accept/Cancel tool. Apply gives the part the remeshed mesh in place
	(one undo step; Shared/MeshPartUpdate.luau), as a local mesh
	(ctx:saveLocalMesh), like Sculpt. The remeshed mesh has no UVs.
]]

local AssetService = game:GetService("AssetService")
local Selection = game:GetService("Selection")
local UserInputService = game:GetService("UserInputService")

local SDK = require(script.Parent.Parent.SDK)
local MeshPartUpdate = require(script.Parent.Parent.Shared.MeshPartUpdate)
local RemeshJob = require(script.RemeshJob)

local RERUN_DELAY = 0.3 -- wait for slider drags to settle before remeshing
local WIRE_COLOR = Color3.fromRGB(20, 20, 24)

local Remesh = SDK.Tool:extend({
	apiVersion = 1,
	id = "Remesh",
	name = "Remesh",
	version = "0.1.0",
	description = "Rebuild the selected MeshPart's mesh with evenly sized triangles, aiming for a triangle count. Apply gives the part the new mesh, as a local mesh. UVs aren't kept.",
	tab = "Model",
	section = "Mesh",
	order = 30,
	shutdown = {
		type = SDK.ShutdownType.AcceptCancel,
		accept = {
			text = "Apply",
			tooltip = "Give the MeshPart the remeshed mesh (one undo step). It becomes a local mesh, kept by the dev server until it's uploaded with Save As MeshPart.",
		},
		cancel = { tooltip = "Exit without changing the part (Esc)" },
	},
	settings = {
		{
			key = "targetTriangles",
			label = "Target triangles",
			type = "integer",
			default = 5000,
			min = 100,
			max = RemeshJob.MAX_TRIANGLES,
			step = 100,
			extended = { widget = "slider" },
			tooltip = "About how many triangles to make. The edge length is worked out from the surface area, so the result comes out near this, not exactly on it. Above 20,000 it's simplified down to 20,000.",
		},
		{
			key = "passes",
			label = "Passes",
			type = "integer",
			default = 10,
			min = 1,
			max = 40,
			extended = { widget = "slider" },
			tooltip = "Remeshing passes. More passes give more even triangles and take longer.",
		},
		{
			key = "wireframe",
			label = "Show wireframe",
			type = "boolean",
			default = true,
			tooltip = "Draw the remeshed triangles' edges.",
		},
		{
			key = "triangles",
			label = "Triangles",
			type = "integer",
			default = 0,
			readOnly = true,
			tooltip = "Triangle count of the remeshed mesh.",
		},
		{
			key = "help",
			label = "F: frame the mesh · The remeshed mesh has no UVs, so textures won't map onto it.",
			type = "label",
		},
	},
})

function Remesh:canActivate(): (boolean, string?)
	local selected = Selection:Get()
	if #selected == 1 and selected[1]:IsA("MeshPart") then
		return true, nil
	end
	if #selected > 1 then
		return false, "Select a single MeshPart to remesh."
	end
	return false, "Select a MeshPart to remesh."
end

function Remesh:activate(ctx: SDK.ToolContext)
	self.closed = false
	self.source = nil
	self.result = nil -- the shown Result, with .gen
	self.preview = nil -- MeshPart showing result.editable
	self.built = nil -- for Accept
	self.applied = false
	self.generation = 0 -- bumped for every requested run; older runs stop
	self.running = false

	local part = Selection:Get()[1]
	if not (part and part:IsA("MeshPart")) then
		ctx:setStatus("Select a MeshPart, then start Remesh again.")
		return
	end
	self.part = part :: MeshPart
	self.model = ctx:createTemporaryModel("RemeshPreview")
	self.wire = ctx:createAdornment("WireframeHandleAdornment") :: WireframeHandleAdornment
	self.wire.Color3 = WIRE_COLOR
	self.wire.Transparency = 0.35
	self.wire.Visible = false

	-- the shown mesh is freed on exit unless the part uses it by then
	ctx:addCleanup(function()
		self:_setResult(nil, nil)
	end)
	ctx:setSetting("triangles", 0)
	ctx:onSettingChanged(function(key: string)
		if key == "targetTriangles" or key == "passes" then
			self:_scheduleRun()
		elseif key == "wireframe" then
			self:_updateWire()
		end
	end)
	ctx:onKey(function(input: InputObject, down: boolean)
		if down and input.KeyCode == Enum.KeyCode.F and not UserInputService:GetFocusedTextBox() then
			ctx:focusView(part.CFrame, part.Size)
		end
	end)
	ctx:connect(part:GetPropertyChangedSignal("CFrame"), function()
		self:_place()
	end)

	ctx:setStatus(string.format("Loading %s...", part.Name))
	task.spawn(function()
		self:_load()
	end)
end

function Remesh:_load()
	local ctx: SDK.ToolContext = self.ctx
	local part: MeshPart = self.part
	local ok, source = pcall(RemeshJob.load, part)
	if self.closed then
		return
	end
	if not ok then
		ctx:setStatus(string.format("Couldn't read the mesh of %s: %s", part.Name, (tostring(source):gsub("^.-:%d+: ", ""))))
		return
	end
	self.source = source
	ctx:autoCameraSpeed(part.Size)
	self:_hideSource()
	self:_scheduleRun(0)
end

-- Hides the part (and its decals) locally while the preview stands in for
-- it; restored on deactivate.
function Remesh:_hideSource()
	local saved = {}
	local function hide(instance: Instance)
		if instance:IsA("BasePart") or instance:IsA("Decal") then
			local object = instance :: any
			saved[object] = object.LocalTransparencyModifier
			object.LocalTransparencyModifier = 1
		end
	end
	hide(self.part)
	for _, descendant in self.part:GetDescendants() do
		hide(descendant)
	end
	self.ctx:addCleanup(function()
		for object, value in saved do
			pcall(function()
				object.LocalTransparencyModifier = value
			end)
		end
	end)
end

-- Running ------------------------------------------------------------------

-- Remeshes again after `delay` (default RERUN_DELAY), cancelling any run in
-- progress. The current result stays shown until the new one is ready.
function Remesh:_scheduleRun(delay: number?)
	if not self.source or self.closed then
		return
	end
	self.generation += 1
	local generation = self.generation
	self.ctx:refreshShutdownButtons()
	task.delay(delay or RERUN_DELAY, function()
		if generation == self.generation and not self.closed then
			self:_run(generation)
		end
	end)
end

function Remesh:_run(generation: number)
	local ctx: SDK.ToolContext = self.ctx
	local function current(): boolean
		return generation == self.generation and not self.closed
	end
	self.running = true
	ctx:refreshShutdownButtons()
	local started = os.clock()
	local settings = ctx.settings
	local ok, result = pcall(RemeshJob.run, self.source, settings.targetTriangles, settings.passes, function(text: string)
		if current() then
			ctx:setStatus(text)
		end
	end, function(): boolean
		return not current()
	end)
	local preview: MeshPart? = nil
	if ok and result and current() then
		local built, made = pcall(AssetService.CreateMeshPartAsync, AssetService, Content.fromObject(result.editable), {
			CollisionFidelity = Enum.CollisionFidelity.Box,
			RenderFidelity = Enum.RenderFidelity.Precise,
		})
		if built then
			preview = made
		else
			ok, result = false, made
		end
	end
	if not current() then
		-- superseded or closed: the newer run (if any) reports
		if ok and result then
			result.editable:Destroy()
		end
		if preview then
			preview:Destroy()
		end
		return
	end
	self.running = false
	if not ok or not result then
		ctx:setStatus("Remeshing failed: " .. (tostring(result):gsub("^.-:%d+: ", "")))
		ctx:refreshShutdownButtons()
		return
	end

	result.gen = generation
	self:_setResult(result, preview)
	ctx:setSetting("triangles", result.triangles)
	local status = string.format("%d triangles, %d vertices", result.triangles, result.vertices)
	if result.remeshedTriangles > result.triangles then
		status ..= string.format(" (remeshed to %d, then simplified)", result.remeshedTriangles)
	end
	if self.source.failedTriangles > 0 then
		status ..= string.format(". %d non-manifold triangles of the input were skipped", self.source.failedTriangles)
	end
	ctx:setStatus(status .. ".")
	ctx:log(string.format("remeshed to %d triangles in %.2fs", result.triangles, os.clock() - started))
	ctx:refreshShutdownButtons()
end

-- Shows a new result (or nothing), freeing the previous one unless the part
-- now uses it.
function Remesh:_setResult(result: any, preview: MeshPart?)
	local old, oldPreview = self.result, self.preview
	self.result, self.preview = result, preview
	if oldPreview then
		oldPreview:Destroy()
	end
	if old and not self.applied then
		old.editable:Destroy()
	end
	if preview then
		local part: MeshPart = self.part
		preview.Name = part.Name .. " (Remesh)"
		preview.Anchored = true
		preview.CanCollide = false
		preview.CanTouch = false
		preview.CanQuery = false
		preview.CastShadow = part.CastShadow
		preview.Material = part.Material
		preview.MaterialVariant = part.MaterialVariant
		preview.Color = part.Color
		preview.Reflectance = part.Reflectance
		self:_place()
		preview.Parent = self.model
	end
	self:_updateWire()
end

-- Puts the preview where the part's remeshed mesh will be.
function Remesh:_place()
	local preview, result = self.preview, self.result
	if preview and result and self.source then
		local scale = self.source.scale
		preview.Size = scale * result.size
		preview.CFrame = self.part.CFrame * CFrame.new(scale * result.center)
	end
end

function Remesh:_updateWire()
	local wire: WireframeHandleAdornment = self.wire
	if not wire then
		return
	end
	wire:Clear()
	local result, preview = self.result, self.preview
	if result and preview and self.ctx.settings.wireframe then
		wire.Adornee = preview
		wire:AddLines(result.lines)
		wire.Visible = true
	else
		wire.Visible = false
	end
end

-- Accept -------------------------------------------------------------------

function Remesh:canAccept(): (boolean, string?)
	if not self.source then
		return false, "Loading the mesh..."
	elseif self.running or not self.result or self.result.gen ~= self.generation then
		return false, "Remeshing..."
	elseif not self.part.Parent then
		return false, "The MeshPart was removed"
	end
	return true, nil
end

-- Accept makes the final MeshPart (with the part's collision fidelity; this
-- yields) so deactivate() can apply it in one step.
function Remesh:confirmShutdown(reason: SDK.ShutdownReason, _trigger: SDK.ShutdownTrigger): boolean
	if reason ~= SDK.ShutdownReason.Accept then
		return true
	end
	local ctx: SDK.ToolContext = self.ctx
	local part: MeshPart = self.part
	local result = self.result
	local progress = ctx:showProgress({ title = "Remesh", message = string.format("Applying the new mesh to %s...", part.Name) })
	local ok, built = pcall(AssetService.CreateMeshPartAsync, AssetService, Content.fromObject(result.editable), {
		CollisionFidelity = part.CollisionFidelity,
		RenderFidelity = part.RenderFidelity,
	})
	progress:close()
	if self.closed then
		if ok then
			built:Destroy()
		end
		return false
	end
	if not ok or self.result ~= result then
		if ok then
			built:Destroy()
		end
		local message = if ok
			then "The settings changed while applying; try again."
			else string.format("Couldn't apply the new mesh to %s: %s", part.Name, (tostring(built):gsub("^.-:%d+: ", "")))
		ctx:setStatus(message)
		ctx:alert({ title = "Remesh failed", message = message .. "\n\nNothing was changed." })
		return false
	end
	self.built = built
	return true
end

function Remesh:deactivate(ctx: SDK.ToolContext, reason: SDK.ShutdownReason)
	self.closed = true
	local built = self.built
	self.built = nil
	if reason ~= SDK.ShutdownReason.Accept or not built then
		if built then
			built:Destroy()
		end
		return
	end
	local part: MeshPart = self.part
	local result = self.result
	local ok, err = ctx:recordUndo("Remesh", function()
		MeshPartUpdate.apply(part, built, result.center, result.size)
		self.applied = true
		-- the part now shows an EditableMesh: store it so it survives saving the place
		ctx:saveLocalMesh(part)
	end)
	built:Destroy()
	if not ok then
		-- recordUndo reverted the place; the mesh isn't in use
		self.applied = false
		warn("[Remesh] The new mesh wasn't applied: " .. tostring(err))
		return
	end
	ctx:log(string.format("applied a %d-triangle mesh to %s", result.triangles, part.Name))
end

return Remesh
