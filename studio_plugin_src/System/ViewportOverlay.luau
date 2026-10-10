--[[
	ViewportOverlay: system-owned UI drawn over the 3D viewport.

	  * Shutdown buttons at the bottom-center while a tool is active ("Done",
	    or "Accept"/"Cancel"); buttons can be disabled, with a tooltip saying why.
	  * A modal confirmation dialog (confirm()), used by tools via ctx:confirm()
	    and ctx:alert().
	  * A modal progress dialog (showProgress()), used by tools via
	    ctx:showProgress() while they work (e.g. an upload on Accept).
	  * While the system waits on a tool's confirmShutdown(), the shutdown
	    buttons are greyed out (setShutdownButtonsBusy()).
	  * A chip in the bottom-right corner (setChip()), e.g. "3 Local Meshes",
	    whose right side opens a popup menu of actions and toggles.

	It's a ScreenGui in CoreGui, so it draws over the viewport without
	touching the place. ToolManager decides what to show; this module only
	draws it and reports clicks.

	isBlockingInput() lets the InputManager ignore viewport clicks that land
	on the buttons or the chip, and all viewport clicks while a dialog or the
	chip's menu is open.
]]

local CoreGui = game:GetService("CoreGui")
local RunService = game:GetService("RunService")

local SDK = require(script.Parent.Parent.SDK)

local BUTTON_HEIGHT = 30
local BUTTON_MIN_WIDTH = 96
local BUTTON_TEXT_SIZE = 20
local BOTTOM_MARGIN = 12

-- Fixed colors rather than Studio theme colors: the overlay sits on top of
-- the 3D scene, which looks the same in light and dark themes.
local GREEN = Color3.fromRGB(46, 160, 67)
local RED = Color3.fromRGB(215, 25, 25)
local BLUE = Color3.fromRGB(0, 122, 204)
local GRAY = Color3.fromRGB(110, 110, 110)
local PANEL = Color3.fromRGB(37, 37, 38)
local DISABLED_BUTTON = Color3.fromRGB(90, 90, 90)
local DISABLED_TEXT = Color3.fromRGB(170, 170, 170)
local BUSY_TOOLTIP = "Working..."
local CHIP_COLOR = Color3.fromRGB(176, 82, 8) -- dark orange
local CHIP_BUTTON_HOVER = Color3.fromRGB(140, 62, 4)
local CHIP_MARGIN = 12
local MENU_WIDTH = 230
local MENU_ITEM_HEIGHT = 28
local MENU_HOVER = Color3.fromRGB(62, 62, 66)
local MENU_TOOLTIP_WIDTH = 260

local SHUTDOWN_COLORS = {
	Done = GREEN,
	Accept = GREEN,
	Cancel = RED,
}

export type Button = {
	reason: string, -- "Done" | "Accept" | "Cancel"; passed to onClick
	text: string,
	tooltip: string?,
}

