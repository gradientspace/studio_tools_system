--[[
	Palette: the dock widget UI. Two modes:
	  * no tool active: a tab bar (tabs and sections come from ToolManager)
	    and the selected tab's tool buttons in a two-column grid, with a
	    label per section when the tab has more than one
	  * tool active: the tool's name, its status line (ctx:setStatus) and
	    its settings, built from the tool's `settings` schemas (including
	    "button" actions); ctx:setSettingState shows/hides, enables/disables
	    and relabels them in place (the tool is exited with the shutdown
	    overlay's buttons in the viewport)
	The whole thing is re-rendered
	whenever the ToolManager or Studio theme changes; it's small enough that
	this is simpler than diffing.
]]

local TextService = game:GetService("TextService")

local SDK = require(script.Parent.Parent.SDK)
local Theme = require(script.Parent.Theme)

local SELECTED_TAB_SETTING = "StudioToolsSystem.SelectedTab"
local DROPDOWN_MAX_HEIGHT = 240
local TOOL_GRID_GAP = 6
local DISABLED_TRANSPARENCY = 0.6 -- of a disabled setting's row
local TOOLTIP_DELAY = 0.5 -- seconds the mouse rests on something before its tooltip shows
local TOOLTIP_MAX_WIDTH = 260
local SLIDER_VALUE_WIDTH = 48 -- the value field beside a slider
local SLIDER_KNOB = 12
local PICKER_WIDTH = 200 -- color picker popup; fixed, whatever the palette's width
local PICKER_SWATCH_SIZE = 19 -- 8 per row: 8 x 19 + 7 gaps of 4 fills the picker's 184px content width
local PICKER_SWATCH_GAP = 4
local PICKER_SQUARE_HEIGHT = 120
local TAB_HEIGHT = 18
local TAB_TEXT_SIZE = 14

