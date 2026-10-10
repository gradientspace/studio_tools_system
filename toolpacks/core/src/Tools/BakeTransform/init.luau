--[[
	Bake Transform: bakes the rotation and/or scale of the selected MeshParts
	into their mesh vertices, and optionally moves their pivots to the center
	or base of the result. The geometry stays exactly where it is in the
	world; the part's own axes and scale change instead.

	An Accept/Cancel tool. On start, each selected MeshPart's mesh is loaded
	into an editable copy (parts whose mesh can't be loaded, e.g. assets the
	user may not edit, are skipped and listed in the status). While the tool
	is active, each part shows its new bounding box (orange) and pivot axes;
	nothing in the place changes. Accept builds the baked meshes, then, in
	one undo step, replaces each part with a copy that has the baked mesh
	(MeshPart:ApplyMesh on a clone, so properties and children carry over)
	and repoints welds, constraints and other references at the copy. The
	baked meshes are EditableMeshes, which Studio doesn't save with the
	place, so each copy is made a local mesh (ctx:saveLocalMesh): stored on
	the dev server and restored when the place is opened again. A
	part whose mesh doesn't change (nothing to bake) only gets its pivot
	moved. Cancel, Escape or switching tools changes nothing.

	See BakeTarget.luau for the math.
]]

local Selection = game:GetService("Selection")
local UserInputService = game:GetService("UserInputService")

local SDK = require(script.Parent.Parent.SDK)
local BakeTarget = require(script.BakeTarget)

local MAX_PREVIEWS = 64 -- parts that get a bounds/pivot preview
local BOX_COLOR = Color3.fromRGB(255, 170, 0)
local AXIS_COLORS = { Color3.fromRGB(255, 70, 70), Color3.fromRGB(70, 220, 70), Color3.fromRGB(70, 140, 255) }

-- The 12 edges of a box, as pairs of corner sign vectors.
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
			local b = corners[j]
			-- corners differing in exactly one sign share an edge
			local diff = (a - b)
			if (math.abs(diff.X) > 0 and 1 or 0) + (math.abs(diff.Y) > 0 and 1 or 0) + (math.abs(diff.Z) > 0 and 1 or 0) == 1 then
				table.insert(BOX_EDGES, { a, b })
			end
		end
	end
end

local BakeTransform = SDK.Tool:extend({
	apiVersion = 1,
	id = "BakeTransform",
	name = "Bake Transform",
	version = "0.1.0",
	description = "Bake the rotation and/or scale of the selected MeshParts into their meshes, and optionally move their pivots to the center or base. The parts are replaced with copies that use the baked mesh.",
	tab = "Model",
	section = "Mesh",
	shutdown = {
		type = SDK.ShutdownType.AcceptCancel,
		accept = { text = "Bake", tooltip = "Replace the parts with copies that have their transform baked in (one undo step)" },
		cancel = { tooltip = "Exit without changing anything (Esc)" },
	},
	settings = {
		{
			key = "bakeRotation",
			label = "Bake rotation",
			type = "boolean",
			default = true,
			tooltip = "Rotate the vertices instead of the part, so the part ends up aligned with the world axes.",
		},
		{
			key = "bakeScale",
			label = "Bake scale",
			type = "boolean",
			default = true,
			tooltip = "Scale the vertices instead of the part, so the part's Size matches its mesh (scale 1). A non-uniform scale is always baked along with the rotation.",
		},
		{
			key = "pivot",
			label = "Pivot",
			type = "enum",
			options = { "Unchanged", "Center", "Base" },
			default = "Unchanged",
			tooltip = "Unchanged: the pivot stays where it is in the world. Center: the center of the part's new bounding box. Base: the center of the box's bottom face (the part's -Y side).",
		},
		{
			key = "help",
			label = "Orange: the new bounding boxes · F: frame the parts",
			type = "label",
		},
	},
})

local function selectedMeshParts(): { MeshPart }
	local parts = {}
	for _, instance in Selection:Get() do
		if instance:IsA("MeshPart") then
			table.insert(parts, instance)
		end
	end
	return parts
end

