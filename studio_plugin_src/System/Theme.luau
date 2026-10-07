--[[
	Thin wrapper over the Studio theme so UI code reads a little nicer:
	Theme.color("MainBackground"), Theme.color("Button", "Selected").
]]

local Theme = {}

Theme.FONT = Enum.Font.SourceSans
Theme.FONT_BOLD = Enum.Font.SourceSansBold
Theme.TEXT_SIZE = 15
Theme.ROW_HEIGHT = 26

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

function Theme.onChanged(fn: () -> ()): RBXScriptConnection
	return settings().Studio.ThemeChanged:Connect(fn)
end

return Theme
