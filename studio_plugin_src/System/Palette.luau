--[[
	Palette: the dock widget UI. Two modes:
	  * no tool active: a tab bar (one tab per pack `tab` name, see
	    ToolManager) and the selected tab's tool buttons, with a heading per
	    pack when a tab holds more than one pack
	  * tool active: just the tool's name and its settings (the tool is
	    exited with the shutdown overlay's buttons in the viewport) The whole thing is re-rendered
	whenever the ToolManager or Studio theme changes; it's small enough that
	this is simpler than diffing.
]]

local SDK = require(script.Parent.Parent.SDK)
local Theme = require(script.Parent.Theme)

local SELECTED_TAB_SETTING = "StudioToolsSystem.SelectedTab"
local DROPDOWN_MAX_HEIGHT = 240

local DEFAULT_COLOR_PRESETS = {
	Color3.fromRGB(242, 243, 243),
	Color3.fromRGB(163, 162, 165),
	Color3.fromRGB(27, 42, 53),
	Color3.fromRGB(196, 40, 28),
	Color3.fromRGB(218, 133, 65),
	Color3.fromRGB(245, 205, 48),
	Color3.fromRGB(75, 151, 75),
	Color3.fromRGB(13, 105, 172),
	Color3.fromRGB(107, 50, 124),
	Color3.fromRGB(124, 92, 70),
}

local Palette = {}
Palette.__index = Palette

local function create(className: string, props: { [string]: any }, children: { Instance }?): any
	local instance = Instance.new(className)
	for key, value in props do
		if key ~= "Parent" then
			(instance :: any)[key] = value
		end
	end
	if children then
		for _, child in children do
			child.Parent = instance
		end
	end
	if props.Parent then
		instance.Parent = props.Parent
	end
	return instance
end

local function label(text: string, props: { [string]: any }?): TextLabel
	local base = {
		BackgroundTransparency = 1,
		Font = Theme.FONT,
		TextSize = Theme.TEXT_SIZE,
		TextColor3 = Theme.color("MainText"),
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, Theme.ROW_HEIGHT),
		Text = text,
	}
	if props then
		for key, value in props do
			base[key] = value
		end
	end
	return create("TextLabel", base)
end

local function button(text: string, selected: boolean?, props: { [string]: any }?, children: { Instance }?): TextButton
	local base = {
		AutoButtonColor = true,
		BorderSizePixel = 1,
		BorderColor3 = Theme.color("ButtonBorder"),
		BackgroundColor3 = Theme.color("Button", if selected then "Selected" else "Default"),
		Font = Theme.FONT,
		TextSize = Theme.TEXT_SIZE,
		TextColor3 = Theme.color("ButtonText", if selected then "Selected" else "Default"),
		Size = UDim2.new(1, 0, 0, Theme.ROW_HEIGHT),
		Text = text,
	}
	if props then
		for key, value in props do
			base[key] = value
		end
	end
	return create("TextButton", base, children)
end

local function textBox(text: string, props: { [string]: any }?): TextBox
	local base = {
		BorderSizePixel = 1,
		BorderColor3 = Theme.color("InputFieldBorder"),
		BackgroundColor3 = Theme.color("InputFieldBackground"),
		Font = Theme.FONT,
		TextSize = Theme.TEXT_SIZE,
		TextColor3 = Theme.color("MainText"),
		ClearTextOnFocus = false,
		Size = UDim2.new(1, 0, 0, Theme.ROW_HEIGHT),
		Text = text,
	}
	if props then
		for key, value in props do
			base[key] = value
		end
	end
	return create("TextBox", base)
end

-- A small downward chevron (10x5) drawn from two rotated bars, since the
-- Studio UI fonts have no arrow glyphs.
local function chevron(color: Color3, props: { [string]: any }): Frame
	local base = { BackgroundTransparency = 1, Size = UDim2.fromOffset(10, 5) }
	for key, value in props do
		base[key] = value
	end
	local function bar(x: number, rotation: number): Frame
		return create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(x, 2.5),
			Size = UDim2.fromOffset(7.5, 1.5),
			Rotation = rotation,
			BackgroundColor3 = color,
			BorderSizePixel = 0,
		})
	end
	return create("Frame", base, { bar(2.5, 45), bar(7.5, -45) })
end

local function listLayout(padding: number): UIListLayout
	return create("UIListLayout", {
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, padding),
	})
end

local function formatNumber(value: number): string
	if value == math.floor(value) then
		return tostring(value)
	end
	return string.format("%.3g", value)
end

