--[[
	ViewportStyle: the look of the system's viewport UI (the Tools Agent chat,
	the default style of ctx:createViewportPanel). Fixed dark colors, since
	this UI sits on top of the 3D scene rather than in a themed Studio panel.

	Tools use it to style the contents of their viewport panels to match;
	they're free to use their own look instead.
]]

return table.freeze({
	panel = Color3.fromRGB(37, 37, 38),
	field = Color3.fromRGB(24, 24, 25),
	button = Color3.fromRGB(70, 70, 72),
	accent = Color3.fromRGB(0, 122, 204),
	text = Color3.fromRGB(235, 235, 235),
	dimText = Color3.fromRGB(150, 150, 150),
	errorText = Color3.fromRGB(255, 110, 110),
	font = Enum.Font.SourceSans,
	boldFont = Enum.Font.SourceSansBold,
	textSize = 15,
	cornerRadius = 8,
	padding = 8,
	rowHeight = 28,
})
