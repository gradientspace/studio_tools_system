--[[
	Sculpt: brush-based sculpting of a MeshPart's mesh.

	Starting the tool needs exactly one MeshPart selected (canActivate). An
	editable copy of the part's mesh is read into a SculptMesh (geometry3luau
	DMesh3 + AABB tree, see SculptSource.luau and SculptMesh.luau), and shown
	by a PreviewMesh (an EditableMesh-backed MeshPart in a temporary model)
	in place of the source part, which is hidden with
	LocalTransparencyModifier (a local, unsaved property).

	Strokes: a press on the mesh starts one, and dabs are placed along the
	mouse path every `spacing` x radius. Dabs find their vertices on the
	surface as it was when the stroke began (positions, normals and the
	AABB tree from then; those are updated when the stroke ends). The
	preview gets the moved positions and their region's new normals on
	every update. Ctrl/Cmd inverts the brush, Shift smooths instead, and
	[ / ] change the size. Each stroke is one undo step (ctx:addUndoStep)
	holding only the moved vertices' deltas, so Ctrl+Z / Ctrl+Y work.

	An Accept/Cancel tool. Accept writes the sculpt into the editable copy,
	which the part then shows (MeshPart:ApplyMesh, in place, one undo step;
	see SculptSource.luau). Studio doesn't save EditableMesh content with the
	place, so the part becomes a local mesh (ctx:saveLocalMesh): stored on
	the dev server and restored when the place is opened again. Sculpting it
	again starts from that mesh; Save As MeshPart uploads it as an asset.
	Cancel discards the sculpt (the tool asks first if there are changes).
]]

local Selection = game:GetService("Selection")
local UserInputService = game:GetService("UserInputService")

local SDK = require(script.Parent.Parent.SDK)
local SculptMesh = require(script.SculptMesh)
local SculptSource = require(script.SculptSource)
local Brushes = require(script.Brushes)
local PreviewMesh = require(script.PreviewMesh)
local BrushCursor = require(script.BrushCursor)

local DEFAULT_SPACING = 0.15 -- brush rates are tuned for this spacing
local SAMPLE_PIXELS = 3 -- the mouse path is sampled this often between updates
local MAX_SAMPLES = 64
local SIZE_KEY_FACTOR = 1.15 -- [ and ] scale the size by this

local CURSOR_COLORS = {
	normal = Color3.fromRGB(0, 170, 255),
	invert = Color3.fromRGB(255, 95, 70),
	smooth = Color3.fromRGB(80, 220, 120),
	grab = Color3.fromRGB(255, 200, 40),
}

-- Mirror planes through the part's center, as componentwise multipliers.
local MIRRORS: { [string]: Vector3 } = {
	X = Vector3.new(-1, 1, 1),
	Y = Vector3.new(1, -1, 1),
	Z = Vector3.new(1, 1, -1),
}