local function plural(count: number, singular: string, pluralForm: string?): string
	return string.format("%d %s", count, if count == 1 then singular else (pluralForm or singular .. "s"))
end

function BakeTransform:canActivate(): (boolean, string?)
	if #selectedMeshParts() > 0 then
		return true, nil
	end
	return false, "Select one or more MeshParts."
end

function BakeTransform:activate(ctx: SDK.ToolContext)
	self.closed = false
	self.loading = true
	-- one entry per selected MeshPart: { part, target?, error?, plan?, preview? }
	self.entries = {}
	for _, part in selectedMeshParts() do
		table.insert(self.entries, { part = part })
	end
	if #self.entries == 0 then
		self.loading = false
		ctx:setStatus("Select one or more MeshParts, then start Bake Transform again.")
		return
	end

	-- Editable copies are freed when the tool exits, except those now shown by
	-- baked parts.
	ctx:addCleanup(function()
		for _, entry in self.entries do
			if entry.target then
				entry.target:destroy()
			end
		end
	end)

	ctx:onSettingChanged(function()
		self:_refresh()
	end)
	ctx:onKey(function(input: InputObject, down: boolean)
		if down and input.KeyCode == Enum.KeyCode.F and not UserInputService:GetFocusedTextBox() then
			self:_frame()
		end
	end)
	for _, entry in self.entries do
		for _, property in { "CFrame", "Size", "PivotOffset", "Parent" } do
			ctx:connect(entry.part:GetPropertyChangedSignal(property), function()
				self:_scheduleRefresh()
			end)
		end
	end

	ctx:setStatus(string.format("Loading %s...", plural(#self.entries, "mesh", "meshes")))
	task.spawn(function()
		self:_load()
	end)
end

function BakeTransform:deactivate(ctx: SDK.ToolContext, reason: SDK.ShutdownReason)
	self.closed = true
	local prepared = self.prepared
	self.prepared = nil
	if reason ~= SDK.ShutdownReason.Accept or not prepared then
		if prepared then
			self:_destroyBuilt(prepared)
		end
		return
	end

	local applied = {}
	local skipped = {}
	local ok, err = ctx:recordUndo("Bake Transform", function()
		local swaps = BakeTarget.newSwaps()
		for _, item in prepared do
			if item.entry.target:isCurrent(item.plan) then
				local result = item.entry.target:apply(item.plan, item.built, swaps)
				applied[item.entry.part] = result
				if item.plan.meshChanged then
					-- the baked mesh is an EditableMesh: store it so it survives saving the place
					ctx:saveLocalMesh(result)
				end
			else
				table.insert(skipped, item.entry.part.Name)
			end
		end
		BakeTarget.finishSwaps(swaps)
	end)
	self:_destroyBuilt(prepared)
	if not ok then
		-- recordUndo reverted the place; none of the editables is in use
		for _, entry in self.entries do
			if entry.target then
				entry.target.applied = false
			end
		end
		warn("[Bake Transform] Nothing was changed: " .. tostring(err))
		return
	end
	if #skipped > 0 then
		warn(string.format("[Bake Transform] Skipped parts that changed while baking: %s", table.concat(skipped, ", ")))
	end

	-- select the copies in place of the parts they replaced
	local selection = {}
	for _, instance in Selection:Get() do
		table.insert(selection, applied[instance] or instance)
	end
	Selection:Set(selection)
	ctx:log(string.format("baked %d part(s)", #prepared - #skipped))
end

function BakeTransform:canAccept(): (boolean, string?)
	if self.loading then
		return false, "Loading the meshes..."
	end
	local changing = 0
	for _, entry in self.entries do
		if entry.plan and (entry.plan.meshChanged or entry.plan.pivotChanged) then
			changing += 1
		end
	end
	if changing == 0 then
		local loaded = 0
		for _, entry in self.entries do
			if entry.target then
				loaded += 1
			end
		end
		if loaded == 0 then
			return false, "None of the selected meshes can be edited"
		end
		return false, "Nothing to change with these options"
	end
	return true, nil
end

-- Accept builds the baked meshes first (this yields), so deactivate() can
-- swap them in all at once. Building fails as a whole: then nothing changes
-- and the tool stays open.
function BakeTransform:confirmShutdown(reason: SDK.ShutdownReason, _trigger: SDK.ShutdownTrigger): boolean
	if reason ~= SDK.ShutdownReason.Accept then
		return true
	end
	local ctx: SDK.ToolContext = self.ctx
	local prepared = {}
	local toBuild = 0
	for _, entry in self.entries do
		local plan = entry.plan
		if plan and (plan.meshChanged or plan.pivotChanged) then
			table.insert(prepared, { entry = entry, plan = plan, built = nil })
			if plan.meshChanged then
				toBuild += 1
			end
		end
	end

	local started = os.clock()
	local done = 0
	local progress = if toBuild > 0 then ctx:showProgress({ title = "Bake Transform", message = "Baking..." }) else nil
	for _, item in prepared do
		if item.plan.meshChanged then
			done += 1
			progress:setMessage(string.format("Baking %s (%d of %d)...", item.entry.part.Name, done, toBuild))
			local ok, result = pcall(item.entry.target.build, item.entry.target, item.plan)
			if self.closed then
				if ok then
					result:Destroy()
				end
				self:_destroyBuilt(prepared)
				return false
			end
			if not ok then
				self:_destroyBuilt(prepared)
				progress:close()
				local message = string.format("Couldn't bake %s: %s", item.entry.part.Name, (tostring(result):gsub("^.-:%d+: ", "")))
				ctx:setStatus(message)
				ctx:alert({ title = "Bake Transform failed", message = message .. "\n\nNothing was changed." })
				return false
			end
			item.built = result
		end
	end
	if progress then
		progress:close()
	end
	ctx:log(string.format("built %d baked mesh(es) in %.2fs", toBuild, os.clock() - started))
	self.prepared = prepared
	return true
end

function BakeTransform:_destroyBuilt(prepared: { any })
	for _, item in prepared do
		if item.built then
			item.built:Destroy()
			item.built = nil
		end
	end
end

-- Loading ----------------------------------------------------------------

function BakeTransform:_load()
	local ctx: SDK.ToolContext = self.ctx
	local started = os.clock()
	for i, entry in self.entries do
		if #self.entries > 1 then
			ctx:setStatus(string.format("Loading meshes... %d of %d", i, #self.entries))
		end
		local ok, result = pcall(BakeTarget.load, entry.part)
		if self.closed then
			if ok then
				result:destroy()
			end
			return
		end
		if ok then
			entry.target = result
		else
			entry.error = tostring(result):gsub("^.-:%d+: ", "")
		end
	end
	self.loading = false
	ctx:log(string.format("loaded %d mesh(es) in %.2fs", #self.entries, os.clock() - started))
	self:_refresh()
end

-- Planning and preview ---------------------------------------------------

function BakeTransform:_scheduleRefresh()
	if self.refreshScheduled then
		return
	end
	self.refreshScheduled = true
	task.defer(function()
		self.refreshScheduled = false
		if not self.closed then
			self:_refresh()
		end
	end)
end

-- Re-plans every loaded part for the current settings, updates the
-- previews, the status and the Accept button.
function BakeTransform:_refresh()
	if self.loading or self.closed then
		return
	end
	local ctx: SDK.ToolContext = self.ctx
	local settings = ctx.settings
	local options: BakeTarget.Options = {
		bakeRotation = settings.bakeRotation,
		bakeScale = settings.bakeScale,
		pivot = settings.pivot,
	}

	local meshes, pivots, unchanged, forced, previews = 0, 0, 0, 0, 0
	local failed = {}
	for _, entry in self.entries do
		local target = entry.target
		if target and entry.part.Parent then
			local plan = target:plan(options)
			entry.plan = plan
			if plan.meshChanged then
				meshes += 1
			elseif plan.pivotChanged then
				pivots += 1
			else
				unchanged += 1
			end
			if plan.scaleForced then
				forced += 1
			end
			if previews < MAX_PREVIEWS then
				previews += 1
				self:_showPreview(entry, plan)
			end
		else
			entry.plan = nil
			self:_hidePreview(entry)
			if entry.error then
				table.insert(failed, string.format("%s (%s)", entry.part.Name, entry.error))
			end
		end
	end

	local lines = {}
	if meshes > 0 then
		table.insert(lines, plural(meshes, "part") .. " will be replaced by a baked copy.")
	end
	if pivots > 0 then
		table.insert(lines, plural(pivots, "part") .. " only get" .. (if pivots == 1 then "s" else "") .. " a new pivot.")
	end
	if unchanged > 0 then
		table.insert(lines, plural(unchanged, "part") .. " already match" .. (if unchanged == 1 then "es" else "") .. " these options.")
	end
	if forced > 0 then
		table.insert(lines, string.format("Non-uniform scale is baked too for %s, since its rotation is.", plural(forced, "part")))
	end
	if #failed > 0 then
		table.insert(lines, string.format("Can't edit %s: %s", plural(#failed, "mesh", "meshes"), table.concat(failed, "; ")))
	end
	ctx:setStatus(table.concat(lines, " "))
	ctx:refreshShutdownButtons()
end

-- The new bounding box and pivot of one part.
function BakeTransform:_showPreview(entry: any, plan: BakeTarget.Plan)
	local ctx: SDK.ToolContext = self.ctx
	local preview = entry.preview
	if not preview then
		preview = { edges = {}, axes = {} }
		for i = 1, #BOX_EDGES do
			local line = ctx:createAdornment("LineHandleAdornment") :: LineHandleAdornment
			line.Thickness = 2
			line.AlwaysOnTop = true
			line.Color3 = BOX_COLOR
			line.Transparency = 0.15
			preview.edges[i] = line
		end
		for i = 1, 3 do
			local line = ctx:createAdornment("LineHandleAdornment") :: LineHandleAdornment
			line.Thickness = 3
			line.AlwaysOnTop = true
			line.ZIndex = 1
			line.Color3 = AXIS_COLORS[i]
			preview.axes[i] = line
		end
		local dot = ctx:createAdornment("SphereHandleAdornment") :: SphereHandleAdornment
		dot.AlwaysOnTop = true
		dot.ZIndex = 1
		dot.Color3 = Color3.new(1, 1, 1)
		preview.dot = dot
		entry.preview = preview
	end

	local cframe, half = plan.cframe, plan.size / 2
	for i, edge in BOX_EDGES do
		local a = cframe * (edge[1] * half)
		local b = cframe * (edge[2] * half)
		local line = preview.edges[i]
		line.CFrame = CFrame.lookAt(a, b)
		line.Length = (b - a).Magnitude
		line.Visible = true
	end

	local pivot = cframe * plan.pivotOffset
	local length = math.clamp(math.max(plan.size.X, plan.size.Y, plan.size.Z) * 0.2, 0.2, 50)
	local directions = { pivot.RightVector, pivot.UpVector, -pivot.LookVector }
	for i, line in preview.axes do
		line.CFrame = CFrame.lookAt(pivot.Position, pivot.Position + directions[i])
		line.Length = length
		line.Visible = true
	end
	preview.dot.CFrame = CFrame.new(pivot.Position)
	preview.dot.Radius = length * 0.08
	preview.dot.Visible = true
end

function BakeTransform:_hidePreview(entry: any)
	local preview = entry.preview
	if preview then
		for _, line in preview.edges do
			line.Visible = false
		end
		for _, line in preview.axes do
			line.Visible = false
		end
		preview.dot.Visible = false
	end
end

-- F: frames all the parts.
function BakeTransform:_frame()
	local minimum, maximum
	for _, entry in self.entries do
		local part = entry.part
		if part.Parent then
			local cframe, size = part.CFrame, part.Size / 2
			for _, x in { -1, 1 } do
				for _, y in { -1, 1 } do
					for _, z in { -1, 1 } do
						local corner = cframe * (Vector3.new(x, y, z) * size)
						minimum = if minimum then minimum:Min(corner) else corner
						maximum = if maximum then maximum:Max(corner) else corner
					end
				end
			end
		end
	end
	if minimum then
		self.ctx:focusView(CFrame.new((minimum + maximum) / 2), maximum - minimum)
	end
end

return BakeTransform
