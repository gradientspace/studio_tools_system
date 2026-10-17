--[[
	CurveDrawingTool: base class for tools that act on a curve the user
	draws on the surface in the viewport. A subclass picks what kind of
	curve with its `curveKind` class field:
	  "polygon"  an area: always closed, at least 3 points
	  "path"     a line: open, or closed by ending it on its first point

	Drawing (one ClickOrDragInputBehavior):
	- Press and drag: a freehand curve, sampled every `sampleSpacing`
	  studs, finished on release. A path closes if it ends near its start.
	- Click: starts a polyline; each click adds a point. Clicking the first
	  point again closes the curve, clicking the last point again (a
	  double click) or pressing Enter finishes it. Dragging while a
	  polyline is open adds a freehand stretch to it. Backspace removes
	  the last point, and Escape cancels the curve (instead of exiting).

	The curve is drawn on the 3D surface but treated as a 2D curve in the
	XZ plane: it's shown (on top of everything) projected down to the
	height of its lowest drawn point, with thin lines up to where each
	clicked point was drawn.

	Subclasses override:
	  onCurveFinished(curve)   required; a curve was finished (see Curve)
	  onCurveStarted()         optional; the user started drawing a new curve
	  onCurveCancelled()       optional
	  pickSurface(point, fallbackY?)
	                           optional; where an input point's ray meets the
	                           surface being drawn on (default: anything
	                           ctx:raycastAt hits, else the plane at fallbackY
	                           or 0)
	  updateStatus()           optional; sets the status line (the default
	                           shows drawing hints)
	and call the base versions of activate() and confirmShutdown() if they
	override those. Helpers: finishCurve(), cancelCurve(),
	removeLastPoint(), isDrawing(), showCurve(curve?) (the finished curve
	stays on screen until the next one starts; showCurve replaces or hides
	it) and setCurveColor(color).

	Since this lives in Shared/ rather than Tools/, it isn't listed as a tool.
]]

local UserInputService = game:GetService("UserInputService")

local SDK = require(script.Parent.Parent.SDK)

export type Curve = {
	kind: "polygon" | "path",
	closed: boolean,
	points: { Vector2 }, -- the 2D curve: (X, Z) of each point
	surfacePoints: { Vector3 }, -- where each point was drawn on the surface
	planeY: number, -- the height it's shown at: its lowest drawn point
	freehand: boolean, -- drawn by dragging (densely sampled) rather than clicked
}

local LINE_THICKNESS = 3
local DROP_THICKNESS = 1.5
local MARKER_SCALE = 0.006 -- marker radius per stud of distance from the camera

local CurveDrawingTool = SDK.Tool:extend({
	apiVersion = 1,
	curveKind = "polygon",
	sampleSpacing = 2, -- studs between freehand samples
	snapPixels = 12, -- clicks within this of the first or last point close or finish the curve
	curveColor = Color3.fromRGB(255, 200, 40),
})

function CurveDrawingTool:onCurveFinished(_curve: Curve)
	error(string.format("tool '%s' must implement onCurveFinished()", tostring(self.id)), 2)
end

function CurveDrawingTool:onCurveStarted() end

function CurveDrawingTool:onCurveCancelled() end

function CurveDrawingTool:pickSurface(point: SDK.InputPoint, fallbackY: number?): (number?, Vector3?)
	local hit = self.ctx:raycastAt(point)
	if hit then
		return hit.Distance, hit.Position
	end
	local ray = point.ray
	if math.abs(ray.Direction.Y) > 1e-6 then
		local t = ((fallbackY or 0) - ray.Origin.Y) / ray.Direction.Y
		if t > 0 then
			return t, ray.Origin + ray.Direction * t
		end
	end
	return nil, nil
end

