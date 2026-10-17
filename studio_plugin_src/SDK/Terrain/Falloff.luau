--[[
	Falloff: the profiles that turn a shape's ramp (t from 0 at the outer
	edge to 1 at the inner edge) into a weight, the smooth min/max used by
	the blend modes, and a Gaussian blur over column grids.
]]

local Falloff = {}

local PROFILES: { [string]: (number) -> number } = {
	linear = function(t)
		return t
	end,
	-- linear too; the smoothing is applied to the distance field (Shapes)
	smooth = function(t)
		return t
	end,
	square = function(t)
		return t * t
	end,
	sqrt = function(t)
		return math.sqrt(t)
	end,
	smoothstep = function(t)
		return t * t * (3 - 2 * t)
	end,
	round = function(t)
		local s = 1 - t
		return math.sqrt(math.max(0, 1 - s * s))
	end,
	constant = function(t)
		return if t > 0 then 1 else 0
	end,
}

-- The weight function for a profile name or function (default linear).
function Falloff.profile(profile: any): (number) -> number
	if profile == nil then
		return PROFILES.linear
	elseif type(profile) == "function" then
		return function(t)
			return math.clamp(profile(t), 0, 1)
		end
	end
	local fn = PROFILES[profile]
	if not fn then
		error(`unknown falloff '{tostring(profile)}'`, 3)
	end
	return fn
end

-- Polynomial smooth minimum: min(a, b), rounded where they're within k.
function Falloff.smoothMin(a: number, b: number, k: number): number
	if k <= 0 then
		return math.min(a, b)
	end
	local h = math.max(k - math.abs(a - b), 0) / k
	return math.min(a, b) - h * h * k * 0.25
end

function Falloff.smoothMax(a: number, b: number, k: number): number
	return -Falloff.smoothMin(-a, -b, k)
end

-- Gaussian blur (standard deviation sigma, in cells) of a grid of nx by nz
-- values stored row by row (index (iz - 1) * nx + ix). nil entries are
-- left out: each result is the weighted mean of the values around it, or
-- nil where there are none.
function Falloff.blur(values: { number? }, nx: number, nz: number, sigma: number): { number? }
	if sigma <= 0 then
		return table.clone(values)
	end
	local radius = math.max(1, math.ceil(3 * sigma))
	local kernel = table.create(radius + 1, 0)
	for d = 0, radius do
		kernel[d + 1] = math.exp(-0.5 * (d / sigma) ^ 2)
	end
	local count = nx * nz
	local rowSum = table.create(count, 0)
	local rowWeight = table.create(count, 0)
	for iz = 1, nz do
		local base = (iz - 1) * nx
		for ix = 1, nx do
			local s, w = 0, 0
			for jx = math.max(1, ix - radius), math.min(nx, ix + radius) do
				local v = values[base + jx]
				if v then
					local kw = kernel[math.abs(jx - ix) + 1]
					s += kw * v
					w += kw
				end
			end
			rowSum[base + ix] = s
			rowWeight[base + ix] = w
		end
	end
	local result = table.create(count)
	for iz = 1, nz do
		for ix = 1, nx do
			local s, w = 0, 0
			for jz = math.max(1, iz - radius), math.min(nz, iz + radius) do
				local kw = kernel[math.abs(jz - iz) + 1]
				local j = (jz - 1) * nx + ix
				s += kw * rowSum[j]
				w += kw * rowWeight[j]
			end
			if w > 1e-9 then
				result[(iz - 1) * nx + ix] = s / w
			end
		end
	end
	return result
end

return Falloff
