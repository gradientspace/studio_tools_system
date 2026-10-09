--[[
	Thin wrapper over the Studio theme so UI code reads a little nicer:
	Theme.color("MainBackground"), Theme.color("Button", "Selected").
]]

local Theme = {}

Theme.FONT = Enum.Font.SourceSans
Theme.FONT_BOLD = Enum.Font.SourceSansBold
Theme.TEXT_SIZE = 15
Theme.ROW_HEIGHT = 26
-- Accent for selected/primary controls; the same blue as the chat's Send button.
Theme.ACCENT = Color3.fromRGB(0, 122, 204)

local warned = {}

-- Falls back to gray (with one warning) if the color name isn't known to
-- this Studio version, rather than breaking the whole palette.
function Theme.color(name: string, modifier: string?): Color3
	local ok, color = pcall(function()
		return settings().Studio.Theme:GetColor(
			(Enum.StudioStyleGuideColor :: any)[name],
			(Enum.StudioStyleGuideModifier :: any)[modifier or "Default"]
		)
	end)
	if ok then
		return color
	end
	local key = name .. "/" .. (modifier or "Default")
	if not warned[key] then
		warned[key] = true
		warn(string.format("[StudioTools] Unknown theme color %s: %s", key, tostring(color)))
	end
	return Color3.fromRGB(128, 128, 128)
end

local function difference(a: Color3, b: Color3): number
	return math.abs(a.R - b.R) + math.abs(a.G - b.G) + math.abs(a.B - b.B)
end

-- Fill for ordinary buttons, matching Studio's own panels (e.g. the
-- Toolbox's category buttons): flat grey, no border. That's the theme's
-- Button color, except where Button is the same as the panel background
-- (the Light theme's is white), which falls back to Midlight.
function Theme.buttonFill(): Color3
	local fill = Theme.color("Button")
	if difference(fill, Theme.color("MainBackground")) < 0.06 then
		return Theme.color("Midlight")
	end
	return fill
end

-- A hover or pressed shade of a fill: moved toward the text color, so it
-- darkens in light themes and lightens in dark ones. amount is 0..1.
function Theme.shade(color: Color3, amount: number): Color3
	return color:Lerp(Theme.color("MainText"), amount)
end

function Theme.onChanged(fn: () -> ()): RBXScriptConnection
	return settings().Studio.ThemeChanged:Connect(fn)
end

return Theme