export type ChipItem = {
	key: string, -- passed to the chip's onSelect
	text: string,
	checked: boolean?, -- a toggle (with a checkbox) if not nil
	enabled: boolean?, -- default true
	tooltip: string?, -- shown beside the menu while hovered (e.g. why it's disabled)
}

export type Chip = {
	text: string,
	items: { ChipItem },
	onSelect: (key: string) -> (),
}

local ViewportOverlay = {}
ViewportOverlay.__index = ViewportOverlay

local function addCorner(parent: Instance, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = parent
end

local function addPadding(parent: Instance, horizontal: number, vertical: number)
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, horizontal)
	padding.PaddingRight = UDim.new(0, horizontal)
	padding.PaddingTop = UDim.new(0, vertical)
	padding.PaddingBottom = UDim.new(0, vertical)
	padding.Parent = parent
end

-- A rounded overlay button. Returns the button and a function to set its
-- enabled state: setEnabled(enabled, color).
local function makeButton(text: string, color: Color3): (TextButton, (boolean, Color3) -> ())
	local button = Instance.new("TextButton")
	button.BorderSizePixel = 0
	button.Size = UDim2.fromOffset(BUTTON_MIN_WIDTH, BUTTON_HEIGHT)
	button.AutomaticSize = Enum.AutomaticSize.X
	button.Font = Enum.Font.SourceSansBold
	button.TextSize = BUTTON_TEXT_SIZE
	button.Text = text
	addPadding(button, 16, 0)
	addCorner(button, 6)

	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = Color3.new(0, 0, 0)
	stroke.Transparency = 0.6
	stroke.Parent = button

	local function setEnabled(enabled: boolean, enabledColor: Color3)
		button.AutoButtonColor = enabled
		button.BackgroundColor3 = if enabled then enabledColor else DISABLED_BUTTON
		button.TextColor3 = if enabled then Color3.new(1, 1, 1) else DISABLED_TEXT
	end
	setEnabled(true, color)
	return button, setEnabled
end

function ViewportOverlay.new()
	local self = setmetatable({}, ViewportOverlay)
	self._maid = SDK.Maid.new()
	self._buttonMaid = self._maid:add(SDK.Maid.new())
	self._buttons = {} -- reason -> { spec, enabled, disabledTooltip, setEnabled, button }
	self._hovered = nil :: any
	self._confirm = nil :: any -- { maid, resolve } while the dialog is open
	self._progress = nil :: any -- { maid } while the progress dialog is open
	self._busy = false -- shutdown buttons greyed out while a shutdown request runs
	self._chip = nil :: Chip? -- what the chip shows (nil: hidden)
	self._chipUi = nil :: any -- { frame, label, menuButton } once created
	self._chipHovered = false
	self._menuMaid = self._maid:add(SDK.Maid.new()) -- the open menu
	self._menuOpen = false

	local gui = Instance.new("ScreenGui")
	gui.Name = "StudioToolsOverlay"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 100
	gui.Enabled = false
	gui.Parent = CoreGui
	self.gui = self._maid:add(gui)

	local bar = Instance.new("Frame")
	bar.Name = "ShutdownButtons"
	bar.BackgroundTransparency = 1
	bar.AnchorPoint = Vector2.new(0.5, 1)
	bar.Position = UDim2.new(0.5, 0, 1, -BOTTOM_MARGIN)
	bar.Size = UDim2.fromOffset(0, BUTTON_HEIGHT)
	bar.AutomaticSize = Enum.AutomaticSize.X
	bar.Visible = false
	bar.Parent = gui
	self.bar = bar

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 8)
	layout.Parent = bar

	local tooltip = Instance.new("TextLabel")
	tooltip.Name = "Tooltip"
	tooltip.AnchorPoint = Vector2.new(0.5, 1)
	tooltip.Position = UDim2.new(0.5, 0, 1, -(BOTTOM_MARGIN + BUTTON_HEIGHT + 8))
	tooltip.AutomaticSize = Enum.AutomaticSize.XY
	tooltip.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	tooltip.BackgroundTransparency = 0.1
	tooltip.BorderSizePixel = 0
	tooltip.Font = Enum.Font.SourceSans
	tooltip.TextSize = 15
	tooltip.TextColor3 = Color3.new(1, 1, 1)
	tooltip.Visible = false
	tooltip.Parent = gui
	addPadding(tooltip, 8, 4)
	addCorner(tooltip, 4)
	self.tooltip = tooltip

	return self
end

function ViewportOverlay:_updateGuiEnabled()
	self.gui.Enabled = self.bar.Visible or self._confirm ~= nil or self._progress ~= nil or self._chip ~= nil
end

-- Shutdown buttons --------------------------------------------------------

function ViewportOverlay:_tooltipFor(reason: string): string?
	local state = self._buttons[reason]
	if not state then
		return nil
	end
	if self._busy then
		return BUSY_TOOLTIP
	end
	if not state.enabled and state.disabledTooltip then
		return state.disabledTooltip
	end
	return state.spec.tooltip
end

function ViewportOverlay:_refreshTooltip()
	local text = if self._hovered then self:_tooltipFor(self._hovered) else nil
	self.tooltip.Text = text or ""
	self.tooltip.Visible = text ~= nil and text ~= ""
end