local Sculpt = SDK.Tool:extend({
	apiVersion = 1,
	id = "Sculpt",
	name = "Sculpt",
	version = "0.1.0",
	description = "Sculpt the selected MeshPart with brushes: clay, draw, flatten, smooth, inflate, pinch, crease and grab. Ctrl inverts, Shift smooths, [ and ] resize. Apply writes the sculpt into the part, as a local mesh.",
	tab = "Model",
	section = "Sculpt",
	shutdown = {
		type = SDK.ShutdownType.AcceptCancel,
		accept = {
			text = "Apply",
			tooltip = "Write the sculpt into the MeshPart (one undo step). It becomes a local mesh, kept by the dev server until it's uploaded with Save As MeshPart.",
		},
		cancel = { tooltip = "Exit and discard the sculpt (Esc)" },
	},
	settings = {
		{
			key = "brush",
			label = "Brush",
			type = "enum",
			options = Brushes.Names,
			default = "Clay",
			tooltip = "Clay builds up flat layers, Draw pushes out along the surface, Flatten levels, Smooth relaxes, Inflate swells along each vertex normal, Pinch pulls toward the center, Crease cuts a sharp groove, Grab drags a region.",
		},
		{
			key = "sizeMode",
			label = "Size in",
			type = "enum",
			options = { "Screen", "World" },
			default = "Screen",
			tooltip = "Screen: the brush keeps its size on screen as you zoom. World: a fixed radius in studs.",
		},
		{
			key = "sizePixels",
			label = "Radius (px)",
			type = "integer",
			default = 60,
			min = 4,
			max = 400,
			extended = { widget = "slider" },
			tooltip = "Brush radius in screen pixels. [ and ] change it.",
		},
		{
			key = "sizeStuds",
			label = "Radius (studs)",
			type = "number",
			default = 1,
			min = 0.05,
			max = 25,
			step = 0.05,
			extended = { widget = "slider" },
			tooltip = "Brush radius in studs. [ and ] change it.",
		},
		{
			key = "strength",
			label = "Strength",
			type = "number",
			default = 0.5,
			min = 0,
			max = 1,
			step = 0.01,
			extended = { widget = "slider" },
		},
		{
			key = "smoothStrength",
			label = "Smooth strength",
			type = "number",
			default = 0.5,
			min = 0,
			max = 1,
			step = 0.01,
			extended = { widget = "slider" },
			tooltip = "Strength of the Smooth brush, and of smoothing with Shift held.",
		},
		{
			key = "falloff",
			label = "Falloff",
			type = "enum",
			options = Brushes.FalloffNames,
			default = "Smooth",
			tooltip = "How the effect fades from the brush center to its edge.",
		},
		{
			key = "spacing",
			label = "Spacing",
			type = "number",
			default = DEFAULT_SPACING,
			min = 0.05,
			max = 1,
			step = 0.01,
			extended = { widget = "slider" },
			tooltip = "Distance between dabs along a stroke, as a fraction of the radius. Strength is scaled to match, so this mostly changes smoothness and speed.",
		},
		{
			key = "symmetry",
			label = "Mirror",
			type = "enum",
			options = { "Off", "X", "Y", "Z" },
			default = "Off",
			tooltip = "Mirror strokes across the part's own X, Y or Z axis, through its center.",
		},
		{
			key = "frontOnly",
			label = "Front faces only",
			type = "boolean",
			default = true,
			tooltip = "Only affect surface facing the camera, so strokes don't reach through thin parts.",
		},
		{
			key = "display",
			label = "Display",
			type = "enum",
			options = { "Textured", "Untextured", "Flat shaded" },
			default = "Textured",
			tooltip = "Textured: the part's own material and texture. Untextured: plain clay. Flat shaded: clay with faceted shading, to see the triangles.",
		},
		{
			key = "clayColor",
			label = "Clay color",
			type = "color",
			default = Color3.fromRGB(190, 190, 195),
			tooltip = "Color of the Untextured and Flat shaded displays.",
		},
		{
			key = "reset",
			label = "Reset Mesh",
			type = "button",
			tooltip = "Put every vertex back where it started. Can be undone.",
		},
		{
			key = "help",
			label = "Ctrl/Cmd: invert · Shift: smooth · [ ]: size · F: frame mesh · Shift+F: frame brush · C: center on cursor · Ctrl+Z: undo a stroke",
			type = "label",
		},
	},
})

function Sculpt:canActivate(): (boolean, string?)
	local selected = Selection:Get()
	if #selected == 1 and selected[1]:IsA("MeshPart") then
		return true, nil
	end
	if #selected > 1 then
		return false, "Select a single MeshPart to sculpt."
	end
	return false, "Select a MeshPart to sculpt."
end

