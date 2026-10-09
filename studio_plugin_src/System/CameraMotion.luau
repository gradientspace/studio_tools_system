--[[
	CameraMotion: animated camera moves for the system and for tools
	(ctx:focusView / ctx:centerView).

	  frame(cframe, size)   move along the current view direction until the
	                        box (center/orientation + size) fills the view
	  center(point)         pan (no rotation or zoom) so the point is at the
	                        center of the view

	Both ease in and out over a short time and finish by making the target
	the camera's Focus, which Studio's camera orbits around. Only one move
	runs at a time; a new one starts from wherever the camera is.
]]

local RunService = game:GetService("RunService")

local DURATION = 0.3 -- seconds
local MARGIN = 1.08 -- frame(): room around the box (1 = touching the view edges)

local CameraMotion = {}

local currentToken = 0

-- Eases the camera to `target`, then sets its Focus to `focus`.
local function animate(target: CFrame, focus: Vector3)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	currentToken += 1
	local token = currentToken
	local from = camera.CFrame
	local started = os.clock()
	local connection: RBXScriptConnection
	connection = RunService.RenderStepped:Connect(function()
		if token ~= currentToken then
			connection:Disconnect()
			return
		end
		local alpha = math.min((os.clock() - started) / DURATION, 1)
		local eased = alpha * alpha * (3 - 2 * alpha) -- smoothstep: no jump at the start or stop at the end
		camera.CFrame = from:Lerp(target, eased)
		if alpha >= 1 then
			connection:Disconnect()
			camera.Focus = CFrame.new(focus)
		end
	end)
end

function CameraMotion.frame(cframe: CFrame, size: Vector3)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local center = cframe.Position
	local viewport = camera.ViewportSize
	local tanVertical = math.tan(math.rad(camera.FieldOfView) / 2) / MARGIN
	local aspect = if viewport.Y > 0 then viewport.X / viewport.Y else 1
	local tanHorizontal = tanVertical * aspect

	local from = camera.CFrame
	local look, right, up = from.LookVector, from.RightVector, from.UpVector
	-- The closest camera distance (along the current view direction) at which
	-- all eight corners of the box are inside the view.
	local distance = 0
	local half = size / 2
	for _, sx in { -1, 1 } do
		for _, sy in { -1, 1 } do
			for _, sz in { -1, 1 } do
				local offset = cframe:VectorToWorldSpace(Vector3.new(sx * half.X, sy * half.Y, sz * half.Z))
				local forward = offset:Dot(look) -- how much farther from the camera than the center
				distance = math.max(
					distance,
					math.abs(offset:Dot(right)) / tanHorizontal - forward,
					math.abs(offset:Dot(up)) / tanVertical - forward,
					0.1 - forward -- stay in front of the corner
				)
			end
		end
	end
	distance = math.max(distance, 0.5)
	animate(CFrame.lookAt(center - look * distance, center, up), center)
end

function CameraMotion.center(point: Vector3)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local from = camera.CFrame
	local depth = (point - from.Position):Dot(from.LookVector)
	animate(from.Rotation + (point - from.LookVector * depth), point)
end

return CameraMotion