-- Shows the given shutdown buttons (replacing any current ones).
-- onClick(reason) fires when an enabled button is clicked.
function ViewportOverlay:showShutdownButtons(buttons: { Button }, onClick: (string) -> ())
	self:hideShutdownButtons()
	for index, spec in buttons do
		local color = SHUTDOWN_COLORS[spec.reason] or GREEN
		local button, setEnabled = makeButton(spec.text, color)
		button.Name = spec.reason
		button.LayoutOrder = index
		local state = { spec = spec, enabled = true, disabledTooltip = nil, color = color, setEnabled = setEnabled }
		self._buttons[spec.reason] = state

		button.MouseEnter:Connect(function()
			self._hovered = spec.reason
			self:_refreshTooltip()
		end)
		button.MouseLeave:Connect(function()
			if self._hovered == spec.reason then
				self._hovered = nil
				self:_refreshTooltip()
			end
		end)
		button.Activated:Connect(function()
			if state.enabled and not self._busy and not self._confirm and not self._progress then
				onClick(spec.reason)
			end
		end)

		button.Parent = self.bar
		self._buttonMaid:add(button)
	end
	self.bar.Visible = true
	self:_updateGuiEnabled()
end

-- Enables or disables one shutdown button; `why` is shown as its tooltip while disabled.
function ViewportOverlay:setShutdownButtonEnabled(reason: string, enabled: boolean, why: string?)
	local state = self._buttons[reason]
	if not state or (state.enabled == enabled and state.disabledTooltip == why) then
		return
	end
	state.enabled = enabled
	state.disabledTooltip = why
	state.setEnabled(enabled and not self._busy, state.color)
	if self._hovered == reason then
		self:_refreshTooltip()
	end
end

-- Greys out all the shutdown buttons (and ignores clicks on them) while a
-- shutdown request is being handled, then puts their own states back.
function ViewportOverlay:setShutdownButtonsBusy(busy: boolean)
	if self._busy == busy then
		return
	end
	self._busy = busy
	for _, state in self._buttons do
		state.setEnabled(state.enabled and not busy, state.color)
	end
	self:_refreshTooltip()
end

function ViewportOverlay:hideShutdownButtons()
	self._buttonMaid:clean()
	table.clear(self._buttons)
	self._hovered = nil
	self.tooltip.Visible = false
	self.bar.Visible = false
	self:_updateGuiEnabled()
end

-- Confirmation dialog -----------------------------------------------------

function ViewportOverlay:isConfirmOpen(): boolean
	return self._confirm ~= nil
end

-- Closes the open dialog (if any), answering `answer`.
function ViewportOverlay:resolveConfirm(answer: boolean)
	local confirm = self._confirm
	if confirm then
		confirm.resolve(answer)
	end
end

-- Shows a modal confirmation dialog and yields until it's answered.
-- Returns false immediately if another dialog is already open. With
-- `single`, there's only the confirm button (an alert).
function ViewportOverlay:confirm(options: SDK.ConfirmOptions, single: boolean?): boolean
	if self._confirm then
		return false
	end

	local maid = SDK.Maid.new()
	local thread = coroutine.running()
	local answered = false
	local confirmState = { maid = maid }
	function confirmState.resolve(answer: boolean)
		if answered then
			return
		end
		answered = true
		self._confirm = nil
		maid:clean()
		self:_updateGuiEnabled()
		task.spawn(thread, answer)
	end
	self._confirm = confirmState

	-- Dim the viewport behind the dialog.
	local shade = Instance.new("Frame")
	shade.Name = "ConfirmShade"
	shade.BackgroundColor3 = Color3.new(0, 0, 0)
	-- over a progress dialog, which already dims the viewport
	shade.BackgroundTransparency = if self._progress then 1 else 0.6
	shade.BorderSizePixel = 0
	shade.Active = true -- swallows clicks meant for the buttons behind it
	shade.Size = UDim2.fromScale(1, 1)
	shade.ZIndex = 10
	shade.Parent = self.gui
	maid:add(shade)

	local panel = Instance.new("Frame")
	panel.Name = "ConfirmDialog"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(320, 0)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.BackgroundColor3 = PANEL
	panel.BorderSizePixel = 0
	panel.ZIndex = 11
	panel.Parent = shade
	addCorner(panel, 8)
	addPadding(panel, 16, 14)

	local panelLayout = Instance.new("UIListLayout")
	panelLayout.SortOrder = Enum.SortOrder.LayoutOrder
	panelLayout.Padding = UDim.new(0, 10)
	panelLayout.Parent = panel

	local function text(value: string, font: Enum.Font, size: number, order: number)
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 0)
		label.AutomaticSize = Enum.AutomaticSize.Y
		label.Font = font
		label.TextSize = size
		label.TextColor3 = Color3.new(1, 1, 1)
		label.TextWrapped = true
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Text = value
		label.LayoutOrder = order
		label.ZIndex = 12
		label.Parent = panel
	end
	if options.title then
		text(options.title, Enum.Font.SourceSansBold, 19, 1)
	end
	text(options.message, Enum.Font.SourceSans, 16, 2)

	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, BUTTON_HEIGHT)
	row.LayoutOrder = 3
	row.ZIndex = 12
	row.Parent = panel
	local rowLayout = Instance.new("UIListLayout")
	rowLayout.FillDirection = Enum.FillDirection.Horizontal
	rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rowLayout.Padding = UDim.new(0, 8)
	rowLayout.Parent = row

	if not single then
		local cancelButton = makeButton(options.cancelText or "Cancel", GRAY)
		cancelButton.LayoutOrder = 1
		cancelButton.ZIndex = 13
		cancelButton.Parent = row
		cancelButton.Activated:Connect(function()
			confirmState.resolve(false)
		end)
	end

	local confirmButton = makeButton(options.confirmText or "OK", BLUE)
	confirmButton.LayoutOrder = 2
	confirmButton.ZIndex = 13
	confirmButton.Parent = row
	confirmButton.Activated:Connect(function()
		confirmState.resolve(true)
	end)

	self:_updateGuiEnabled()
	return coroutine.yield()
