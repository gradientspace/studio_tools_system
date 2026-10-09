--[[
	Move: click and drag a part to slide it horizontally (XZ). Hold Shift to
	move it vertically (Y) instead. Shift can be pressed or released mid-drag.

	The drag works by intersecting the mouse ray with a plane through the
	grab point: a horizontal plane for XZ moves, or a vertical plane facing
	the camera for Y moves. The part is offset by how far that intersection
	point has moved from where the drag (or the current mode) started.

	Extends PartPickerTool, replacing its click with a ClickDragInputBehavior.
	Shift going up or down is an input update, so the drag switches modes
	without the mouse moving.
]]

local SDK = require(script.Parent.Parent.SDK)
local PartPickerTool = require(script.Parent.Parent.Shared.PartPickerTool)

local MoveBlock = PartPickerTool:extend({
	apiVersion = 1,
	id = "MoveBlock",
	version = "1.1.0",
	name = "Move",
	description = "Drag a part to move it in XZ. Hold Shift while dragging to move it vertically. Locked parts are skipped.",
	order = 40,
	highlightColor = Color3.fromRGB(255, 200, 0),
	settings = {
		{ key = "snap", label = "Snap Increment", type = "number", default = 0, min = 0, max = 64, step = 0.25 },
	},
})

local function intersectRayPlane(ray: Ray, planePoint: Vector3, planeNormal: Vector3): Vector3?
	local denom = ray.Direction:Dot(planeNormal)
	if math.abs(denom) < 1e-4 then
		return nil -- ray is (nearly) parallel to the plane
	end
	local t = (planePoint - ray.Origin):Dot(planeNormal) / denom
	if t < 0 then
		return nil -- plane is behind the camera
	end
	return ray.Origin + ray.Direction * t
end

-- Normal of a vertical plane that faces the camera as directly as possible.
local function verticalPlaneNormal(): Vector3
	local cameraCFrame = workspace.CurrentCamera.CFrame
	local flat = cameraCFrame.LookVector * Vector3.new(1, 0, 1)
	if flat.Magnitude < 1e-3 then
		-- Looking straight up/down: the camera's up vector is horizontal.
		flat = cameraCFrame.UpVector * Vector3.new(1, 0, 1)
	end
	return flat.Unit
end

local function snapValue(value: number, increment: number): number
	if increment <= 0 then
		return value
	end
	return math.round(value / increment) * increment
end

-- self.drag, while dragging:
--   part           the part being moved
--   vertical       current mode (true = Y, false = XZ)
--   anchorPoint    world point on the drag plane where the current mode started
--   anchorCFrame   the part's CFrame when the current mode started
--   planeNormal
--   undo

-- (Re)starts the current drag mode from the part's present position, so
-- toggling Shift mid-drag doesn't make the part jump.
function MoveBlock:beginMode(grabPoint: Vector3, vertical: boolean)
	local drag = self.drag
	drag.vertical = vertical
	drag.anchorPoint = grabPoint
	drag.anchorCFrame = drag.part.CFrame
	drag.planeNormal = if vertical then verticalPlaneNormal() else Vector3.yAxis
end

function MoveBlock:beginDrag(point: SDK.InputPoint, vertical: boolean)
	self:endDrag()
	local part, hit = self:getTarget(point)
	if not part or not hit then
		return
	end
	self.drag = { part = part, undo = self.ctx:beginUndo("Move Part") }
	self:beginMode(hit.Position, vertical)
	self:setHighlight(part)
end

function MoveBlock:updateDrag(point: SDK.InputPoint, vertical: boolean)
	local drag = self.drag
	if not drag then
		return
	end
	if drag.part.Parent == nil then
		-- Deleted out from under us (e.g. undo); abandon the drag.
		self:endDrag()
		return
	end
	if vertical ~= drag.vertical then
		-- The grab point has moved along with the part since the mode began.
		local moved = drag.part.Position - drag.anchorCFrame.Position
		self:beginMode(drag.anchorPoint + moved, vertical)
	end

	local hitPoint = intersectRayPlane(point.ray, drag.anchorPoint, drag.planeNormal)
	if not hitPoint then
		return
	end
	local delta = hitPoint - drag.anchorPoint
	local snap = self.ctx.settings.snap
	if drag.vertical then
		delta = Vector3.new(0, snapValue(delta.Y, snap), 0)
	else
		delta = Vector3.new(snapValue(delta.X, snap), 0, snapValue(delta.Z, snap))
	end
	drag.part.CFrame = drag.anchorCFrame + delta
end

function MoveBlock:endDrag()
	if self.drag then
		self.drag.undo.commit()
		self.drag = nil
	end
end

function MoveBlock:createPickBehavior(): SDK.InputBehavior
	-- With no onCancelDrag, a drag that's cut short (e.g. the tool is
	-- shut down mid-drag) ends normally, keeping the move.
	return SDK.ClickDragInputBehavior:new({
		id = "Drag",
		hitTest = function(point)
			return self:hitTest(point)
		end,
		onBeginDrag = function(point, modifiers)
			self:beginDrag(point, modifiers.shift)
		end,
		onUpdateDrag = function(point, modifiers)
			self:updateDrag(point, modifiers.shift)
		end,
		onEndDrag = function()
			self:endDrag()
		end,
	})
end

return MoveBlock