function Palette.new(host: any, manager: any)
	local self = setmetatable({}, Palette)
	self.host = host
	self.manager = manager
	self._maid = SDK.Maid.new()

	self.scroll = self._maid:add(create("ScrollingFrame", {
		Name = "Palette",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 6,
		Parent = host.container,
	}))

	self._maid:add(manager.changed:connect(function()
		self:render()
	end))
	self._maid:add(Theme.onChanged(function()
		self:render()
	end))

	self:render()
	return self
end

function Palette:render()
	self:_closeDropdown()
	if self._content then
		self._content:Destroy()
	end
	self.scroll.ScrollBarImageColor3 = Theme.color("ScrollBar")

	local content = create("Frame", {
		Name = "Content",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
	}, {
		listLayout(4),
		create("UIPadding", {
			PaddingLeft = UDim.new(0, 8),
			PaddingRight = UDim.new(0, 10),
			PaddingTop = UDim.new(0, 8),
			PaddingBottom = UDim.new(0, 8),
		}),
	})
	self._content = content

	local order = 0
	local function add(instance: GuiObject)
		order += 1
		instance.LayoutOrder = order
		instance.Parent = content
		return instance
	end

	local active = self.manager:getActiveTool()
	if active then
		self:_renderActiveTool(add, active)
	else
		self:_renderToolList(add)
	end

	content.Parent = self.scroll
end

-- The selected tab: the remembered one if it still exists, else the first.
function Palette:_selectedTab(): any
	local tabs = self.manager.tabs
	local name = self.host.persist.selectedTab
	if name == nil then
		local ok, saved = pcall(self.host.plugin.GetSetting, self.host.plugin, SELECTED_TAB_SETTING)
		name = if ok and type(saved) == "string" then saved else nil
	end
	for _, tab in tabs do
		if tab.name == name then
			return tab
		end
	end
	return tabs[1]
end

function Palette:_selectTab(name: string)
	self.host.persist.selectedTab = name
	pcall(self.host.plugin.SetSetting, self.host.plugin, SELECTED_TAB_SETTING, name)
	self:render()
end

function Palette:_tabBar(tabs: { any }, selected: any): GuiObject
	local bar = create("ScrollingFrame", {
		Name = "Tabs",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, Theme.ROW_HEIGHT + 3),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		ScrollingDirection = Enum.ScrollingDirection.X,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = Theme.color("ScrollBar"),
	}, {
		create("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 2),
		}),
	})

	for index, tab in tabs do
		local isSelected = tab == selected
		local tabButton = create("TextButton", {
			Name = tab.name,
			LayoutOrder = index,
			AutoButtonColor = not isSelected,
			BorderSizePixel = 0,
			BackgroundColor3 = Theme.color("Tab", if isSelected then "Selected" else "Default"),
			Font = if isSelected then Theme.FONT_BOLD else Theme.FONT,
			TextSize = Theme.TEXT_SIZE,
			TextColor3 = Theme.color(if isSelected then "MainText" else "DimmedText"),
			Size = UDim2.fromOffset(0, Theme.ROW_HEIGHT),
			AutomaticSize = Enum.AutomaticSize.X,
			Text = tab.name,
			Parent = bar,
		}, {
			create("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12) }),
		})
		if isSelected then
			-- Underline; offsets undo the button's padding so it spans the full width.
			create("Frame", {
				Name = "Underline",
				BackgroundColor3 = Theme.color("MainButton"),
				BorderSizePixel = 0,
				Position = UDim2.new(0, -12, 1, -2),
				Size = UDim2.new(1, 24, 0, 2),
				Parent = tabButton,
			})
		else
			tabButton.Activated:Connect(function()
				self:_selectTab(tab.name)
			end)
		end
	end
	return bar
end

function Palette:_renderToolList(add: (GuiObject) -> GuiObject)
	local manager = self.manager
	local selected = self:_selectedTab()
	if not selected then
		add(label("No tools loaded. Check toolpacks.json / toolpacks.local.json and the Output window.", {
			TextWrapped = true,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, 0, 0, 0),
			TextColor3 = Theme.color("DimmedText"),
		}))
		return
	end

	add(self:_tabBar(manager.tabs, selected))
	add(create("Frame", {
		BackgroundColor3 = Theme.color("Border"),
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 1),
	}))

	-- Pack headings only when this tab mixes several packs.
	local showPackHeadings = #selected.packs + #selected.failedPacks > 1
	for _, pack in selected.packs do
		if showPackHeadings then
			local header = add(label(string.upper(pack.manifest.name), {
				Font = Theme.FONT_BOLD,
				TextColor3 = Theme.color("DimmedText"),
			}))
			label(pack.manifest.version, {
				TextXAlignment = Enum.TextXAlignment.Right,
				TextColor3 = Theme.color("DimmedText"),
				Size = UDim2.fromScale(1, 1),
				Parent = header,
			})
		end
		for _, entry in pack.tools do
			local toolButton = add(button(entry.definition.name, false, {
				TextXAlignment = Enum.TextXAlignment.Left,
			}))
			create("UIPadding", { PaddingLeft = UDim.new(0, 8), Parent = toolButton })
			toolButton.Activated:Connect(function()
				manager:toggle(entry.id)
			end)
		end
	end

	for _, manifest in selected.failedPacks do
		add(label(string.upper(manifest.name), { Font = Theme.FONT_BOLD, TextColor3 = Theme.color("DimmedText") }))
		add(label("Failed to load; see the Output window.", { TextColor3 = Theme.color("ErrorText") }))
	end