end

-- Progress dialog ----------------------------------------------------------

function ViewportOverlay:isProgressOpen(): boolean
	return self._progress ~= nil
end

-- Shows a modal dialog with a message and an animated bar, for work the user
-- has to wait for. It stays until close() is called on the returned handle
-- (or hide()); opening another replaces it. Drawn under confirm dialogs, so
-- a confirm or alert can be shown while it's open.
function ViewportOverlay:showProgress(options: SDK.ProgressOptions): SDK.ProgressHandle
	self:_closeProgress()
	local maid = SDK.Maid.new()
	local progress = { maid = maid }
	self._progress = progress

	local shade = Instance.new("Frame")
	shade.Name = "ProgressShade"
	shade.BackgroundColor3 = Color3.new(0, 0, 0)
	shade.BackgroundTransparency = 0.6
	shade.BorderSizePixel = 0
	shade.Active = true -- swallows clicks meant for the buttons behind it
	shade.Size = UDim2.fromScale(1, 1)
	shade.ZIndex = 5
	shade.Parent = self.gui
	maid:add(shade)

	local panel = Instance.new("Frame")
	panel.Name = "ProgressDialog"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(320, 0)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.BackgroundColor3 = PANEL
	panel.BorderSizePixel = 0
	panel.ZIndex = 6
	panel.Parent = shade
	addCorner(panel, 8)
	addPadding(panel, 16, 14)

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 10)
	layout.Parent = panel

	local function text(value: string, font: Enum.Font, size: number, order: number): TextLabel
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 0)
		label.AutomaticSize = Enum.AutomaticSize.Y
		label.Font = font
		label.TextSize = size
		label.TextColor3 = Color3.new(1, 1, 1)
		label.TextWrapped = true
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Text = value
		label.LayoutOrder = order
		label.ZIndex = 7
		label.Parent = panel
		return label
	end
	if options.title then
		text(options.title, Enum.Font.SourceSansBold, 19, 1)
	end
	local message = text(options.message, Enum.Font.SourceSans, 16, 2)

	-- An indeterminate bar: a block sliding across a track.
	local track = Instance.new("Frame")
	track.Name = "Track"
	track.BackgroundColor3 = Color3.fromRGB(70, 70, 72)
	track.BorderSizePixel = 0
	track.ClipsDescendants = true
	track.Size = UDim2.new(1, 0, 0, 4)
	track.LayoutOrder = 3
	track.ZIndex = 7
	track.Parent = panel
	addCorner(track, 2)
	local block = Instance.new("Frame")
	block.BackgroundColor3 = BLUE
	block.BorderSizePixel = 0
	block.Size = UDim2.fromScale(0.3, 1)
	block.ZIndex = 8
	block.Parent = track
	addCorner(block, 2)
	local started = os.clock()
	maid:add(RunService.Heartbeat:Connect(function()
		local phase = ((os.clock() - started) * 0.7) % 1
		block.Position = UDim2.fromScale(phase * 1.3 - 0.3, 0)
	end))

	self:_updateGuiEnabled()

	local handle = {}
	function handle.setMessage(_handle: any, value: string)
		if self._progress == progress then
			message.Text = value
		end
	end
	function handle.close(_handle: any)
		if self._progress == progress then
			self:_closeProgress()
		end
	end
	return handle :: any