-- The color picker's swatches when a setting has no `presets`, in one grid
-- (3 full rows of 8 at the picker's width): white to black and brown, the
-- pure primaries and secondaries, then softer colors.
local DEFAULT_COLOR_PRESETS = {
	Color3.fromRGB(255, 255, 255),
	Color3.fromRGB(242, 243, 243),
	Color3.fromRGB(205, 205, 205),
	Color3.fromRGB(163, 162, 165),
	Color3.fromRGB(99, 99, 99),
	Color3.fromRGB(27, 42, 53),
	Color3.fromRGB(0, 0, 0),
	Color3.fromRGB(124, 92, 70),
	Color3.fromRGB(255, 0, 0),
	Color3.fromRGB(0, 255, 0),
	Color3.fromRGB(0, 0, 255),
	Color3.fromRGB(255, 0, 255),
	Color3.fromRGB(0, 255, 255),
	Color3.fromRGB(255, 255, 0),
	Color3.fromRGB(196, 40, 28),
	Color3.fromRGB(218, 133, 65),
	Color3.fromRGB(245, 205, 48),
	Color3.fromRGB(75, 151, 75),
	Color3.fromRGB(13, 105, 172),
	Color3.fromRGB(107, 50, 124),
	Color3.fromRGB(255, 148, 196),
	Color3.fromRGB(0, 143, 156),
	Color3.fromRGB(164, 189, 71),
	Color3.fromRGB(215, 197, 154),
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

-- A flat button in the style of Studio's own panels: a theme fill with
-- rounded corners and no border, shaded on hover and press. A selected
-- button (the current tab, a toggle that's on) uses the accent color.
local function button(text: string, selected: boolean?, props: { [string]: any }?, children: { Instance }?): TextButton
	local fill = if selected then Theme.ACCENT else Theme.buttonFill()
	local base = {
		AutoButtonColor = false,
		BorderSizePixel = 0,
		BackgroundColor3 = fill,
		Font = Theme.FONT,
		TextSize = Theme.TEXT_SIZE,
		TextColor3 = if selected then Color3.new(1, 1, 1) else Theme.color("ButtonText"),
		Size = UDim2.new(1, 0, 0, Theme.ROW_HEIGHT),
		Text = text,
	}
	if props then
		for key, value in props do
			base[key] = value
		end
	end
	local instance = create("TextButton", base, children)
	create("UICorner", { CornerRadius = UDim.new(0, 4), Parent = instance })

	local hovered, pressed = false, false
	local function refresh()
		instance.BackgroundColor3 = if pressed then Theme.shade(fill, 0.14) elseif hovered then Theme.shade(fill, 0.07) else fill
	end
	instance.MouseEnter:Connect(function()
		hovered = true
		refresh()
	end)
	instance.MouseLeave:Connect(function()
		hovered, pressed = false, false
		refresh()
	end)
	instance.MouseButton1Down:Connect(function()
		pressed = true
		refresh()
	end)
	instance.MouseButton1Up:Connect(function()
		pressed = false
		refresh()
	end)
	return instance
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
	self._settingRows = {} -- setting key -> { applyState, setValue }, for the active tool's rows
	self._availabilityRefreshers = {} -- one per tool button: re-asks canActivate() and restyles it
	self._statusLabel = nil

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
	self._maid:add(self.scroll:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
		self:_hideTooltip()
	end))
	-- Status and widget state changes update the rendered rows in place, so
	-- they don't disturb a field the user is editing.
	self._maid:add(manager.toolUiChanged:connect(function()
		self:_applyToolUi()
	end))
	self._maid:add(manager.settingChanged:connect(function(toolId, key, value)
		local active = manager:getActiveTool()
		local handle = self._settingRows[key]
		if active and active.id == toolId and handle then
			handle.setValue(value)
		end
	end))
	self._maid:add(manager.availabilityChanged:connect(function()
		for _, refresh in self._availabilityRefreshers do
			refresh()
		end
	end))
	self._maid:add(Theme.onChanged(function()
		self:render()
	end))

	self:render()
	return self
end

function Palette:render()
	self:_closeDropdown()
	self:_endDrag()
	self:_hideTooltip()
	if self._content then
		self._content:Destroy()
	end
	self._settingRows = {}
	self._availabilityRefreshers = {}
	self._statusLabel = nil
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
		Size = UDim2.new(1, 0, 0, TAB_HEIGHT + 3),
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

	-- The selected tab is filled with the accent color; the others look like
	-- quieter buttons.
	for index, tab in tabs do
		local isSelected = tab == selected
		local tabButton = button(tab.name, isSelected, {
			Name = tab.name,
			LayoutOrder = index,
			Font = if isSelected then Theme.FONT_BOLD else Theme.FONT,
			TextColor3 = if isSelected then Color3.new(1, 1, 1) else Theme.color("DimmedText"),
			Size = UDim2.fromOffset(0, TAB_HEIGHT),
			TextSize = TAB_TEXT_SIZE,
			AutomaticSize = Enum.AutomaticSize.X,
			Parent = bar,
		}, {
			create("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12) }),
		})
		if not isSelected then
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

	-- Section labels only when this tab has more than one section (failed
	-- packs get their own heading below, so they count too).
	local showSectionLabels = #selected.sections + #selected.failedPacks > 1
	for _, section in selected.sections do
		if showSectionLabels then
			add(label(string.upper(section.name), {
				Font = Theme.FONT_BOLD,
				TextColor3 = Theme.color("DimmedText"),
				TextTruncate = Enum.TextTruncate.AtEnd,
			}))
		end
		-- Tool buttons in a two-column grid.
		local grid = add(create("Frame", {
			Name = "Tools",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
		}, {
			create("UIGridLayout", {
				CellSize = UDim2.new(0.5, -TOOL_GRID_GAP / 2, 0, Theme.ROW_HEIGHT + 4),
				CellPadding = UDim2.fromOffset(TOOL_GRID_GAP, TOOL_GRID_GAP),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
		}))
		for index, entry in section.tools do
			local toolButton = button(entry.definition.name, false, {
				LayoutOrder = index,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Parent = grid,
			}, {
				create("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) }),
			})
			-- A tool whose canActivate() says no is greyed out, with the reason in its tooltip.
			local available, why = true, nil
			local function refreshAvailability()
				available, why = manager:getAvailability(entry)
				toolButton.TextTransparency = if available then 0 else DISABLED_TRANSPARENCY
			end
			refreshAvailability()
			table.insert(self._availabilityRefreshers, refreshAvailability)
			toolButton.Activated:Connect(function()
				refreshAvailability()
				if available then
					manager:toggle(entry.id)
				end
			end)
			self:_attachTooltip(toolButton, function()
				local description = entry.definition.description
				if available or not why then
					return description
				end
				return if description then description .. "\n\n" .. why else why
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
	-- The tool's status line (ctx:setStatus); hidden while it has none.
	self._statusLabel = add(label("", {
		TextColor3 = Theme.color("DimmedText"),
		TextWrapped = true,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Visible = false,
	}))
	add(create("Frame", {
		BackgroundColor3 = Theme.color("Border"),
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 1),
	}))

	local schemas = definition.settings or {}
	if #schemas == 0 then
		add(label("No settings", { TextColor3 = Theme.color("DimmedText") }))
	end
	local values = self.manager:getSettings(active)
	for _, schema in schemas do
		local row, handle = self:_settingRow(active, schema, values[schema.key])
		add(row)
		self._settingRows[schema.key] = handle
	end
	self:_applyToolUi()
end

-- Applies the active tool's status and widget states (ToolManager.toolUi)
-- to the rendered rows, without re-rendering.
function Palette:_applyToolUi()
	local status = self.manager.toolUi.status
	if self._statusLabel then
		self._statusLabel.Text = status or ""
		self._statusLabel.Visible = status ~= nil and status ~= ""
	end
	for key, handle in self._settingRows do
		handle.applyState(self.manager:getSettingState(key))
	end
end

local function formatSettingNumber(kind: string, value: number): string
	return if kind == "integer" then string.format("%d", math.round(value)) else formatNumber(value)
end

-- Builds the widget row for one setting. Returns the row and a handle:
--   applyState(state)  shows/hides, enables/disables, relabels it and sets its tooltip
--   setValue(value)    shows a new value (after an edit), without rebuilding the row
-- Rows are CanvasGroups so a disabled one can be faded as a whole; every
-- input handler checks `enabled` first.
function Palette:_settingRow(entry: any, schema: any, initialValue: any): (GuiObject, any)
	local manager = self.manager
	local kind = schema.type
	local extended = if type(schema.extended) == "table" then schema.extended else {}
	local value = initialValue
	local enabled = true
	local editableBoxes: { TextBox } = {}
	local function set(newValue: any)
		if enabled then
			manager:setSetting(entry.id, schema.key, newValue)
		end
	end
	local showValue: (any) -> () = function(_v: any) end

	local row = create("CanvasGroup", {
		Name = schema.key,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, Theme.ROW_HEIGHT),
	})
	local defaultLabel = schema.label or schema.key
	local tooltip: string? = schema.tooltip
	self:_attachTooltip(row, function()
		return tooltip
	end)

	local function finish(setLabel: (string) -> ()): (GuiObject, any)
		local handle = {}
		function handle.applyState(state: any)
			row.Visible = state.visible
			enabled = state.enabled
			row.GroupTransparency = if enabled then 0 else DISABLED_TRANSPARENCY
			setLabel(state.label or defaultLabel)
			tooltip = if state.tooltip ~= nil then state.tooltip else schema.tooltip
			for _, box in editableBoxes do
				box.TextEditable = enabled
				if not enabled then
					box:ReleaseFocus()
				end
			end
		end
		function handle.setValue(newValue: any)
			value = newValue
			showValue(newValue)
		end
		return row, handle
	end

	-- Full-width rows: an action button, or display-only text.
	if kind == "button" then
		row.Size = UDim2.new(1, 0, 0, Theme.ROW_HEIGHT + 4)
		local actionButton = button(defaultLabel, false, {
			Size = UDim2.fromScale(1, 1),
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = row,
		}, {
			create("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) }),
		})
		actionButton.Activated:Connect(function()
			if enabled then
				manager:runAction(schema.key)
			end
		end)
		return finish(function(text)
			actionButton.Text = text
		end)
	elseif kind == "label" then
		row.Size = UDim2.fromScale(1, 0)
		row.AutomaticSize = Enum.AutomaticSize.Y
		local text = label(defaultLabel, {
			TextWrapped = true,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Parent = row,
		})
		create("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4), Parent = text })
		return finish(function(newText)
			text.Text = newText
		end)
	end

	-- Everything else: name on the left, editor on the right.
	local nameLabel = label(defaultLabel, {
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
	local function setLabel(text: string)
		nameLabel.Text = text
	end

	-- A text field that commits when it loses focus; parse returns the new
	-- value, or nil to reject the text. Then shows the stored value.
	local function valueBox(format: (any) -> string, parse: (string) -> any, props: { [string]: any }?): TextBox
		local box = textBox(format(value), props)
		if not box.Parent then
			box.Parent = editorFrame
		end
		table.insert(editableBoxes, box)
		box.FocusLost:Connect(function()
			local parsed = parse(box.Text)
			if parsed ~= nil and enabled then
				set(parsed)
			end
			box.Text = format(value)
		end)
		return box
	end

	if kind == "number" or kind == "integer" then
		local function format(v: any): string
			return if type(v) == "number" then formatSettingNumber(kind, v) else ""
		end
		local min, max = schema.min, schema.max
		local slider = extended.widget == "slider"
		if slider and not (type(min) == "number" and type(max) == "number" and max > min) then
			warn(string.format("[StudioTools] Tool '%s' setting '%s': a slider needs min < max; showing a text field", entry.id, schema.key))
			slider = false
		end
		if not slider then
			local box = valueBox(format, tonumber)
			showValue = function(v)
				if not box:IsFocused() then
					box.Text = format(v)
				end
			end
		else
			-- A slider, with the value in a small field beside it.
			local area = create("TextButton", {
				Name = "Slider",
				Text = "",
				AutoButtonColor = false,
				BackgroundTransparency = 1,
				Size = UDim2.new(1, -(SLIDER_VALUE_WIDTH + 6), 1, 0),
				Parent = editorFrame,
			})
			local track = create("Frame", {
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(0, SLIDER_KNOB / 2, 0.5, 0),
				Size = UDim2.new(1, -SLIDER_KNOB, 0, 4),
				BackgroundColor3 = Theme.shade(Theme.buttonFill(), 0.1),
				BorderSizePixel = 0,
				Parent = area,
			}, { create("UICorner", { CornerRadius = UDim.new(1, 0) }) })
			local fill = create("Frame", {
				Size = UDim2.fromScale(0, 1),
				BackgroundColor3 = Theme.ACCENT,
				BorderSizePixel = 0,
				Parent = track,
			}, { create("UICorner", { CornerRadius = UDim.new(1, 0) }) })
			local knob = create("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0, 0.5),
				Size = UDim2.fromOffset(SLIDER_KNOB, SLIDER_KNOB),
				BackgroundColor3 = Theme.ACCENT,
				BorderSizePixel = 0,
				Parent = track,
			}, { create("UICorner", { CornerRadius = UDim.new(1, 0) }) })
			local box = valueBox(format, tonumber, {
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.fromScale(1, 0),
				Size = UDim2.new(0, SLIDER_VALUE_WIDTH, 1, 0),
				TextXAlignment = Enum.TextXAlignment.Center,
				Parent = editorFrame,
			})
			showValue = function(v)
				local t = if type(v) == "number" then math.clamp((v - min) / (max - min), 0, 1) else 0
				fill.Size = UDim2.fromScale(t, 1)
				knob.Position = UDim2.fromScale(t, 0.5)
				if not box:IsFocused() then
					box.Text = format(v)
				end
			end
			local function moveTo(position: Vector2)
				local t = math.clamp((position.X - track.AbsolutePosition.X) / math.max(1, track.AbsoluteSize.X), 0, 1)
				set(min + t * (max - min))
			end
			area.InputBegan:Connect(function(input)
				if enabled and input.UserInputType == Enum.UserInputType.MouseButton1 then
					moveTo(Vector2.new(input.Position.X, input.Position.Y))
					self:_beginDrag(input, moveTo)
				end
			end)
		end
	elseif kind == "string" then
		local function format(v: any): string
			return if type(v) == "string" then v else ""
		end
		local box = valueBox(format, function(text)
			return text
		end, {
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			PlaceholderText = if type(extended.placeholder) == "string" then extended.placeholder else "",
			PlaceholderColor3 = Theme.color("DimmedText"),
		})
		create("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6), Parent = box })
		showValue = function(v)
			if not box:IsFocused() then
				box.Text = format(v)
			end
		end
	elseif kind == "boolean" then
		-- button() bakes in its selected look, so the toggle is rebuilt on change.
		local toggle: TextButton? = nil
		showValue = function(v)
			if toggle then
				toggle:Destroy()
			end
			local newToggle = button(if v then "On" else "Off", v == true, { Parent = editorFrame })
			newToggle.Activated:Connect(function()
				set(not value)
			end)
			toggle = newToggle
		end
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
			if enabled then
				self:_openDropdown(field, schema.options or {}, value, set)
			end
		end)
		showValue = function(v)
			field.Text = tostring(v)
		end
	elseif kind == "color" then
		-- A swatch with the hex value; clicking it opens the color picker.
		local field = button("", false, { Parent = editorFrame })
		local swatch = create("Frame", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 4, 0.5, 0),
			Size = UDim2.new(0, 34, 1, -8),
			BorderSizePixel = 0,
			Parent = field,
		}, {
			create("UICorner", { CornerRadius = UDim.new(0, 3) }),
			create("UIStroke", { Color = Theme.color("Border"), Thickness = 1 }),
		})
		local hexLabel = label("", {
			Position = UDim2.fromOffset(46, 0),
			Size = UDim2.new(1, -50, 1, 0),
			TextColor3 = Theme.color("ButtonText"),
			Parent = field,
		})
		showValue = function(v)
			if typeof(v) == "Color3" then
				swatch.BackgroundColor3 = v
				hexLabel.Text = "#" .. string.upper(v:ToHex())
			end
		end
		field.Activated:Connect(function()
			if enabled and typeof(value) == "Color3" then
				self:_openColorPicker(field, value, { schema.presets or DEFAULT_COLOR_PRESETS }, set)
			end
		end)
	else
		label(string.format("(unsupported type '%s')", tostring(kind)), {
			TextColor3 = Theme.color("ErrorText"),
			Parent = editorFrame,
		})
	end

	showValue(value)
	return finish(setLabel)
end

-- Tooltips -----------------------------------------------------------------------
-- Studio has no tooltips for plugin UI, so the palette draws its own: when
-- the mouse rests on a target for TOOLTIP_DELAY, getText()'s text (if any)
-- shows in a box below it (or above, near the bottom). Leaving the target,
-- scrolling or re-rendering hides it.

function Palette:_attachTooltip(target: GuiObject, getText: () -> string?)
	local hoverId = 0
	target.MouseEnter:Connect(function()
		hoverId += 1
		local thisHover = hoverId
		task.delay(TOOLTIP_DELAY, function()
			if hoverId ~= thisHover or not target:IsDescendantOf(self.host.container) or self._dropdown then
				return
			end
			local text = getText()
			if type(text) == "string" and text ~= "" then
				self:_showTooltip(target, text)
			end
		end)
	end)
	target.MouseLeave:Connect(function()
		hoverId += 1
		self:_hideTooltip(target)
	end)
end

function Palette:_showTooltip(target: GuiObject, text: string)
	self:_hideTooltip()
	local container: GuiObject = self.host.container
	local padX, padY = 6, 4
	local textSize = Theme.TEXT_SIZE - 1
	local maxWidth = math.max(60, math.min(TOOLTIP_MAX_WIDTH, container.AbsoluteSize.X - 16) - 2 * padX)
	local bounds = TextService:GetTextSize(text, textSize, Theme.FONT, Vector2.new(maxWidth, math.huge))
	local width, height = math.ceil(bounds.X) + 2 * padX + 1, math.ceil(bounds.Y) + 2 * padY

	local origin = container.AbsolutePosition
	local left = math.clamp(target.AbsolutePosition.X - origin.X, 4, math.max(4, container.AbsoluteSize.X - width - 4))
	local top = target.AbsolutePosition.Y - origin.Y + target.AbsoluteSize.Y + 2
	if top + height > container.AbsoluteSize.Y then
		top = math.max(0, target.AbsolutePosition.Y - origin.Y - height - 2)
	end

	local tip = create("TextLabel", {
		Name = "Tooltip",
		ZIndex = 20,
		Position = UDim2.fromOffset(left, top),
		Size = UDim2.fromOffset(width, height),
		BackgroundColor3 = Theme.color("Tooltip"),
		BorderSizePixel = 1,
		BorderColor3 = Theme.color("Border"),
		Font = Theme.FONT,
		TextSize = textSize,
		TextColor3 = Theme.color("MainText"),
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Text = text,
	}, {
		create("UIPadding", {
			PaddingLeft = UDim.new(0, padX),
			PaddingRight = UDim.new(0, padX),
			PaddingTop = UDim.new(0, padY),
			PaddingBottom = UDim.new(0, padY),
		}),
	})
	tip.Parent = container
	self._tooltip = { gui = tip, target = target }
end

-- Hides the tooltip; with a target, only if it's that target's.
function Palette:_hideTooltip(target: GuiObject?)
	local tooltip = self._tooltip
	if not tooltip or (target and tooltip.target ~= target) then
		return
	end
	self._tooltip = nil
	tooltip.gui:Destroy()
end

-- Mouse drags (sliders, the color picker) ------------------------------------------
-- A drag starts on a widget's press. A transparent layer over the whole palette
-- then receives the mouse, so the drag continues outside the widget, and
-- onMove(position) is called for each move (in the same space as
-- AbsolutePosition). Releasing the button, or the mouse leaving the palette,
-- ends it. The release is reported to the widget the press began on, not to
-- the layer, so it's detected on the press's InputObject (pressInput), whose
-- UserInputState becomes End.

function Palette:_beginDrag(pressInput: InputObject, onMove: (Vector2) -> ())
	self:_endDrag()
	local layer = create("TextButton", {
		Name = "DragCapture",
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 30,
	})
	self._drag = layer
	layer.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement then
			onMove(Vector2.new(input.Position.X, input.Position.Y))
		end
	end)
	layer.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			self:_endDrag()
		end
	end)
	layer.MouseLeave:Connect(function()
		self:_endDrag()
	end)
	local released = pressInput:GetPropertyChangedSignal("UserInputState"):Connect(function()
		if pressInput.UserInputState ~= Enum.UserInputState.Begin and pressInput.UserInputState ~= Enum.UserInputState.Change then
			self:_endDrag()
		end
	end)
	layer.Destroying:Connect(function()
		released:Disconnect()
	end)
	layer.Parent = self.host.container
	if pressInput.UserInputState == Enum.UserInputState.End then
		self:_endDrag() -- already released (a quick click)
	end
end

function Palette:_endDrag()
	local layer = self._drag
	if layer then
		self._drag = nil
		layer:Destroy()
	end
end

-- Popups (dropdown list, color picker) ---------------------------------------------
-- A popup floats in a layer over the whole palette. Clicking outside it,
-- scrolling the palette, resizing it or re-rendering it closes it. Only one
-- is open at a time.

-- Opens an empty popup layer and returns it; the caller adds the popup's
-- content (which should be Active, so clicks on it don't close it).
function Palette:_openPopupLayer(name: string): TextButton
	self:_closeDropdown()
	self:_hideTooltip()
	local container: GuiObject = self.host.container
	local layer = create("TextButton", {
		Name = name,
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 10,
	})
	layer.Activated:Connect(function()
		self:_closeDropdown()
	end)
	local function close()
		self:_closeDropdown()
	end
	self._dropdown = {
		layer = layer,
		connections = {
			self.scroll:GetPropertyChangedSignal("CanvasPosition"):Connect(close),
			container:GetPropertyChangedSignal("AbsoluteSize"):Connect(close),
		},
	}
	layer.Parent = container
	return layer
end

-- Where a popup of the given height goes: under the anchor, or above it when
-- that has more room. Returns top (container-relative) and the height that fits.
function Palette:_popupPlacement(anchor: GuiObject, wanted: number): (number, number)
	local container: GuiObject = self.host.container
	local anchorTop = anchor.AbsolutePosition.Y - container.AbsolutePosition.Y
	local below = container.AbsoluteSize.Y - (anchorTop + anchor.AbsoluteSize.Y)
	local above = anchorTop
	if wanted <= below or below >= above then
		local height = math.min(wanted, below)
		return anchorTop + anchor.AbsoluteSize.Y, height
	end
	local height = math.min(wanted, above)
	return anchorTop - height, height
end

function Palette:_closeDropdown()
	local dropdown = self._dropdown
	if not dropdown then
		return
	end
	self._dropdown = nil
	self:_endDrag()
	for _, connection in dropdown.connections or {} do
		connection:Disconnect()
	end
	dropdown.layer:Destroy()
end

-- Color picker ---------------------------------------------------------------------
-- A saturation/brightness square, a hue bar, a preview with the hex value
-- (editable) and preset swatches. Every change is applied right away through
-- onChange; the picker keeps its own hue/saturation/value so the hue doesn't
-- jump when the color is grey.

local HUE_COLORS = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromHSV(0, 1, 1)),
	ColorSequenceKeypoint.new(1 / 6, Color3.fromHSV(1 / 6, 1, 1)),
	ColorSequenceKeypoint.new(2 / 6, Color3.fromHSV(2 / 6, 1, 1)),
	ColorSequenceKeypoint.new(3 / 6, Color3.fromHSV(3 / 6, 1, 1)),
	ColorSequenceKeypoint.new(4 / 6, Color3.fromHSV(4 / 6, 1, 1)),
	ColorSequenceKeypoint.new(5 / 6, Color3.fromHSV(5 / 6, 1, 1)),
	ColorSequenceKeypoint.new(1, Color3.fromHSV(1, 1, 1)),
})

local function marker(size: number): Frame
	return create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(size, size),
		BackgroundTransparency = 1,
		ZIndex = 2,
	}, {
		create("UICorner", { CornerRadius = UDim.new(1, 0) }),
		create("UIStroke", { Color = Color3.new(1, 1, 1), Thickness = 2 }),
	})
