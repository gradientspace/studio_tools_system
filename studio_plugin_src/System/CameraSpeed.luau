--[[
	CameraSpeed: sets Studio's camera speeds to suit an object's size, for
	ctx:autoCameraSpeed, and puts the user's own values back afterwards.

	The speeds are user preferences (settings().Studio), shared by every
	place and kept across sessions, so a change must never outlive the tool
	that made it. While changed, the original values are also kept in a
	plugin setting, and recover() (called when the system starts) puts them
	back if Studio closed or the plugin crashed before the tool could.

	Tuning: speeds scale linearly with the bounds' diagonal. At the reference
	size (a 6-stud ball, diagonal ~10.4) fly speed is ~0.47 and the wheel step
	~3.
]]

local CameraSpeed = {}

local SAVED_SETTING = "StudioTools.SavedCameraSpeeds"

-- Studio setting name -> value per stud of bounds diagonal, and clamp range.
local SCALED = {
	["Camera Speed"] = { perStud = 0.045, min = 0.02, max = 20 },
	["Camera Mouse Wheel Speed"] = { perStud = 0.29, min = 0.2, max = 100 },
}
-- Scaled by the same factor as "Camera Speed", keeping its ratio to it.
local SHIFT_SPEED = "Camera Shift Speed"

export type Snapshot = { [string]: number }

local function read(name: string): number?
	local ok, value = pcall(function()
		return (settings() :: any).Studio[name]
	end)
	return if ok and type(value) == "number" then value else nil
end

local function write(name: string, value: number)
	pcall(function()
		(settings() :: any).Studio[name] = value
	end)
end

-- The current values of every setting this module may change.
function CameraSpeed.snapshot(): Snapshot
	local snapshot = {}
	for name in SCALED do
		snapshot[name] = read(name)
	end
	snapshot[SHIFT_SPEED] = read(SHIFT_SPEED)
	return snapshot
end

-- Sets the speeds for an object of this size. `original` is the snapshot
-- taken before any change; it's persisted so recover() can undo a change a
-- crash left behind.
function CameraSpeed.apply(plugin: Plugin, original: Snapshot, size: Vector3)
	pcall(plugin.SetSetting, plugin, SAVED_SETTING, original)
	local diagonal = math.max(size.Magnitude, 0.01)
	for name, rule in SCALED do
		write(name, math.clamp(diagonal * rule.perStud, rule.min, rule.max))
	end
	local speed, originalSpeed, originalShift = read("Camera Speed"), original["Camera Speed"], original[SHIFT_SPEED]
	if speed and originalSpeed and originalShift and originalSpeed > 0 then
		write(SHIFT_SPEED, originalShift * speed / originalSpeed)
	end
end

-- Puts a snapshot's values back and forgets the persisted copy.
function CameraSpeed.restore(plugin: Plugin, original: Snapshot)
	for name, value in original do
		write(name, value)
	end
	pcall(plugin.SetSetting, plugin, SAVED_SETTING, nil)
end

-- At startup: restore speeds a previous session changed and never put back.
function CameraSpeed.recover(plugin: Plugin)
	local ok, saved = pcall(plugin.GetSetting, plugin, SAVED_SETTING)
	if ok and type(saved) == "table" then
		local snapshot = {}
		for name, value in saved do
			if type(name) == "string" and type(value) == "number" then
				snapshot[name] = value
			end
		end
		CameraSpeed.restore(plugin, snapshot)
	end
end

return CameraSpeed