function Sculpt:activate(ctx: SDK.ToolContext)
	self.closed = false
	self.loading = true
	self.source = nil
	self.built = nil
	self.sm = nil
	self.preview = nil
	self.stroke = nil
	self.applied = 0 -- strokes currently applied (for the exit confirmation)
	self.cursor = BrushCursor.new(ctx)

	local part = Selection:Get()[1]
	if not (part and part:IsA("MeshPart")) then
		ctx:setStatus("Select a MeshPart, then start Sculpt again.")
		return
	end
	self.part = part :: MeshPart
	self:_clearSelection()

	self:_refreshWidgets()
	ctx:onSettingChanged(function(key: string)
		if (key == "display" or key == "clayColor") and self.preview then
			self.preview:setDisplay(ctx.settings.display, ctx.settings.clayColor)
		end
		self:_refreshWidgets()
	end)
	ctx:onKey(function(input: InputObject, down: boolean)
		if not down or UserInputService:GetFocusedTextBox() then
			return
		end
		if input.KeyCode == Enum.KeyCode.LeftBracket then
			self:_resize(1 / SIZE_KEY_FACTOR)
		elseif input.KeyCode == Enum.KeyCode.RightBracket then
			self:_resize(SIZE_KEY_FACTOR)
		elseif input.KeyCode == Enum.KeyCode.C then
			if self.hoverPoint then
				ctx:centerView(self.hoverPoint)
			end
		elseif input.KeyCode == Enum.KeyCode.F then
			if ctx:isShiftDown() then
				self:_focusBrush()
			else
				self:_focusMesh()
			end
		end
	end)

	self:addInputBehavior(SDK.ClickDragInputBehavior:new({
		id = "SculptStroke",
		hitTest = function(point: SDK.InputPoint): number?
			return (self:_hit(point))
		end,
		onBeginDrag = function(point: SDK.InputPoint, modifiers: SDK.Modifiers)
			self:_beginStroke(point, modifiers)
		end,
		onUpdateDrag = function(point: SDK.InputPoint, modifiers: SDK.Modifiers)
			self:_updateStroke(point, modifiers)
		end,
		onEndDrag = function()
			self:_endStroke()
		end,
		onCancelDrag = function()
			self:_endStroke()
		end,
	}))
	self:addInputBehavior(SDK.HoverInputBehavior:new({
		id = "SculptCursor",
		hitTest = function(point: SDK.InputPoint): number?
			return (self:_hit(point))
		end,
		onUpdateHover = function(point: SDK.InputPoint, modifiers: SDK.Modifiers)
			self:_hover(point, modifiers)
		end,
		onEndHover = function()
			self.hoverPoint = nil
			if not self.stroke then
				self.cursor:hide()
			end
		end,
	}))

	ctx:setStatus(string.format("Loading %s...", part.Name))
	task.spawn(function()
		self:_load()
	end)
end

function Sculpt:deactivate(ctx: SDK.ToolContext, reason: SDK.ShutdownReason)
	self.closed = true
	self.stroke = nil
	local built = self.built
	self.built = nil
	if reason ~= SDK.ShutdownReason.Accept or not built then
		if built then
			built:Destroy()
		end
		return
	end

	local source = self.source
	local part: MeshPart = self.part
	local ok, err = ctx:recordUndo("Sculpt", function()
		source:apply(built)
		-- the part now shows an EditableMesh: store it so it survives saving the place
		ctx:saveLocalMesh(part)
	end)
	built:Destroy()
	if not ok then
		-- recordUndo reverted the place; the editable copy isn't in use
		source.applied = false
		warn("[Sculpt] The sculpt wasn't applied: " .. tostring(err))
		return
	end
	ctx:log(string.format("applied the sculpt to %s", part.Name))
end

function Sculpt:canAccept(): (boolean, string?)
	if self.loading then
		return false, "Loading the mesh..."
	elseif not self.sm then
		return false, "The mesh couldn't be loaded"
	elseif not self.part.Parent then
		return false, "The MeshPart was removed"
	elseif self.applied == 0 then
		return false, "Nothing sculpted yet"
	end
	return true, nil
end

-- Accept builds the new mesh first (this yields), so deactivate() can apply
-- it in one step. If building fails, nothing changes and the tool stays
-- open. Cancel asks before throwing strokes away.
function Sculpt:confirmShutdown(reason: SDK.ShutdownReason, _trigger: SDK.ShutdownTrigger): boolean
	local ctx: SDK.ToolContext = self.ctx
	if reason == SDK.ShutdownReason.Accept then
		self:_endStroke()
		local part: MeshPart = self.part
		local started = os.clock()
		local progress = ctx:showProgress({ title = "Sculpt", message = string.format("Applying the sculpt to %s...", part.Name) })
		local ok, result = pcall(self.source.build, self.source)
		progress:close()
		if self.closed then
			if ok then
				result:Destroy()
			end
			return false
		end
		if not ok then
			local message = string.format("Couldn't apply the sculpt to %s: %s", part.Name, (tostring(result):gsub("^.-:%d+: ", "")))
			ctx:setStatus(message)
			ctx:alert({ title = "Sculpt failed", message = message .. "\n\nNothing was changed." })
			return false
		end
		ctx:log(string.format("built the sculpted mesh in %.2fs", os.clock() - started))
		self.built = result
		return true
	end
	if reason == SDK.ShutdownReason.Cancel and self.applied > 0 then
		return ctx:confirm({
			title = "Discard the sculpt?",
			message = "Your strokes haven't been applied to the MeshPart. Use Apply to keep them.",
			confirmText = "Discard",
			cancelText = "Keep Sculpting",
		})
	end
	return true