end

-- presetGroups: swatch groups, each starting on a new row.
function Palette:_openColorPicker(anchor: GuiObject, initial: Color3, presetGroups: { { Color3 } }, onChange: (Color3) -> ())
	local layer = self:_openPopupLayer("ColorPicker")
	local container: GuiObject = self.host.container
	local h, s, v = initial:ToHSV()

	local pad = 8
	local width = math.min(PICKER_WIDTH, math.max(1, container.AbsoluteSize.X - 8)) -- narrower only if the palette is
	local gap, swatchSize = PICKER_SWATCH_GAP, PICKER_SWATCH_SIZE
	local perRow = math.max(1, math.floor((width - 2 * pad + gap) / (swatchSize + gap)))
	local swatchRows = 0
	for _, group in presetGroups do
		swatchRows += math.ceil(#group / perRow)
	end
	local swatchesHeight = if swatchRows > 0 then swatchRows * (swatchSize + gap) - gap else 0
	local wanted = pad + PICKER_SQUARE_HEIGHT + 6 + 14 + 6 + Theme.ROW_HEIGHT + (if swatchRows > 0 then 6 + swatchesHeight else 0) + pad
	local top, height = self:_popupPlacement(anchor, wanted)
	local left = math.clamp(anchor.AbsolutePosition.X - container.AbsolutePosition.X, 4, math.max(4, container.AbsoluteSize.X - width - 4))

	local panel = create("Frame", {
		Name = "Panel",
		Active = true, -- clicks on the picker don't reach the layer (which closes it)
		Position = UDim2.fromOffset(left, top),
		Size = UDim2.fromOffset(width, height),
		ClipsDescendants = true,
		BackgroundColor3 = Theme.color("MainBackground"),
		BorderSizePixel = 1,
		BorderColor3 = Theme.color("Border"),
		Parent = layer,
	}, {
		create("UIPadding", {
			PaddingLeft = UDim.new(0, pad),
			PaddingRight = UDim.new(0, pad),
			PaddingTop = UDim.new(0, pad),
			PaddingBottom = UDim.new(0, pad),
		}),
		listLayout(6),
	})

	-- Saturation (x) / value (y) square: the hue, with white fading in from the
	-- left and black from the bottom.
	local square = create("TextButton", {
		Name = "SaturationValue",
		Text = "",
		AutoButtonColor = false,
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, PICKER_SQUARE_HEIGHT),
		BorderSizePixel = 0,
		Parent = panel,
	})
	create("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Parent = square,
	}, {
		create("UIGradient", { Transparency = NumberSequence.new(0, 1) }),
	})
	create("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BorderSizePixel = 0,
		Parent = square,
	}, {
		create("UIGradient", { Rotation = 90, Transparency = NumberSequence.new(1, 0) }),
	})
	local squareMarker = marker(10)
	squareMarker.Parent = square

	-- Hue bar.
	local hueBar = create("TextButton", {
		Name = "Hue",
		Text = "",
		AutoButtonColor = false,
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, 14),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Parent = panel,
	}, {
		create("UIGradient", { Color = HUE_COLORS }),
		create("UICorner", { CornerRadius = UDim.new(0, 3) }),
	})
	local hueMarker = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.new(0, 4, 1, 4),
		BackgroundTransparency = 1,
		ZIndex = 2,
		Parent = hueBar,
	}, {
		create("UIStroke", { Color = Color3.new(1, 1, 1), Thickness = 2 }),
	})

	-- Preview and hex value.
	local hexRow = create("Frame", {
		LayoutOrder = 3,
		Size = UDim2.new(1, 0, 0, Theme.ROW_HEIGHT),
		BackgroundTransparency = 1,
		Parent = panel,
	})
	local preview = create("Frame", {
		Size = UDim2.fromOffset(40, Theme.ROW_HEIGHT),
		BorderSizePixel = 0,
		Parent = hexRow,
	}, {
		create("UICorner", { CornerRadius = UDim.new(0, 3) }),
		create("UIStroke", { Color = Theme.color("Border"), Thickness = 1 }),
	})
	local hexBox = textBox("", {
		Position = UDim2.fromOffset(48, 0),
		Size = UDim2.new(1, -48, 1, 0),
		Parent = hexRow,
	})

	local function refresh()
		local color = Color3.fromHSV(h, s, v)
		square.BackgroundColor3 = Color3.fromHSV(h, 1, 1)
		squareMarker.Position = UDim2.fromScale(s, 1 - v)
		hueMarker.Position = UDim2.fromScale(h, 0.5)
		preview.BackgroundColor3 = color
		if not hexBox:IsFocused() then
			hexBox.Text = "#" .. string.upper(color:ToHex())
		end
	end
	local function apply()
		refresh()
		onChange(Color3.fromHSV(h, s, v))
	end
	local function setColor(color: Color3)
		local newH, newS, newV = color:ToHSV()
		if newS > 0 and newV > 0 then
			h = newH -- keep the hue for greys and black
		end
		s, v = newS, newV
		apply()
	end

	local function dragOn(target: GuiButton, onMove: (Vector2) -> ())
		target.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				onMove(Vector2.new(input.Position.X, input.Position.Y))
				self:_beginDrag(input, onMove)
			end
		end)
	end
	dragOn(square, function(position)
		s = math.clamp((position.X - square.AbsolutePosition.X) / math.max(1, square.AbsoluteSize.X), 0, 1)
		v = 1 - math.clamp((position.Y - square.AbsolutePosition.Y) / math.max(1, square.AbsoluteSize.Y), 0, 1)
		apply()
	end)
	dragOn(hueBar, function(position)
		h = math.clamp((position.X - hueBar.AbsolutePosition.X) / math.max(1, hueBar.AbsoluteSize.X), 0, 1)
		apply()
	end)
	hexBox.FocusLost:Connect(function()
		local hex = string.gsub(hexBox.Text, "^%s*#?", "")
		local ok, color = pcall(Color3.fromHex, (string.gsub(hex, "%s+$", "")))
		if ok then
			setColor(color)
		else
			refresh()
		end
	end)

	-- Presets: one wrapping grid per group, stacked 4px apart.
	local presetList = create("Frame", {
		LayoutOrder = 4,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Visible = swatchRows > 0,
		Parent = panel,
	}, { listLayout(4) })
	for groupIndex, presets in presetGroups do
		local swatches = create("Frame", {
			LayoutOrder = groupIndex,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Parent = presetList,
		}, {
			create("UIGridLayout", {
				CellSize = UDim2.fromOffset(swatchSize, swatchSize),
				CellPadding = UDim2.fromOffset(gap, gap),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
		})
		for index, preset in presets do
			local swatch = create("TextButton", {
				Text = "",
				AutoButtonColor = true,
				BackgroundColor3 = preset,
				BorderSizePixel = 0,
				LayoutOrder = index,
				Parent = swatches,
			}, {
				create("UICorner", { CornerRadius = UDim.new(0, 3) }),
				create("UIStroke", { Color = Theme.color("Border"), Thickness = 1 }),
			})
			swatch.Activated:Connect(function()
				setColor(preset)
			end)
		end
	end

	refresh()
end

-- Dropdown (enum settings) ----------------------------------------------------
-- The option list, in a popup under the field (or above it).

function Palette:_openDropdown(anchor: GuiObject, options: { any }, current: any, onPick: (any) -> ())
	if #options == 0 then
		self:_closeDropdown()
		return
	end
	local layer = self:_openPopupLayer("Dropdown")
	local container: GuiObject = self.host.container
	local itemHeight = Theme.ROW_HEIGHT - 2
	local top, height = self:_popupPlacement(anchor, math.min(#options * itemHeight + 2, DROPDOWN_MAX_HEIGHT))

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
end

function Palette:destroy()
	self:_closeDropdown()
	self:_endDrag()
	self:_hideTooltip()
	self._maid:clean()
	self._content = nil
end

return Palette