end

function Palette:_renderActiveTool(add: (GuiObject) -> GuiObject, active: any)
	local definition = active.definition
	add(label(definition.name, {
		Font = Theme.FONT_BOLD,
		TextSize = Theme.TEXT_SIZE + 4,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Size = UDim2.new(1, 0, 0, Theme.ROW_HEIGHT + 4),
	}))
	add(create("Frame", {
		BackgroundColor3 = Theme.color("Border"),
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 1),
	}))

	local schemas = definition.settings or {}
	if #schemas == 0 then
		add(label("No settings", { TextColor3 = Theme.color("DimmedText") }))
		return
	end
	local values = self.manager:getSettings(active)
	for _, schema in schemas do
		add(self:_settingRow(active, schema, values[schema.key]))
	end
end

function Palette:_settingRow(entry: any, schema: any, value: any): Frame
	local manager = self.manager
	local function set(newValue: any)
		manager:setSetting(entry.id, schema.key, newValue)
	end

	local row = create("Frame", {
		Name = schema.key,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, Theme.ROW_HEIGHT),
	})
	label(schema.label or schema.key, {
		Size = UDim2.new(0.45, -4, 0, Theme.ROW_HEIGHT),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = row,
	})
	local editorFrame = create("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromScale(0.45, 0),
		Size = UDim2.new(0.55, 0, 0, Theme.ROW_HEIGHT),
		Parent = row,
	})

	local kind = schema.type
	if kind == "number" then
		local box = textBox(formatNumber(value), { Parent = editorFrame })
		box.FocusLost:Connect(function()
			local parsed = tonumber(box.Text)
			if parsed then
				set(parsed)
			else
				box.Text = formatNumber(value)
			end
		end)
	elseif kind == "boolean" then
		local toggle = button(if value then "On" else "Off", value, { Parent = editorFrame })
		toggle.Activated:Connect(function()
			set(not value)
		end)
	elseif kind == "enum" then
		local field = button(tostring(value), false, {
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = editorFrame,
		}, {
			create("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 18) }),
		})
		chevron(Theme.color("DimmedText"), {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, 13, 0.5, 0),
			Parent = field,
		})
		field.Activated:Connect(function()
			self:_openDropdown(field, schema.options or {}, value, set)
		end)
	elseif kind == "color" then
		row.AutomaticSize = Enum.AutomaticSize.Y
		editorFrame.AutomaticSize = Enum.AutomaticSize.Y
		listLayout(4).Parent = editorFrame

		local top = create("Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, Theme.ROW_HEIGHT),
			LayoutOrder = 1,
			Parent = editorFrame,
		})
		create("Frame", {
			BackgroundColor3 = value,
			BorderSizePixel = 1,
			BorderColor3 = Theme.color("Border"),
			Size = UDim2.fromOffset(Theme.ROW_HEIGHT, Theme.ROW_HEIGHT),
			Parent = top,
		})
		local hexBox = textBox("#" .. string.upper(value:ToHex()), {
			Position = UDim2.fromOffset(Theme.ROW_HEIGHT + 4, 0),
			Size = UDim2.new(1, -(Theme.ROW_HEIGHT + 4), 0, Theme.ROW_HEIGHT),
			Parent = top,
		})
		hexBox.FocusLost:Connect(function()
			local hex = string.gsub(hexBox.Text, "^#", "")
			local ok, color = pcall(Color3.fromHex, hex)
			if ok then
				set(color)
			else
				hexBox.Text = "#" .. string.upper(value:ToHex())
			end
		end)

		local swatches = create("Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = 2,
			Parent = editorFrame,
		}, {
			create("UIGridLayout", {
				CellSize = UDim2.fromOffset(18, 18),
				CellPadding = UDim2.fromOffset(4, 4),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
		})
		for index, preset in schema.presets or DEFAULT_COLOR_PRESETS do
			local swatch = create("TextButton", {
				Text = "",
				AutoButtonColor = true,
				BackgroundColor3 = preset,
				BorderSizePixel = 1,
				BorderColor3 = Theme.color("Border"),
				LayoutOrder = index,
				Parent = swatches,
			})
			swatch.Activated:Connect(function()
				set(preset)
			end)
		end
	else
		label(string.format("(unsupported type '%s')", tostring(kind)), {
			TextColor3 = Theme.color("ErrorText"),
			Parent = editorFrame,
		})
	end

	return row
end

-- Dropdown (enum settings) ----------------------------------------------------
-- The list floats in a layer over the whole palette, below the field (or
-- above it, if there's more room there). Picking an option, clicking
-- outside the list, scrolling the palette, resizing it or re-rendering it
-- closes the list.

function Palette:_openDropdown(anchor: GuiObject, options: { any }, current: any, onPick: (any) -> ())
	self:_closeDropdown()
	if #options == 0 then
		return
	end
	local container: GuiObject = self.host.container
	local dropdown = {}
	self._dropdown = dropdown

	local layer = create("TextButton", {
		Name = "Dropdown",
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 10,
	})
	dropdown.layer = layer
	layer.Activated:Connect(function()
		self:_closeDropdown()
	end)

	-- Place it under the anchor, flipping above when that has more room.
	local itemHeight = Theme.ROW_HEIGHT - 2
	local wanted = #options * itemHeight + 2
	local anchorTop = anchor.AbsolutePosition.Y - container.AbsolutePosition.Y
	local below = container.AbsoluteSize.Y - (anchorTop + anchor.AbsoluteSize.Y)
	local above = anchorTop
	local height, top
	if wanted <= below or below >= above then
		height = math.min(wanted, DROPDOWN_MAX_HEIGHT, below)
		top = anchorTop + anchor.AbsoluteSize.Y
	else
		height = math.min(wanted, DROPDOWN_MAX_HEIGHT, above)
		top = anchorTop - height
	end

	local list = create("ScrollingFrame", {
		Name = "List",
		Position = UDim2.fromOffset(anchor.AbsolutePosition.X - container.AbsolutePosition.X, top),
		Size = UDim2.fromOffset(anchor.AbsoluteSize.X, height),
		BackgroundColor3 = Theme.color("MainBackground"),
		BorderSizePixel = 1,
		BorderColor3 = Theme.color("Border"),
		CanvasSize = UDim2.fromOffset(0, #options * itemHeight),
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = Theme.color("ScrollBar"),
		Parent = layer,
	}, { listLayout(0) })

	for index, option in options do
		local selected = option == current
		local function background(hovered: boolean): Color3
			return Theme.color("Item", if selected then "Selected" elseif hovered then "Hover" else "Default")
		end
		local item = create("TextButton", {
			Name = tostring(option),
			LayoutOrder = index,
			AutoButtonColor = false,
			BorderSizePixel = 0,
			BackgroundColor3 = background(false),
			Size = UDim2.new(1, 0, 0, itemHeight),
			Font = Theme.FONT,
			TextSize = Theme.TEXT_SIZE,
			TextColor3 = Theme.color("MainText", if selected then "Selected" else "Default"),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Text = tostring(option),
			Parent = list,
		}, {
			create("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) }),
		})
		item.MouseEnter:Connect(function()
			item.BackgroundColor3 = background(true)
		end)
		item.MouseLeave:Connect(function()
			item.BackgroundColor3 = background(false)
		end)
		item.Activated:Connect(function()
			self:_closeDropdown()
			if not selected then
				onPick(option)
			end
		end)
	end

	-- Scroll the current option into view.
	local currentIndex = table.find(options, current)
	if currentIndex then
		local y = (currentIndex - 1) * itemHeight - (height - itemHeight) / 2
		list.CanvasPosition = Vector2.new(0, math.clamp(y, 0, math.max(0, #options * itemHeight - height)))
	end

	local function close()
		self:_closeDropdown()
	end
	dropdown.connections = {
		self.scroll:GetPropertyChangedSignal("CanvasPosition"):Connect(close),
		container:GetPropertyChangedSignal("AbsoluteSize"):Connect(close),
	}
	layer.Parent = container
end

function Palette:_closeDropdown()
	local dropdown = self._dropdown
	if not dropdown then
		return
	end
	self._dropdown = nil
	for _, connection in dropdown.connections or {} do
		connection:Disconnect()
	end
	dropdown.layer:Destroy()
end

function Palette:destroy()
	self:_closeDropdown()
	self._maid:clean()
	self._content = nil
end

return Palette
