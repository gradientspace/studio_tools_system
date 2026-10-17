--[[
	TerrainBrushTool: base class for brushes that edit the terrain under the
	mouse. It shows a ring cursor draped over the terrain, and runs strokes:
	a press on the terrain (or, where there's none, on the ground plane)
	starts one, and every frame until the release the subclass applies the
	brush along the stretch the cursor passed over since the last frame
	(or at the cursor, if it's held still). A stroke is one undo step.

	Subclasses have a `radius` setting (studs; [ and ] change it) and override:
	  applyStroke(stroke, centers, dt, modifiers)
	                           required; apply the brush at these points (at
	                           least one; spaced a quarter radius apart along
	                           the mouse path) for a frame of dt seconds.
	                           dt is 0 for the final call at the release.
	  beginStroke(stroke, modifiers) -> boolean?
	                           optional; return false to not start the stroke
	                           (e.g. Ctrl+click picks something instead)
	  cursorColor(modifiers)   optional; the ring's color
	and call TerrainBrushTool.activate(self, ctx) if they override activate.
	A stroke is { start, current: Vector3, ... }: where it started and where
	the brush is; subclasses may keep their own fields in it.

	Since this lives in Shared/ rather than Tools/, it isn't listed as a tool.
]]

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local SDK = require(script.Parent.Parent.SDK)
local TerrainPicking = require(script.Parent.TerrainPicking)
local TerrainBrushRing = require(script.Parent.TerrainBrushRing)

local SIZE_KEY_FACTOR = 1.15
local SPACING = 0.25 -- of the radius, between brush positions along the mouse path
local MAX_CENTERS = 64 -- per frame
local MAX_DT = 0.1

local TerrainBrushTool = SDK.Tool:extend({
	apiVersion = 1,
	section = "Terrain",
})

function TerrainBrushTool:applyStroke(_stroke: any, _centers: { Vector3 }, _dt: number, _modifiers: SDK.Modifiers)
	error(string.format("tool '%s' must implement applyStroke()", tostring(self.id)), 2)
end

function TerrainBrushTool:beginStroke(_stroke: any, _modifiers: SDK.Modifiers): boolean?
	return true
end

function TerrainBrushTool:cursorColor(_modifiers: SDK.Modifiers): Color3
	return Color3.fromRGB(0, 170, 255)
end

function TerrainBrushTool:activate(ctx: SDK.ToolContext)
	self.closed = false
	self.stroke = nil
	self.hover = nil :: Vector3?
	self.ring = TerrainBrushRing.new(ctx)

	self:addInputBehavior(SDK.ClickDragInputBehavior:new({
		id = "BrushStroke",
		hitTest = function(point: SDK.InputPoint): number?
			return (TerrainPicking.pick(point))
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
		id = "BrushCursor",
		hitTest = function(point: SDK.InputPoint): number?
			return (TerrainPicking.pick(point))
		end,
		onUpdateHover = function(point: SDK.InputPoint, modifiers: SDK.Modifiers)
			local _, position = TerrainPicking.pick(point)
			self.hover = position
			self.hoverModifiers = modifiers
			self:_showRing()
		end,
		onEndHover = function()
			self.hover = nil
			if not self.stroke then
				self.ring:hide()
			end
		end,
	}))

	ctx:connect(RunService.Heartbeat, function(dt: number)
		if self.stroke then
			self:_step(math.min(dt, MAX_DT))
		end
	end)
	ctx:onKey(function(input: InputObject, down: boolean)
		if not down or UserInputService:GetFocusedTextBox() then
			return
		end
		if input.KeyCode == Enum.KeyCode.LeftBracket then
			ctx:setSetting("radius", ctx.settings.radius / SIZE_KEY_FACTOR)
		elseif input.KeyCode == Enum.KeyCode.RightBracket then
			ctx:setSetting("radius", ctx.settings.radius * SIZE_KEY_FACTOR)
		elseif input.KeyCode == Enum.KeyCode.C and self.hover then
			ctx:centerView(self.hover)
		end
	end)
	ctx:onSettingChanged(function(key: string)
		if key == "radius" then
			self:_showRing()
		end
	end)
end

function TerrainBrushTool:deactivate(_ctx: SDK.ToolContext, _reason: SDK.ShutdownReason)
	self:_endStroke()
	self.closed = true
end

function TerrainBrushTool:_showRing()
	local stroke = self.stroke
	local center = if stroke then stroke.current else self.hover
	if not center then
		self.ring:hide()
		return
	end
	local modifiers = if stroke then stroke.modifiers else self.hoverModifiers
	self.ring:show(center, self.ctx.settings.radius, self:cursorColor(modifiers or {}))
end

function TerrainBrushTool:_beginStroke(point: SDK.InputPoint, modifiers: SDK.Modifiers)
	local _, position = TerrainPicking.pick(point)
	if not position or self.closed then
		return
	end
	local stroke = {
		start = position,
		current = position,
		pending = { position },
		modifiers = modifiers,
		ray = point.ray,
	}
	if self:beginStroke(stroke, modifiers) == false then
		return
	end
	stroke.recording = self.ctx:beginUndo(self.name)
	self.stroke = stroke
	self:_showRing()
end

function TerrainBrushTool:_updateStroke(point: SDK.InputPoint, modifiers: SDK.Modifiers)
	local stroke = self.stroke
	if not stroke then
		return
	end
	stroke.modifiers = modifiers
	local ray = point.ray
	-- a held mouse keeps its spot, even as the terrain under it rises or sinks
	if ray.Origin ~= stroke.ray.Origin or ray.Direction ~= stroke.ray.Direction then
		stroke.ray = ray
		local _, position = TerrainPicking.pick(point, stroke.current.Y)
		if position then
			local spacing = math.max(self.ctx.settings.radius * SPACING, 0.5)
			local from = stroke.current
			local distance = Vector2.new(position.X - from.X, position.Z - from.Z).Magnitude
			local steps = math.min(math.floor(distance / spacing), MAX_CENTERS)
			for i = 1, steps do
				table.insert(stroke.pending, from:Lerp(position, i / (steps + 1)))
			end
			table.insert(stroke.pending, position)
			stroke.current = position
		end
	end
	self:_showRing()
end

function TerrainBrushTool:_step(dt: number)
	local stroke = self.stroke
	local centers = stroke.pending
	if #centers == 0 then
		centers = { stroke.current }
	end
	stroke.pending = {}
	local ok, err = pcall(self.applyStroke, self, stroke, centers, dt, stroke.modifiers)
	if not ok then
		self.ctx:setStatus("Brush failed: " .. (tostring(err):gsub("^.-:%d+: ", "")))
		self:_endStroke()
	end
end

function TerrainBrushTool:_endStroke()
	local stroke = self.stroke
	if not stroke then
		return
	end
	if #stroke.pending > 0 and not self.closed then
		self:_step(0)
	end
	self.stroke = nil
	stroke.recording.commit()
	if not self.hover then
		self.ring:hide()
	end
end

return TerrainBrushTool