end

function ViewportOverlay:_closeProgress()
	local progress = self._progress
	if progress then
		self._progress = nil
		progress.maid:clean()
		self:_updateGuiEnabled()
	end
end

-- A modal message with one button; yields until it's dismissed (the button,
-- Escape, or the tool shutting down). Returns immediately if another dialog
-- is already open.
function ViewportOverlay:alert(options: SDK.AlertOptions)
	self:confirm({ title = options.title, message = options.message, confirmText = options.buttonText or "OK" }, true)
end

-- Chip ----------------------------------------------------------------------

-- Shows the chip (or updates it), or hides it with nil. An open menu is
-- rebuilt with the new items.
function ViewportOverlay:setChip(chip: Chip?)
	self._chip = chip
	if not chip then
		self:closeMenu()
		if self._chipUi then
			self._chipUi.frame.Visible = false
		end
		self._chipHovered = false
		self:_updateGuiEnabled()
		return
	end
	local ui = self._chipUi or self:_createChip()
	ui.label.Text = chip.text
	ui.frame.Visible = true
	if self._menuOpen then
		self:_openMenu()
	end
	self:_updateGuiEnabled()
end

function ViewportOverlay:_createChip()
	local frame = Instance.new("Frame")
	frame.Name = "Chip"
	frame.AnchorPoint = Vector2.new(1, 1)
	frame.Position = UDim2.new(1, -CHIP_MARGIN, 1, -BOTTOM_MARGIN)
	frame.Size = UDim2.fromOffset(0, BUTTON_HEIGHT)
	frame.AutomaticSize = Enum.AutomaticSize.X
	frame.BackgroundColor3 = CHIP_COLOR
	frame.BorderSizePixel = 0
	frame.Active = true -- clicks on the label don't reach the viewport
	frame.ZIndex = 2
	frame.Parent = self.gui
	addCorner(frame, 6)
	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = Color3.new(0, 0, 0)
	stroke.Transparency = 0.6
	stroke.Parent = frame
	frame.MouseEnter:Connect(function()
		self._chipHovered = true
	end)
	frame.MouseLeave:Connect(function()
		self._chipHovered = false
	end)

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = frame

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromOffset(0, BUTTON_HEIGHT)
	label.AutomaticSize = Enum.AutomaticSize.X
	label.Font = Enum.Font.SourceSansBold
	label.TextSize = 17
	label.TextColor3 = Color3.new(1, 1, 1)
	label.LayoutOrder = 1
	label.ZIndex = 3
	label.Parent = frame
	local labelPadding = Instance.new("UIPadding")
	labelPadding.PaddingLeft = UDim.new(0, 12)
	labelPadding.PaddingRight = UDim.new(0, 10)
	labelPadding.Parent = label

	local divider = Instance.new("Frame")
	divider.BackgroundColor3 = Color3.new(0, 0, 0)
	divider.BackgroundTransparency = 0.65
	divider.BorderSizePixel = 0
	divider.Size = UDim2.fromOffset(1, BUTTON_HEIGHT - 10)
	divider.LayoutOrder = 2
	divider.ZIndex = 3
	divider.Parent = frame

	-- the menu button: three vertical dots
	local menuButton = Instance.new("TextButton")
	menuButton.Name = "MenuButton"
	menuButton.Text = ""
	menuButton.AutoButtonColor = false
	menuButton.BackgroundColor3 = CHIP_BUTTON_HOVER
	menuButton.BackgroundTransparency = 1
	menuButton.BorderSizePixel = 0
	menuButton.Size = UDim2.fromOffset(28, BUTTON_HEIGHT)
	menuButton.LayoutOrder = 3
	menuButton.ZIndex = 3
	menuButton.Parent = frame
	addCorner(menuButton, 6)
	for i = -1, 1 do
		local dot = Instance.new("Frame")
		dot.AnchorPoint = Vector2.new(0.5, 0.5)
		dot.Position = UDim2.new(0.5, 0, 0.5, i * 6)
		dot.Size = UDim2.fromOffset(4, 4)
		dot.BackgroundColor3 = Color3.new(1, 1, 1)
		dot.BorderSizePixel = 0
		dot.ZIndex = 4
		dot.Parent = menuButton
		addCorner(dot, 2)
	end
	local hovered = false
	local function refreshButton()
		menuButton.BackgroundTransparency = if hovered or self._menuOpen then 0 else 1
	end
	menuButton.MouseEnter:Connect(function()
		hovered = true
		refreshButton()
	end)
	menuButton.MouseLeave:Connect(function()
		hovered = false
		refreshButton()
	end)
	menuButton.Activated:Connect(function()
		if self._confirm or self._progress then
			return
		end
		if self._menuOpen then
			self:closeMenu()
		else
			self:_openMenu()
		end
	end)

	self._chipUi = { frame = frame, label = label, refreshButton = refreshButton }
	return self._chipUi
