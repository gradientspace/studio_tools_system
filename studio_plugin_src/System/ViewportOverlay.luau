--[[
	ViewportOverlay: system-owned UI drawn over the 3D viewport.

	  * Shutdown buttons at the bottom-center while a tool is active ("Done",
	    or "Accept"/"Cancel"); buttons can be disabled, with a tooltip saying why.
	  * A modal confirmation dialog (confirm()), used by tools via ctx:confirm().

	It's a ScreenGui in CoreGui, so it draws over the viewport without
	touching the place. ToolManager decides what to show; this module only
	draws it and reports clicks.

	isBlockingInput() lets the InputManager ignore viewport clicks that land
	on the buttons, and all viewport clicks while the dialog is open.
]]

local CoreGui = game:GetService("CoreGui")

local SDK = require(script.Parent.Parent.SDK)

local BUTTON_HEIGHT = 24
local BUTTON_MIN_WIDTH = 96
local BOTTOM_MARGIN = 12

-- Fixed colors rather than Studio theme colors: the overlay sits on top of
-- the 3D scene, which looks the same in light and dark themes.
local GREEN = Color3.fromRGB(46, 160, 67)
local RED = Color3.fromRGB(200, 55, 55)
local BLUE = Color3.fromRGB(0, 122, 204)
local GRAY = Color3.fromRGB(110, 110, 110)
local PANEL = Color3.fromRGB(37, 37, 38)
local DISABLED_BUTTON = Color3.fromRGB(90, 90, 90)
local DISABLED_TEXT = Color3.fromRGB(170, 170, 170)

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
	button.TextSize = 16
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
	self.gui.Enabled = self.bar.Visible or self._confirm ~= nil
end

-- Shutdown buttons --------------------------------------------------------

function ViewportOverlay:_tooltipFor(reason: string): string?
	local state = self._buttons[reason]
	if not state then
		return nil
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
			if state.enabled and not self._confirm then
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
	state.setEnabled(enabled, state.color)
	if self._hovered == reason then
		self:_refreshTooltip()
	end
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
-- Returns false immediately if another dialog is already open.
function ViewportOverlay:confirm(options: SDK.ConfirmOptions): boolean
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
	shade.BackgroundTransparency = 0.6
	shade.BorderSizePixel = 0
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

	local cancelButton = makeButton(options.cancelText or "Cancel", GRAY)
	cancelButton.LayoutOrder = 1
	cancelButton.ZIndex = 13
	cancelButton.Parent = row
	cancelButton.Activated:Connect(function()
		confirmState.resolve(false)
	end)

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

-- Input -------------------------------------------------------------------

-- True while viewport clicks should not reach the active tool: the mouse is
-- over a shutdown button, or the confirmation dialog is open (it's modal).
function ViewportOverlay:isBlockingInput(): boolean
	return self._hovered ~= nil or self._confirm ~= nil
end

-- Hides everything, answering false to an open dialog.
function ViewportOverlay:hide()
	self:resolveConfirm(false)
	self:hideShutdownButtons()
end

function ViewportOverlay:destroy()
	self:hide()
	self._maid:clean()
end

return ViewportOverlay