function CurveDrawingTool:updateStatus()
	local ctx: SDK.ToolContext = self.ctx
	local drawing = self._drawing
	if drawing and drawing.dragging and drawing.mode == "freehand" then
		ctx:setStatus("Release to finish the curve.")
	elseif drawing then
		local close = if self.curveKind == "polygon" then "click the first or last point, or press Enter, to finish" else "click the last point or press Enter to finish, the first point to close the loop"
		ctx:setStatus(string.format("%d point%s: click to add points, %s. Backspace removes a point, Esc cancels.", #drawing.points, if #drawing.points == 1 then "" else "s", close))
	else
		ctx:setStatus(string.format("Drag to draw a %s freehand, or click to place its points.", self.curveKind))
	end
end

function CurveDrawingTool:activate(ctx: SDK.ToolContext)
	self._drawing = nil
	self._shown = nil :: Curve?
	self._lines = {} :: { LineHandleAdornment }
	self._markers = {} :: { SphereHandleAdornment }
	self._hover = nil :: Vector3?
	self._visibleMarkers = 0
	self._color = self.curveColor

	self:addInputBehavior(SDK.ClickOrDragInputBehavior:new({
		id = "DrawCurve",
		hitTest = function(point: SDK.InputPoint): number?
			return (self:pickSurface(point))
		end,
		onClick = function(point: SDK.InputPoint)
			self:_click(point)
		end,
		onBeginDrag = function(point: SDK.InputPoint)
			self:_beginDrag(point)
		end,
		onUpdateDrag = function(point: SDK.InputPoint)
			self:_updateDrag(point)
		end,
		onEndDrag = function(point: SDK.InputPoint)
			self:_endDrag(point)
		end,
		onCancelDrag = function()
			self:_cancelDrag()
		end,
	}))
	self:addInputBehavior(SDK.HoverInputBehavior:new({
		id = "CurveHover",
		hitTest = function(point: SDK.InputPoint): number?
			return (self:pickSurface(point))
		end,
		onUpdateHover = function(point: SDK.InputPoint)
			self:_hoverAt(point)
		end,
		onEndHover = function()
			self:_hoverAt(nil)
		end,
	}))

	ctx:onKey(function(input: InputObject, down: boolean)
		if not down or UserInputService:GetFocusedTextBox() then
			return
		end
		local key = input.KeyCode
		if key == Enum.KeyCode.Return or key == Enum.KeyCode.KeypadEnter then
			self:finishCurve()
		elseif key == Enum.KeyCode.Backspace or key == Enum.KeyCode.Delete then
			self:removeLastPoint()
		elseif key == Enum.KeyCode.C and self._hover then
			ctx:centerView(self._hover)
		end
	end)
	-- markers keep their size on screen
	ctx:connect(workspace.CurrentCamera:GetPropertyChangedSignal("CFrame"), function()
		if self._visibleMarkers > 0 then
			self:_redraw()
		end
	end)
	self:updateStatus()
end

-- Escape cancels the curve being drawn instead of exiting the tool.
function CurveDrawingTool:confirmShutdown(_reason: SDK.ShutdownReason, trigger: SDK.ShutdownTrigger): boolean
	if trigger == SDK.ShutdownTrigger.Escape and self._drawing then
		self:cancelCurve()
		return false
	end
	return true
end

-- Public helpers -----------------------------------------------------------

function CurveDrawingTool:isDrawing(): boolean
	return self._drawing ~= nil
end

-- Finishes the curve being drawn, if it has enough points (a polygon
-- needs 3). A polygon is closed, a path left open.
function CurveDrawingTool:finishCurve()
	local drawing = self._drawing
	if not drawing or drawing.dragging then
		return
	end
	if self.curveKind == "polygon" then
		if #drawing.points >= 3 then
			self:_finish(true)
		end
	else
		self:_finish(false)
	end
end

function CurveDrawingTool:cancelCurve()
	if not self._drawing then
		return
	end
	self._drawing = nil
	self:_redraw()
	self:onCurveCancelled()
	self:updateStatus()
end

function CurveDrawingTool:removeLastPoint()
	local drawing = self._drawing
	if not drawing or drawing.dragging then
		return
	end
	table.remove(drawing.points)
	table.remove(drawing.clicked)
	if #drawing.points == 0 then
		self:cancelCurve()
		return
	end
	self:_redraw()
	self:updateStatus()
end

-- Shows a finished curve (nil hides it), in place of the last one.
function CurveDrawingTool:showCurve(curve: Curve?)
	self._shown = curve
	self:_redraw()
end

function CurveDrawingTool:setCurveColor(color: Color3)
	self._color = color
	self:_redraw()
end

-- Drawing ------------------------------------------------------------------

function CurveDrawingTool:_planeY(): number?
	local drawing = self._drawing
	if not drawing then
		return nil
	end
	local y = math.huge
	for _, p in drawing.points do
		y = math.min(y, p.Y)
	end
	return y
end

-- Is a world point within snapPixels of an input point on screen?
function CurveDrawingTool:_nearOnScreen(world: Vector3, point: SDK.InputPoint): boolean
	local screen, visible = workspace.CurrentCamera:WorldToScreenPoint(world)
	return visible and (Vector2.new(screen.X, screen.Y) - point.position).Magnitude <= self.snapPixels
end

-- The surface point under an input point. While drawing, rays that miss
-- the surface meet the plane of the curve instead.
function CurveDrawingTool:_pick(point: SDK.InputPoint): Vector3?
	local _, position = self:pickSurface(point, self:_planeY())
	return position
end

function CurveDrawingTool:_start(p: Vector3, mode: string)
	self:onCurveStarted()
	self._shown = nil
	self._drawing = {
		mode = mode, -- "polyline" or "freehand"
		points = { p },
		clicked = { true }, -- which points were placed by a click (shown with markers)
		dragging = false,
	}
end

function CurveDrawingTool:_click(point: SDK.InputPoint)
	local p = self:_pick(point)
	if not p then
		return
	end
	local drawing = self._drawing
	if not drawing then
		self:_start(p, "polyline")
		self:_redraw()
		self:updateStatus()
		return
	end
	local points = drawing.points
	if #points >= 3 and self:_nearOnScreen(points[1], point) then
		self:_finish(true)
		return
	end
	if self:_nearOnScreen(points[#points], point) then
		if self.curveKind == "path" or #points >= 3 then
			self:_finish(self.curveKind == "polygon")
		end
		return
	end
	table.insert(points, p)
	table.insert(drawing.clicked, true)
	self:_redraw()
	self:updateStatus()
end

function CurveDrawingTool:_beginDrag(point: SDK.InputPoint)
	local p = self:_pick(point)
	if not p then
		return
	end
	local drawing = self._drawing
	if not drawing then
		self:_start(p, "freehand")
		drawing = self._drawing
	elseif not self:_nearOnScreen(drawing.points[#drawing.points], point) then
		table.insert(drawing.points, p)
		table.insert(drawing.clicked, true)
	end
	drawing.dragging = true
	self:_redraw()
	self:updateStatus()
end

function CurveDrawingTool:_addSample(point: SDK.InputPoint, minSpacing: number)
	local drawing = self._drawing
	local p = self:_pick(point)
	if not p then
		return
	end
	local last = drawing.points[#drawing.points]
	if Vector2.new(p.X - last.X, p.Z - last.Z).Magnitude >= minSpacing then
		table.insert(drawing.points, p)
		table.insert(drawing.clicked, false)
	end
end

function CurveDrawingTool:_updateDrag(point: SDK.InputPoint)
	local drawing = self._drawing
	if not drawing or not drawing.dragging then
		return
	end
	self:_addSample(point, self.sampleSpacing)
	self:_redraw()
end

function CurveDrawingTool:_endDrag(point: SDK.InputPoint)
	local drawing = self._drawing
	if not drawing or not drawing.dragging then
		return
	end
	self:_addSample(point, self.sampleSpacing / 2)
	drawing.dragging = false
	if drawing.mode ~= "freehand" then
		self:_redraw()
		self:updateStatus()
		return
	end
	local points = drawing.points
	if self.curveKind == "polygon" then
		if #points >= 3 then
			self:_finish(true)
		else
			self:cancelCurve()
		end
		return
	end
	-- a path closes if it ends near where it started
	local first, last = points[1], points[#points]
	local closes = #points >= 4
		and (
			self:_nearOnScreen(first, point)
			or Vector2.new(first.X - last.X, first.Z - last.Z).Magnitude <= 2 * self.sampleSpacing
		)
	self:_finish(closes)
end

function CurveDrawingTool:_cancelDrag()
	local drawing = self._drawing
	if not drawing then
		return
	end
	if drawing.mode == "freehand" then
		self:cancelCurve()
	else
		drawing.dragging = false
		self:_redraw()
		self:updateStatus()
	end
end

function CurveDrawingTool:_finish(closed: boolean)
	local drawing = self._drawing
	self._drawing = nil
	-- drop repeated points, and a last point that lands on the first of a closed curve
	local surfacePoints = {}
	for _, p in drawing.points do
		local last = surfacePoints[#surfacePoints]
		if not last or Vector2.new(p.X - last.X, p.Z - last.Z).Magnitude > 0.05 then
			table.insert(surfacePoints, p)
		end
	end
	if closed and #surfacePoints > 3 then
		local first, last = surfacePoints[1], surfacePoints[#surfacePoints]
		if Vector2.new(first.X - last.X, first.Z - last.Z).Magnitude < self.sampleSpacing / 2 then
			table.remove(surfacePoints)
		end
	end
	local points = table.create(#surfacePoints)
	local planeY = math.huge
	for i, p in surfacePoints do
		points[i] = Vector2.new(p.X, p.Z)
		planeY = math.min(planeY, p.Y)
	end
	local curve: Curve = {
		kind = self.curveKind,
		closed = closed or self.curveKind == "polygon",
		points = points,
		surfacePoints = surfacePoints,
		planeY = planeY,
		freehand = drawing.mode == "freehand",
	}
	self._shown = curve
	self:_redraw()
	self:updateStatus()
	self:onCurveFinished(curve)
end

function CurveDrawingTool:_hoverAt(point: SDK.InputPoint?)
	self._hover = if point then self:_pick(point) else nil
	local drawing = self._drawing
	if drawing then
		drawing.snap = nil
		if point and #drawing.points >= 3 and self:_nearOnScreen(drawing.points[1], point) then
			drawing.snap = "first"
		elseif point and self:_nearOnScreen(drawing.points[#drawing.points], point) then
			drawing.snap = "last"
		end
	end
	self:_redraw(true)
end

-- The marker at the surface point under the mouse.
function CurveDrawingTool:_showHoverMarker(position: Vector3?, color: Color3)
	local adornment = self._hoverMarker
	if not position then
		if adornment then
			adornment.Visible = false
		end
		return
	end
	if not adornment then
		adornment = self.ctx:createAdornment("SphereHandleAdornment") :: SphereHandleAdornment
		adornment.AlwaysOnTop = true
		adornment.ZIndex = 3
		self._hoverMarker = adornment
	end
	local distance = (position - workspace.CurrentCamera.CFrame.Position).Magnitude
	adornment.CFrame = CFrame.new(position)
	adornment.Radius = math.max(0.05, distance * MARKER_SCALE * 0.6)
	adornment.Color3 = color
	adornment.Visible = true
end

-- Display ------------------------------------------------------------------

-- Redraws the curve and the hover marker. While no curve is being drawn,
-- only the hover marker changes as the mouse moves.
function CurveDrawingTool:_redraw(hoverOnly: boolean?)
	local drawing = self._drawing
	self:_showHoverMarker(if drawing and (drawing.dragging or drawing.snap) then nil else self._hover, self._color)
	if hoverOnly and not drawing then
		return
	end
	local ctx: SDK.ToolContext = self.ctx
	local lineCount, markerCount = 0, 0
	local cameraPosition = workspace.CurrentCamera.CFrame.Position

	local function line(a: Vector3, b: Vector3, color: Color3, transparency: number, thickness: number)
		local length = (b - a).Magnitude
		if length < 1e-3 then
			return
		end
		lineCount += 1
		local adornment = self._lines[lineCount]
		if not adornment then
			adornment = ctx:createAdornment("LineHandleAdornment") :: LineHandleAdornment
			adornment.AlwaysOnTop = true
			adornment.ZIndex = 2
			self._lines[lineCount] = adornment
		end
		adornment.CFrame = CFrame.lookAt(a, b)
		adornment.Length = length
		adornment.Color3 = color
		adornment.Transparency = transparency
		adornment.Thickness = thickness
		adornment.Visible = true
	end

	local function marker(p: Vector3, color: Color3, scale: number)
		markerCount += 1
		local adornment = self._markers[markerCount]
		if not adornment then
			adornment = ctx:createAdornment("SphereHandleAdornment") :: SphereHandleAdornment
			adornment.AlwaysOnTop = true
			adornment.ZIndex = 3
			self._markers[markerCount] = adornment
		end
		adornment.CFrame = CFrame.new(p)
		adornment.Radius = math.max(0.05, (p - cameraPosition).Magnitude * MARKER_SCALE * scale)
		adornment.Color3 = color
		adornment.Visible = true
	end

	local color: Color3 = self._color
	if drawing then
		local y = self:_planeY() :: number
		local points = drawing.points
		local function flat(p: Vector3): Vector3
			return Vector3.new(p.X, y, p.Z)
		end
		for i = 2, #points do
			line(flat(points[i - 1]), flat(points[i]), color, 0, LINE_THICKNESS)
		end
		local hover = if drawing.dragging then nil else self._hover
		local last = flat(points[#points])
		if hover and not drawing.snap then
			line(last, flat(hover), color, 0.35, LINE_THICKNESS)
		end
		-- where the curve would close
		if self.curveKind == "polygon" or drawing.snap == "first" then
			local from = if hover and not drawing.snap then flat(hover) else last
			line(from, flat(points[1]), color, if drawing.snap == "first" then 0.2 else 0.65, LINE_THICKNESS)
		end
		for i, p in points do
			if drawing.clicked[i] then
				line(flat(p), p, color, 0.55, DROP_THICKNESS)
				local snapped = (i == 1 and drawing.snap == "first") or (i == #points and drawing.snap == "last")
				marker(flat(p), if snapped then Color3.new(1, 1, 1) else color, if snapped then 1.6 else 1)
			end
		end
	else
		local shown: Curve? = self._shown
		if shown then
			local y = shown.planeY
			local points = shown.points
			for i = 2, #points do
				line(Vector3.new(points[i - 1].X, y, points[i - 1].Y), Vector3.new(points[i].X, y, points[i].Y), color, 0.2, LINE_THICKNESS)
			end
			if shown.closed and #points > 2 then
				line(Vector3.new(points[#points].X, y, points[#points].Y), Vector3.new(points[1].X, y, points[1].Y), color, 0.2, LINE_THICKNESS)
			end
		end
	end

	for i = lineCount + 1, #self._lines do
		self._lines[i].Visible = false
	end
	for i = markerCount + 1, #self._markers do
		self._markers[i].Visible = false
	end
	self._visibleMarkers = markerCount
end

return CurveDrawingTool
