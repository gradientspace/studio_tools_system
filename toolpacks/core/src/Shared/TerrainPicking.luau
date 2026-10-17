--[[
	TerrainPicking: where an input point's ray meets the terrain surface,
	for terrain tools. Only Terrain is hit (parts in front are ignored),
	and water is seen through. Where the ray misses the terrain (an empty
	place, the sky above a slope), it falls back to the horizontal plane at
	GROUND_Y, the height SDK.Terrain treats empty columns as having, so
	terrain can be built up from nothing.
]]

local SDK = require(script.Parent.Parent.SDK)

local TerrainPicking = {}

TerrainPicking.GROUND_Y = 0
local MAX_DISTANCE = 20000

local params: RaycastParams? = nil

local function terrainParams(): RaycastParams
	if not params then
		local p = RaycastParams.new()
		p.FilterType = Enum.RaycastFilterType.Include
		p.FilterDescendantsInstances = { workspace.Terrain }
		p.IgnoreWater = true
		params = p
	end
	return params :: RaycastParams
end

-- The terrain hit along a ray: the distance, position, normal and
-- material. Nil if it misses the terrain.
function TerrainPicking.raycast(origin: Vector3, direction: Vector3, maxDistance: number?): RaycastResult?
	return workspace:Raycast(origin, direction.Unit * (maxDistance or MAX_DISTANCE), terrainParams())
end

-- Where a ray meets the horizontal plane at height y (in front of it).
function TerrainPicking.planeHit(ray: Ray, y: number): (number?, Vector3?)
	local dy = ray.Direction.Y
	if math.abs(dy) < 1e-6 then
		return nil, nil
	end
	local t = (y - ray.Origin.Y) / dy
	if t <= 0 or t > MAX_DISTANCE then
		return nil, nil
	end
	return t, ray.Origin + ray.Direction * t
end

-- The surface under an input point: distance along the ray, position,
-- normal, and the terrain hit (nil where it fell back to a plane at
-- fallbackY, default GROUND_Y).
function TerrainPicking.pick(point: SDK.InputPoint, fallbackY: number?): (number?, Vector3?, Vector3?, RaycastResult?)
	local ray = point.ray
	local hit = TerrainPicking.raycast(ray.Origin, ray.Direction)
	if hit then
		return hit.Distance, hit.Position, hit.Normal, hit
	end
	local t, position = TerrainPicking.planeHit(ray, fallbackY or TerrainPicking.GROUND_Y)
	if t then
		return t, position, Vector3.yAxis, nil
	end
	return nil, nil, nil, nil
end

-- The surface height at (x, z) by a vertical raycast from `above`, or nil.
function TerrainPicking.heightAt(x: number, z: number, above: number, depth: number): number?
	local hit = TerrainPicking.raycast(Vector3.new(x, above, z), Vector3.new(0, -1, 0), depth)
	return hit and hit.Position.Y
end

return TerrainPicking
