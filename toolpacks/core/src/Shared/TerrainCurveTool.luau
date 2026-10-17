--[[
	TerrainCurveTool: base class for terrain edits over a drawn curve (a
	CurveDrawingTool that draws on the terrain).

	When a curve is finished, the subclass's buildEdits(curve) lists the
	SDK.Terrain edits to make, and they're applied as one undo step. The
	edit stays live until the next curve is started: changing a setting
	puts the terrain back (SDK.Terrain.restore, from the edit's snapshot)
	and applies the edits again with the new settings, as a new undo step.
	Undo or redo ends the live edit; "Apply Again" applies the last curve
	once more, on top of what's there.

	Subclasses set curveKind ("polygon" or "path"), build their settings
	with TerrainCurveTool.settingsWith(...), and override:
	  buildEdits(curve) -> { Edit }   the edits for a curve (see Edit)
	Helpers: shapeOf(curve, pathOptions?, useHeights?) and the settings maps
	in TerrainSettings.
]]

local SDK = require(script.Parent.Parent.SDK)
local CurveDrawingTool = require(script.Parent.CurveDrawingTool)
local TerrainPicking = require(script.Parent.TerrainPicking)

local Terrain = SDK.Terrain

export type Curve = CurveDrawingTool.Curve

-- One SDK.Terrain shape edit: fn(shape, options), e.g. Terrain.raise.
export type Edit = {
	fn: (SDK.TerrainShape, any) -> SDK.TerrainEditResult,
	shape: SDK.TerrainShape,
	options: { [string]: any },
}

local ADJUST_DELAY = 0.25 -- seconds after the last setting change before re-applying
local LIVE_COLOR = Color3.fromRGB(80, 220, 120)
local DONE_COLOR = Color3.fromRGB(150, 150, 150)

local TerrainCurveTool = CurveDrawingTool:extend({
	apiVersion = 1,
	section = "Terrain",
})

-- The tool's settings: its own, then the shared curve settings.
function TerrainCurveTool.settingsWith(own: { SDK.SettingSchema }, kind: string): { SDK.SettingSchema }
	local list = table.clone(own)
	table.insert(list, {
		key = "cornerRounding",
		label = "Round corners",
		type = "integer",
		default = if kind == "path" then 2 else 0,
		min = 0,
		max = 5,
		extended = { widget = "slider" },
		tooltip = "Rounds the corners of a clicked curve, more for higher values (freehand curves are only smoothed slightly).",
	})
	table.insert(list, {
		key = "applyAgain",
		label = "Apply Again",
		type = "button",
		tooltip = "Apply the last curve's edit once more, on top of the terrain as it is now.",
	})
	table.insert(list, {
		key = "help",
		label = if kind == "path"
			then "Drag to draw a path, or click its points: click the last point (or Enter) to finish, the first one to close a loop. Backspace: remove a point · Esc: cancel · C: center the view. Settings changed afterwards adjust the last edit."
			else "Drag to draw a polygon, or click its points: click the first or last point (or Enter) to finish. Backspace: remove a point · Esc: cancel · C: center the view. Settings changed afterwards adjust the last edit.",
		type = "label",
	})
	return list
end

function TerrainCurveTool:buildEdits(_curve: Curve): { Edit }
	error(string.format("tool '%s' must implement buildEdits()", tostring(self.id)), 2)
end

-- An SDK.Terrain shape for the curve: a polygon, or a path with
-- pathOptions. Clicked curves get their corners rounded per the
-- cornerRounding setting, freehand ones are smoothed lightly. With
-- useHeights the points keep the heights they were drawn at (e.g. for a
-- water level along a path); otherwise the shape is 2D.
function TerrainCurveTool:shapeOf(curve: Curve, pathOptions: SDK.TerrainPathOptions?, useHeights: boolean?): SDK.TerrainShape
	local closed = curve.closed
	local points: { Vector3 } = curve.surfacePoints
	local iterations = if curve.freehand then 1 else self.ctx.settings.cornerRounding or 0
	if iterations > 0 and #points > 2 then
		points = Terrain.smoothPath(points, { closed = closed, iterations = iterations })
	end
	local list: { any } = points
	if not useHeights then
		list = table.create(#points)
		for i, p in points do
			list[i] = Vector2.new(p.X, p.Z)
		end
	end
	if curve.kind == "polygon" then
		return Terrain.polygon(list)
	end
	local options: SDK.TerrainPathOptions = table.clone(pathOptions or {})
	options.closed = closed
	return Terrain.path(list, options)
end

function TerrainCurveTool:pickSurface(point: SDK.InputPoint, fallbackY: number?): (number?, Vector3?)
	local t, position = TerrainPicking.pick(point, fallbackY)
	return t, position
end

function TerrainCurveTool:activate(ctx: SDK.ToolContext)
	self.closed = false
	self.live = nil -- { curve, snapshots }: the edit that settings adjust
	self.lastCurve = nil :: Curve?
	self.message = nil :: string?
	self.adjustGeneration = 0
	CurveDrawingTool.activate(self, ctx)

	ctx:onSettingChanged(function()
		if self.live then
			self:_scheduleAdjust()
		end
	end)
	ctx:onUndoRedo(function(action: SDK.UndoAction)
		if self.live then
			self.live = nil
			self.adjustGeneration += 1
			self:setCurveColor(DONE_COLOR)
			self.message = if action == "Undo"
				then "Undone. Draw a new curve, or use Apply Again to apply the last one again."
				else "Redone. Draw a new curve, or use Apply Again."
		end
		self:updateStatus()
	end)
	ctx:setSettingState("applyAgain", { enabled = false })
end

function TerrainCurveTool:deactivate(_ctx: SDK.ToolContext, _reason: SDK.ShutdownReason)
	self.closed = true
end

function TerrainCurveTool:onAction(key: string)
	if key == "applyAgain" and self.lastCurve and not self:isDrawing() then
		self:_apply(self.lastCurve, false)
	end
end

function TerrainCurveTool:onCurveStarted()
	-- the last edit stays as it is
	self.live = nil
	self.adjustGeneration += 1
	self.message = nil
	self:setCurveColor(self.curveColor)
end

function TerrainCurveTool:onCurveFinished(curve: Curve)
	self.lastCurve = curve
	self.ctx:setSettingState("applyAgain", { enabled = true })
	self:_apply(curve, false)
end

function TerrainCurveTool:updateStatus()
	if self.message and not self:isDrawing() then
		self.ctx:setStatus(self.message)
	else
		CurveDrawingTool.updateStatus(self)
	end
end

function TerrainCurveTool:_scheduleAdjust()
	self.adjustGeneration += 1
	local generation = self.adjustGeneration
	task.delay(ADJUST_DELAY, function()
		if self.closed or generation ~= self.adjustGeneration or not self.live or self:isDrawing() then
			return
		end
		self:_apply(self.live.curve, true)
	end)
end

-- Applies the curve's edits as one undo step. With adjust, the live edit
-- is put back first, so the new edit replaces it.
function TerrainCurveTool:_apply(curve: Curve, adjust: boolean)
	local ctx: SDK.ToolContext = self.ctx
	local ok, edits = pcall(self.buildEdits, self, curve)
	if not ok then
		self.message = "Couldn't edit the terrain: " .. (tostring(edits):gsub("^.-:%d+: ", ""))
		self:updateStatus()
		return
	end
	local previous = if adjust and self.live then self.live.snapshots else nil
	local snapshots: { SDK.TerrainSnapshot } = {}
	local columns = 0
	local started = os.clock()
	local applied, err = ctx:recordUndo(self.name, function()
		if previous then
			for i = #previous, 1, -1 do
				Terrain.restore(previous[i])
			end
		end
		for _, edit in edits do
			local options = table.clone(edit.options)
			options.snapshot = true
			local result = edit.fn(edit.shape, options)
			columns = math.max(columns, result.columns)
			if result.snapshot then
				table.insert(snapshots, result.snapshot)
			end
		end
	end)
	if not applied then
		-- the recording was cancelled, so the terrain (and a live edit) is as it was
		local reason = (tostring(err):match("^[^\n]*") or ""):gsub("^.-:%d+: ", "")
		self.message = "Couldn't edit the terrain: " .. reason
		self:updateStatus()
		return
	end
	self.live = { curve = curve, snapshots = snapshots }
	self:setCurveColor(LIVE_COLOR)
	self.message = string.format(
		"%s %d column%s (%.2f s). Change settings to adjust it; draw again to start a new one.",
		if adjust then "Adjusted:" else "Edited",
		columns,
		if columns == 1 then "" else "s",
		os.clock() - started
	)
	self:updateStatus()
end

return TerrainCurveTool