end

function Sculpt:onAction(key: string)
	if key == "reset" and self.sm and not self.stroke then
		local record = self.sm:resetRecord()
		if record then
			-- after a reset no strokes are applied; undoing it brings the count back
			local before = self.applied
			self:_applyRecord(record, 1, 0)
			self.ctx:addUndoStep("Sculpt: Reset", function()
				self:_applyRecord(record, -1, before)
			end, function()
				self:_applyRecord(record, 1, 0)
			end)
		end
	end
end

-- Loading ----------------------------------------------------------------

function Sculpt:_load()
	local ctx: SDK.ToolContext = self.ctx
	local part: MeshPart = self.part
	local started = os.clock()

	local ok, source = pcall(SculptSource.load, part)
	if self.closed then
		if ok then
			source:destroy()
		end
		return
	end
	if not ok then
		self.loading = false
		ctx:setStatus(string.format("Couldn't read the mesh of %s: %s", part.Name, tostring(source)))
		ctx:refreshShutdownButtons()
		return
	end
	-- freed when the tool exits, unless the part shows it by then
	ctx:addCleanup(function()
		source:destroy()
	end)
	local sm = source.sm

	-- Objects made after the tool closed (the preview build yields) are
	-- destroyed right away instead of being handed to a finished context.
	local function own(object: any)
		if self.closed then
			object:Destroy()
		else
			ctx:addCleanup(object)
		end
	end
	local model = ctx:createTemporaryModel("SculptPreview")
	local built, preview = pcall(PreviewMesh.new, sm, part, model, ctx.settings.display, ctx.settings.clayColor, own)
	if self.closed then
		return
	end
	if not built then
		self.loading = false
		ctx:setStatus(string.format("Couldn't build the preview of %s: %s", part.Name, tostring(preview)))
		ctx:refreshShutdownButtons()
		return
	end

	self.loading = false
	self.source = source
	self.sm = sm
	self.preview = preview
	self:_hideSource()
	ctx:autoCameraSpeed(sm.size)
	ctx:connect(part:GetPropertyChangedSignal("CFrame"), function()
		preview:updatePlacement()
	end)

	local status = string.format("%s: %d vertices, %d triangles", part.Name, sm.vertexCount, sm.triangleCount)
	if sm.failedTriangles > 0 then
		status ..= string.format(" (%d non-manifold triangles skipped)", sm.failedTriangles)
	end
	ctx:setStatus(status)
	ctx:log(string.format("loaded %s in %.2fs", status, os.clock() - started))
	ctx:refreshInput()
	ctx:refreshShutdownButtons()
end

-- Clears the selection so Studio doesn't draw its selection box around the
-- (hidden) source part, and puts it back on deactivate unless the user has
-- selected something else meanwhile.
function Sculpt:_clearSelection()
	local previous = Selection:Get()
	Selection:Set({})
	self.ctx:addCleanup(function()
		if #Selection:Get() > 0 then
			return
		end
		local restore = {}
		for _, instance in previous do
			if instance:IsDescendantOf(game) then
				table.insert(restore, instance)
			end
		end
		Selection:Set(restore)
	end)
end

-- Hides the source part (and its decals) locally while the preview stands in
-- for it; restored on deactivate.
function Sculpt:_hideSource()
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

-- Settings ---------------------------------------------------------------

function Sculpt:_refreshWidgets()
	local ctx: SDK.ToolContext = self.ctx
	local settings = ctx.settings
	ctx:setSettingState("sizePixels", { visible = settings.sizeMode ~= "World" })
	ctx:setSettingState("sizeStuds", { visible = settings.sizeMode == "World" })
	ctx:setSettingState("strength", { enabled = settings.brush ~= "Smooth" and settings.brush ~= "Grab" })
	ctx:setSettingState("spacing", { enabled = settings.brush ~= "Grab" })
	ctx:setSettingState("clayColor", { enabled = settings.display ~= "Textured" })