end

function ViewportOverlay:isMenuOpen(): boolean
	return self._menuOpen
end

function ViewportOverlay:closeMenu()
	if not self._menuOpen then
		return
	end
	self._menuOpen = false
	self._menuMaid:clean()
	if self._chipUi then
		self._chipUi.refreshButton()
	end
end

-- Opens (or rebuilds) the chip's menu above the chip.
function ViewportOverlay:_openMenu()
	local chip = self._chip
	if not chip then
		return
	end
	self._menuMaid:clean()
	self._menuOpen = true
	local maid = self._menuMaid

	-- a click anywhere else closes the menu
	local catcher = Instance.new("TextButton")
	catcher.Name = "MenuCatcher"
	catcher.Text = ""
	catcher.AutoButtonColor = false
	catcher.BackgroundTransparency = 1
	catcher.Size = UDim2.fromScale(1, 1)
	catcher.ZIndex = 3
	catcher.Parent = self.gui
	catcher.Activated:Connect(function()
		self:closeMenu()
	end)
	maid:add(catcher)

	local menu = Instance.new("Frame")
	menu.Name = "ChipMenu"
	menu.AnchorPoint = Vector2.new(1, 1)
	menu.Position = UDim2.new(1, -CHIP_MARGIN, 1, -(BOTTOM_MARGIN + BUTTON_HEIGHT + 6))
	menu.Size = UDim2.fromOffset(MENU_WIDTH, 0)
	menu.AutomaticSize = Enum.AutomaticSize.Y
	menu.BackgroundColor3 = PANEL
	menu.BorderSizePixel = 0
	menu.Active = true
	menu.ZIndex = 4
	menu.Parent = self.gui
	maid:add(menu)
	addCorner(menu, 6)
	addPadding(menu, 4, 4)
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.new(0, 0, 0)
	stroke.Transparency = 0.5
	stroke.Parent = menu
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 2)
	layout.Parent = menu

	-- the hovered item's tooltip, left of the menu and level with the item
	local tooltip = Instance.new("TextLabel")
	tooltip.Name = "ChipMenuTooltip"
	tooltip.AnchorPoint = Vector2.new(1, 0)
	tooltip.Size = UDim2.fromOffset(MENU_TOOLTIP_WIDTH, 0)
	tooltip.AutomaticSize = Enum.AutomaticSize.Y
	tooltip.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	tooltip.BackgroundTransparency = 0.1
	tooltip.BorderSizePixel = 0
	tooltip.Font = Enum.Font.SourceSans
	tooltip.TextSize = 15
	tooltip.TextColor3 = Color3.new(1, 1, 1)
	tooltip.TextWrapped = true
	tooltip.TextXAlignment = Enum.TextXAlignment.Left
	tooltip.Visible = false
	tooltip.ZIndex = 8
	tooltip.Parent = self.gui
	maid:add(tooltip)
	addPadding(tooltip, 8, 5)
	addCorner(tooltip, 4)
	local tooltipFor: GuiObject? = nil
	local function showTooltip(text: string?, button: GuiObject)
		tooltipFor = if text then button else nil
		tooltip.Visible = text ~= nil
		if text then
			tooltip.Text = text
			local origin = self.gui.AbsolutePosition
			tooltip.Position = UDim2.fromOffset(menu.AbsolutePosition.X - origin.X - 6, button.AbsolutePosition.Y - origin.Y)
		end
	end

	for index, item in chip.items do
		local enabled = item.enabled ~= false
		local textColor = if enabled then Color3.new(1, 1, 1) else DISABLED_TEXT
		local button = Instance.new("TextButton")
		button.Name = item.key
		button.Text = ""
		button.AutoButtonColor = false
		button.BackgroundColor3 = MENU_HOVER
		button.BackgroundTransparency = 1
		button.BorderSizePixel = 0
		button.Size = UDim2.new(1, 0, 0, MENU_ITEM_HEIGHT)
		button.AutomaticSize = Enum.AutomaticSize.Y
		button.LayoutOrder = index
		button.ZIndex = 5
		button.Parent = menu
		addCorner(button, 4)
		local itemPadding = Instance.new("UIPadding")
		itemPadding.PaddingLeft = UDim.new(0, if item.checked ~= nil then 32 else 10)
		itemPadding.PaddingRight = UDim.new(0, 10)
		itemPadding.PaddingTop = UDim.new(0, 5)
		itemPadding.PaddingBottom = UDim.new(0, 5)
		itemPadding.Parent = button
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 0)
		label.AutomaticSize = Enum.AutomaticSize.Y
		label.Font = Enum.Font.SourceSans
		label.TextSize = 16
		label.TextColor3 = textColor
		label.TextWrapped = true
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Text = item.text
		label.ZIndex = 6
		label.Parent = button

		if item.checked ~= nil then
			-- a checkbox in the left padding, centered on the first line
			local box = Instance.new("Frame")
			box.AnchorPoint = Vector2.new(0, 0.5)
			box.Position = UDim2.new(0, -22, 0, 9)
			box.Size = UDim2.fromOffset(14, 14)
			box.BackgroundTransparency = 1
			box.ZIndex = 6
			box.Parent = button
			addCorner(box, 3)
			local boxStroke = Instance.new("UIStroke")
			boxStroke.Color = textColor
			boxStroke.Thickness = 1.5
			boxStroke.Parent = box
			if item.checked then
				local fill = Instance.new("Frame")
				fill.AnchorPoint = Vector2.new(0.5, 0.5)
				fill.Position = UDim2.fromScale(0.5, 0.5)
				fill.Size = UDim2.fromOffset(8, 8)
				fill.BackgroundColor3 = CHIP_COLOR:Lerp(Color3.new(1, 1, 1), 0.25)
				fill.BorderSizePixel = 0
				fill.ZIndex = 7
				fill.Parent = box
				addCorner(fill, 2)
			end
		end

		button.MouseEnter:Connect(function()
			if enabled then
				button.BackgroundTransparency = 0
			end
			showTooltip(item.tooltip, button)
		end)
		button.MouseLeave:Connect(function()
			button.BackgroundTransparency = 1
			if tooltipFor == button then
				showTooltip(nil, button)
			end
		end)
		if enabled then
			button.Activated:Connect(function()
				self:closeMenu()
				chip.onSelect(item.key)
			end)
		end
	end

	if self._chipUi then
		self._chipUi.refreshButton()
	end
end

-- Input -------------------------------------------------------------------

-- True while viewport clicks should not reach the active tool: the mouse is
-- over a shutdown button or the chip, or a dialog or the chip's menu is open
-- (they're modal).
function ViewportOverlay:isBlockingInput(): boolean
	return self._hovered ~= nil or self._confirm ~= nil or self._progress ~= nil or self._chipHovered or self._menuOpen
end

-- Hides everything but the chip, answering false to an open dialog.
function ViewportOverlay:hide()
	self:closeMenu()
	self:resolveConfirm(false)
	self:_closeProgress()
	self:setShutdownButtonsBusy(false)
	self:hideShutdownButtons()
end

function ViewportOverlay:destroy()
	self:hide()
	self._maid:clean()
end

return ViewportOverlay