end

function Sculpt:_resize(factor: number)
	local ctx: SDK.ToolContext = self.ctx
	if ctx.settings.sizeMode == "World" then
		ctx:setSetting("sizeStuds", ctx.settings.sizeStuds * factor)
	else
		local current = ctx.settings.sizePixels
		local resized = math.round(current * factor)
		if resized == current then
			resized += if factor > 1 then 1 else -1
		end
		ctx:setSetting("sizePixels", resized)
	end
end

-- Picking ----------------------------------------------------------------

function Sculpt:_localRay(ray: Ray): (Vector3, Vector3)
	local cframe = self.part.CFrame
	return cframe:PointToObjectSpace(ray.Origin), cframe:VectorToObjectSpace(ray.Direction)
end

-- The stroke-start surface under an input point: distance along the ray,
-- triangle, and local hit point. Nil if it misses, or if something else in
-- the place is in front of it.
function Sculpt:_hit(point: SDK.InputPoint): (number?, number?, Vector3?)
	local sm = self.sm
	if not sm or self.closed then
		return nil, nil, nil
	end
	local origin, direction = self:_localRay(point.ray)
	local t, tid = sm:raycast(origin, direction)
	if not t then
		return nil, nil, nil
	end
	local blocker = self.ctx:raycastAt(point, t, { self.part })
	if blocker and blocker.Distance < t - 1e-3 then
		return nil, nil, nil
	end
	return t, tid, origin + direction * t
end

-- Brush radius (studs) for a stroke or cursor at this world point.
function Sculpt:_radiusAt(worldPoint: Vector3): number
	local settings = self.ctx.settings
	if settings.sizeMode == "World" then
		return settings.sizeStuds
	end
	local camera = workspace.CurrentCamera
	local depth = math.max((worldPoint - camera.CFrame.Position):Dot(camera.CFrame.LookVector), 0.01)
	local perPixel = 2 * depth * math.tan(math.rad(camera.FieldOfView) / 2) / math.max(camera.ViewportSize.Y, 1)
	return settings.sizePixels * perPixel
end

-- The brush to use with these modifiers, and whether it's inverted.
function Sculpt:_mode(modifiers: SDK.Modifiers): (string, boolean)
	if modifiers.shift then
		return "Smooth", false
	end
	return self.ctx.settings.brush, modifiers.ctrl or modifiers.cmd
end

function Sculpt:_cursorColor(modifiers: SDK.Modifiers): Color3
	local brush, invert = self:_mode(modifiers)
	if brush == "Smooth" then
		return CURSOR_COLORS.smooth
	elseif brush == "Grab" then
		return CURSOR_COLORS.grab
	elseif invert then
		return CURSOR_COLORS.invert
	end
	return CURSOR_COLORS.normal
end

-- The mirror multipliers in effect: identity, plus the mirror if any.
function Sculpt:_mirrors(): { Vector3 }
	local list = { Vector3.one }
	local mirror = MIRRORS[self.ctx.settings.symmetry]
	if mirror then
		table.insert(list, mirror)
	end
	return list
end

-- One dab per mirror at a local center, with the surface normal and view
-- direction there. Also returns each dab's mirror multiplier.
function Sculpt:_dabs(center: Vector3, normal: Vector3, view: Vector3, radius: number, invert: boolean): ({ Brushes.Dab }, { Vector3 })
	local settings = self.ctx.settings
	local falloff = Brushes.Falloffs[settings.falloff] or Brushes.Falloffs.Smooth
	local dabs = {}
	local mirrors = self:_mirrors()
	for _, m in mirrors do
		local c, n, v = center * m, normal * m, view * m
		table.insert(dabs, {
			cx = c.X,
			cy = c.Y,
			cz = c.Z,
			nx = n.X,
			ny = n.Y,
			nz = n.Z,
			vx = v.X,
			vy = v.Y,
			vz = v.Z,
			radius = radius,
			strength = settings.strength,
			invert = invert,
			falloff = falloff,
			frontOnly = settings.frontOnly,
			rateScale = settings.spacing / DEFAULT_SPACING,
		})
	end
	return dabs, mirrors
end

-- Cursor -----------------------------------------------------------------

function Sculpt:_hover(point: SDK.InputPoint, modifiers: SDK.Modifiers)
	local t, tid = self:_hit(point)
	if not t or not tid then
		self.hoverPoint = nil
		self.cursor:hide()
		return
	end
	local world = point.ray.Origin + point.ray.Direction * t
	self.hoverPoint = world
	self:_showCursor(world, tid, self:_radiusAt(world), self:_cursorColor(modifiers))
end

function Sculpt:_showCursor(world: Vector3, tid: number?, radius: number, color: Color3)
	local normal = Vector3.yAxis
	if tid then
		normal = self.part.CFrame:VectorToWorldSpace(Vector3.new(self.sm:hitTriangleNormal(tid)))
	elseif self.cursorNormal then
		normal = self.cursorNormal
	end
	self.cursorNormal = normal
	self.lastStamp = { center = world, radius = radius }
	self.cursor:show(world, normal, radius, color)
end

-- Camera -------------------------------------------------------------------

-- F: frame the whole mesh (its current bounds).
function Sculpt:_focusMesh()
	local sm = self.sm
	if not sm then
		return
	end
	local pos = sm.pos
	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	for v = 0, sm.maxVertex - 1 do
		if #sm.vtris[v + 1] > 0 then
			local p = 3 * v
			local x, y, z = pos[p + 1], pos[p + 2], pos[p + 3]
			minX, maxX = math.min(minX, x), math.max(maxX, x)
			minY, maxY = math.min(minY, y), math.max(maxY, y)
			minZ, maxZ = math.min(minZ, z), math.max(maxZ, z)
		end
	end
	if minX > maxX then
		return
	end
	local center = Vector3.new((minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2)
	self.ctx:focusView(self.part.CFrame * CFrame.new(center), Vector3.new(maxX - minX, maxY - minY, maxZ - minZ))
end

-- Shift+F: frame the area of the last brush stamp (where the cursor was).
function Sculpt:_focusBrush()
	local stamp = self.lastStamp
	if not stamp then
		return
	end
	self.ctx:focusView(CFrame.new(stamp.center), Vector3.one * (2 * stamp.radius))
end

-- Strokes ----------------------------------------------------------------

function Sculpt:_beginStroke(point: SDK.InputPoint, modifiers: SDK.Modifiers)
	local t, tid, hitLocal = self:_hit(point)
	if not t or not tid or not hitLocal then
		return
	end
	local sm = self.sm
	local brush = self:_mode(modifiers)
	local world = point.ray.Origin + point.ray.Direction * t
	local radius = self:_radiusAt(world)
	sm:beginStroke()
	local stroke = {
		name = brush,
		radius = radius,
		lastDab = hitLocal,
		lastRay = point.ray,
		lastPosition = point.position,
		grab = nil :: any,
	}
	self.stroke = stroke

	local _, direction = self:_localRay(point.ray)
	local normal = Vector3.new(sm:hitTriangleNormal(tid))
	if brush == "Grab" then
		local regions = {}
		local dabs, mirrors = self:_dabs(hitLocal, normal, direction, radius, false)
		for index, dab in dabs do
			local m = mirrors[index]
			table.insert(regions, Brushes.grabRegion(sm, dab, m.X, m.Y, m.Z))
		end
		stroke.grab = {
			regions = regions,
			startWorld = world,
			planeNormal = workspace.CurrentCamera.CFrame.LookVector,
		}
	else
		self:_dab(stroke, hitLocal, tid, direction, modifiers)
	end
	self:_flush()
	self:_showCursor(world, tid, radius, self:_cursorColor(modifiers))
end

-- Applies the brush (per the current modifiers) at a local point.
function Sculpt:_dab(stroke: any, center: Vector3, tid: number, direction: Vector3, modifiers: SDK.Modifiers)
	local brush, invert = self:_mode(modifiers)
	if brush == "Grab" then
		return -- grab is decided when the stroke starts
	end
	local normal = Vector3.new(self.sm:hitTriangleNormal(tid))
	local smoothStrength = self.ctx.settings.smoothStrength
	for _, dab in self:_dabs(center, normal, direction, stroke.radius, invert) do
		Brushes.dab(self.sm, brush, dab, smoothStrength)
	end
end

function Sculpt:_updateStroke(point: SDK.InputPoint, modifiers: SDK.Modifiers)
	local stroke = self.stroke
	if not stroke or self.closed then
		return
	end
	local sm = self.sm

	if stroke.grab then
		local grab = stroke.grab
		local ray = point.ray
		local n = grab.planeNormal
		local denom = ray.Direction:Dot(n)
		if math.abs(denom) > 1e-6 then
			local s = (grab.startWorld - ray.Origin):Dot(n) / denom
			if s > 0 then
				local world = ray.Origin + ray.Direction * s
				local delta = self.part.CFrame:VectorToObjectSpace(world - grab.startWorld)
				Brushes.updateGrab(sm, grab.regions, delta.X, delta.Y, delta.Z)
				self:_flush()
				self:_showCursor(world, nil, stroke.radius, CURSOR_COLORS.grab)
			end
		end
		return
	end

	-- Sample the mouse path since the last update and dab every `spacing`.
	local spacing = stroke.radius * self.ctx.settings.spacing
	local fromRay: Ray, toRay = stroke.lastRay, point.ray
	local pixels = (point.position - stroke.lastPosition).Magnitude
	local samples = math.clamp(math.ceil(pixels / SAMPLE_PIXELS), 1, MAX_SAMPLES)
	local lastWorld, lastTid = nil, nil
	for i = 1, samples do
		local alpha = i / samples
		local origin = fromRay.Origin:Lerp(toRay.Origin, alpha)
		local direction = fromRay.Direction:Lerp(toRay.Direction, alpha).Unit
		local localOrigin, localDirection = self:_localRay(Ray.new(origin, direction))
		local t, tid = sm:raycast(localOrigin, localDirection)
		if t and tid then
			local hitLocal = localOrigin + localDirection * t
			lastWorld, lastTid = origin + direction * t, tid
			if (hitLocal - stroke.lastDab).Magnitude >= spacing then
				self:_dab(stroke, hitLocal, tid, localDirection, modifiers)
				stroke.lastDab = hitLocal
			end
		end
	end
	stroke.lastRay, stroke.lastPosition = toRay, point.position
	self:_flush()
	if lastWorld then
		self:_showCursor(lastWorld, lastTid, stroke.radius, self:_cursorColor(modifiers))
	end
end

function Sculpt:_endStroke()
	local stroke = self.stroke
	if not stroke then
		return
	end
	self.stroke = nil
	if self.closed then
		return
	end
	self:_flush()
	local record, moved, count = self.sm:endStroke()
	if not record then
		return
	end
	self:_finishChange(moved, count)
	self.applied += 1
	self.ctx:refreshShutdownButtons()
	self.ctx:addUndoStep("Sculpt: " .. stroke.name, function()
		self:_applyRecord(record, -1)
	end, function()
		self:_applyRecord(record, 1)
	end)
end

-- Pushes the vertices moved since the last flush to the preview, with new
-- normals for the region around them.
function Sculpt:_flush()
	local sm = self.sm
	local dirty, count = sm:takeDirty()
	if count > 0 then
		self.preview:setPositions(dirty, count)
		local tris, triCount, verts, vertCount = sm:affectedRegion(dirty, count)
		sm:computeNormals(verts, vertCount)
		self.preview:updateNormals(tris, triCount, verts, vertCount)
	end
end

-- After vertices moved for good (stroke end, undo, redo, reset): new
-- normals for the region, in the mesh and the preview, those normals and
-- positions become the next stroke's starting surface, and the tree is refit.
function Sculpt:_finishChange(moved: { number }, count: number)
	local sm = self.sm
	local tris, triCount, verts, vertCount = sm:affectedRegion(moved, count)
	sm:computeNormals(verts, vertCount)
	sm:syncHitNormals(verts, vertCount)
	self.preview:updateNormals(tris, triCount, verts, vertCount)
	sm:refitTree()
end

-- Applies an undo record forward (1) or backward (-1). `applied` sets the
-- count of applied strokes (default: one more or one fewer).
function Sculpt:_applyRecord(record: SculptMesh.Record, sign: number, applied: number?)
	if self.closed or not self.sm then
		return
	end
	local moved, count = self.sm:applyRecord(record, sign)
	self.preview:setPositions(moved, count)
	self:_finishChange(moved, count)
	self.applied = applied or (self.applied + sign)
	self.ctx:refreshInput()
	self.ctx:refreshShutdownButtons()
end

return Sculpt
