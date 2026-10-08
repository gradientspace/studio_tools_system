--[[
	ChatPanel: the "Tools Agent" chat box in the viewport (backed by a
	headless coding agent on the server; the UI deliberately doesn't say which).

	A "Tools Agent" button at the bottom-left of the viewport opens a chat box.
	By default it's compact: an entry field, a Send button, and a one-line
	preview of the latest reply or of what the agent is doing. The history
	button expands it into the full conversation (with "New chat").

	The conversation lives on the dev server (server/chat.js), which runs
	the agent; this panel sends messages and long-polls for updates, so hot
	reloads and Studio restarts don't lose anything. When the server reports
	the agent unavailable, the input is disabled and the reason is shown.

	Drawn in its own ScreenGui in CoreGui. isBlockingInput() keeps viewport
	clicks on the chat from reaching the active tool.
]]

local CoreGui = game:GetService("CoreGui")
local HttpService = game:GetService("HttpService")

local SDK = require(script.Parent.Parent.SDK)
local ServerApi = require(script.Parent.ServerApi)

local MARGIN = 12
local LAUNCHER_HEIGHT = 24
local PANEL_WIDTH = 400
local HISTORY_HEIGHT = 320
local ROW_HEIGHT = 28
local RETRY_DELAY = 3

-- Fixed dark colors: the chat sits on top of the 3D scene.
local COLORS = {
	panel = Color3.fromRGB(37, 37, 38),
	field = Color3.fromRGB(24, 24, 25),
	userBubble = Color3.fromRGB(52, 58, 70),
	text = Color3.fromRGB(235, 235, 235),
	dim = Color3.fromRGB(150, 150, 150),
	error = Color3.fromRGB(255, 110, 110),
	send = Color3.fromRGB(0, 122, 204),
	stop = Color3.fromRGB(200, 55, 55),
	button = Color3.fromRGB(70, 70, 72),
}

local ChatPanel = {}
ChatPanel.__index = ChatPanel

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

local function corner(radius: number): UICorner
	return create("UICorner", { CornerRadius = UDim.new(0, radius) })
end

local function padding(horizontal: number, vertical: number): UIPadding
	return create("UIPadding", {
		PaddingLeft = UDim.new(0, horizontal),
		PaddingRight = UDim.new(0, horizontal),
		PaddingTop = UDim.new(0, vertical),
		PaddingBottom = UDim.new(0, vertical),
	})
end

local function smallButton(text: string, color: Color3?): TextButton
	return create("TextButton", {
		AutoButtonColor = true,
		BackgroundColor3 = color or COLORS.button,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(0, ROW_HEIGHT - 6),
		AutomaticSize = Enum.AutomaticSize.X,
		Font = Enum.Font.SourceSansBold,
		TextSize = 14,
		TextColor3 = Color3.new(1, 1, 1),
		Text = text,
	}, { corner(4), padding(8, 0) })
end

local function contains(gui: GuiObject, x: number, y: number): boolean
	if not gui.Visible then
		return false
	end
	local position, size = gui.AbsolutePosition, gui.AbsoluteSize
	return x >= position.X and x <= position.X + size.X and y >= position.Y and y <= position.Y + size.Y
end

function ChatPanel.new(host: any)
	local self = setmetatable({}, ChatPanel)
	self.host = host
	self._maid = SDK.Maid.new()
	self._alive = true
	host.persist.chat = host.persist.chat or { open = false, expanded = false }
	self._ui = host.persist.chat

	-- Conversation mirror (the server is the source of truth).
	self._conversationId = ""
	self._revision = 0
	self._lastId = 0
	self._messages = {}
	self._running = false
	self._activity = ""
	self._unavailableReason = nil :: string? -- set while the server says the agent can't run
	self._problem = nil :: string? -- connection or request problem to show
	self._historyDirty = true
	self._hovered = {} :: { [Instance]: boolean }

	self:_build()
	self:_update()
	task.spawn(function()
		self:_pollLoop()
	end)
	return self
end

-- UI construction ------------------------------------------------------------

function ChatPanel:_trackHover(gui: GuiObject)
	gui.MouseEnter:Connect(function()
		self._hovered[gui] = true
	end)
	gui.MouseLeave:Connect(function()
		self._hovered[gui] = nil
	end)
end

function ChatPanel:_build()
	local gui = create("ScreenGui", {
		Name = "StudioToolsChat",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 101,
		Parent = CoreGui,
	})
	self.gui = self._maid:add(gui)

	-- Launcher -----------------------------------------------------------
	local launcher = create("TextButton", {
		Name = "Launcher",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, MARGIN, 1, -MARGIN),
		Size = UDim2.fromOffset(0, LAUNCHER_HEIGHT),
		AutomaticSize = Enum.AutomaticSize.X,
		AutoButtonColor = true,
		BackgroundColor3 = COLORS.panel,
		BorderSizePixel = 0,
		Font = Enum.Font.SourceSansBold,
		TextSize = 15,
		TextColor3 = COLORS.text,
		Text = "Tools Agent",
		Parent = gui,
	}, { corner(6), padding(12, 0) })
	self.launcher = launcher
	self:_trackHover(launcher)
	launcher.Activated:Connect(function()
		self:_setOpen(not self._ui.open)
	end)

	-- Panel ----------------------------------------------------------------
	local panel = create("Frame", {
		Name = "Panel",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, MARGIN, 1, -(MARGIN + LAUNCHER_HEIGHT + 8)),
		Size = UDim2.fromOffset(PANEL_WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = COLORS.panel,
		BorderSizePixel = 0,
		Parent = gui,
	}, {
		corner(8),
		padding(8, 8),
		create("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6) }),
	})
	self.panel = panel
	self:_trackHover(panel)

	-- 1: history header (expanded)
	local header = create("Frame", {
		Name = "Header",
		LayoutOrder = 1,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, ROW_HEIGHT - 6),
		Parent = panel,
	})
	create("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(0.5, 1),
		Font = Enum.Font.SourceSansBold,
		TextSize = 15,
		TextColor3 = COLORS.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "Tools Agent",
		Parent = header,
	})
	local headerButtons = create("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromScale(0.5, 1),
		Parent = header,
	}, {
		create("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Right,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 6),
		}),
	})
	local newChatButton = smallButton("New chat")
	newChatButton.LayoutOrder = 1
	newChatButton.Parent = headerButtons
	newChatButton.Activated:Connect(function()
		self:_post("/chat/reset", nil)
	end)
	local collapseButton = smallButton("Collapse")
	collapseButton.LayoutOrder = 2
	collapseButton.Parent = headerButtons
	collapseButton.Activated:Connect(function()
		self:_setExpanded(false)
	end)
	self.header = header

	-- 2: history (expanded)
	local history = create("ScrollingFrame", {
		Name = "History",
		LayoutOrder = 2,
		BackgroundColor3 = COLORS.field,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, HISTORY_HEIGHT),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 6,
		Parent = panel,
	}, { corner(4) })
	self.history = history
	-- Keep scrolled to the bottom as content grows, unless the user scrolled up.
	history:GetPropertyChangedSignal("AbsoluteCanvasSize"):Connect(function()
		if self._stickToBottom then
			history.CanvasPosition = Vector2.new(0, math.max(0, history.AbsoluteCanvasSize.Y - history.AbsoluteWindowSize.Y))
		end
	end)
	history:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
		local bottom = history.AbsoluteCanvasSize.Y - history.AbsoluteWindowSize.Y
		self._stickToBottom = history.CanvasPosition.Y >= bottom - 4
	end)
	self._stickToBottom = true

	-- 3: one-line preview / status, with the expand button
	local preview = create("Frame", {
		Name = "Preview",
		LayoutOrder = 3,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, ROW_HEIGHT - 6),
		Parent = panel,
	})
	local previewText = create("TextButton", {
		Name = "Text",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -76, 1, 0),
		Font = Enum.Font.SourceSans,
		TextSize = 15,
		TextColor3 = COLORS.dim,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = "",
		Parent = preview,
	})
	previewText.Activated:Connect(function()
		if #self._messages > 0 then
			self:_setExpanded(true)
		end
	end)
	local expandButton = smallButton("History")
	expandButton.AnchorPoint = Vector2.new(1, 0)
	expandButton.Position = UDim2.fromScale(1, 0)
	expandButton.Parent = preview
	expandButton.Activated:Connect(function()
		self:_setExpanded(true)
	end)
	self.preview = preview
	self.previewText = previewText
	self.expandButton = expandButton

	-- 4: input row
	local inputRow = create("Frame", {
		Name = "Input",
		LayoutOrder = 4,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
		Parent = panel,
	})
	local input = create("TextBox", {
		Name = "Field",
		BackgroundColor3 = COLORS.field,
		BorderSizePixel = 0,
		Size = UDim2.new(1, -70, 1, 0),
		ClearTextOnFocus = false,
		Font = Enum.Font.SourceSans,
		TextSize = 15,
		TextColor3 = COLORS.text,
		PlaceholderText = "What would you like to change?",
		PlaceholderColor3 = COLORS.dim,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = "",
		Parent = inputRow,
	}, { corner(4), padding(8, 0) })
	input.FocusLost:Connect(function(enterPressed)
		if enterPressed then
			self:_send()
		end
	end)
	local sendButton = create("TextButton", {
		Name = "Send",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0, 64, 1, 0),
		AutoButtonColor = true,
		BackgroundColor3 = COLORS.send,
		BorderSizePixel = 0,
		Font = Enum.Font.SourceSansBold,
		TextSize = 15,
		TextColor3 = Color3.new(1, 1, 1),
		Text = "Send",
		Parent = inputRow,
	}, { corner(4) })
	sendButton.Activated:Connect(function()
		if self._running then
			self:_post("/chat/stop", nil)
		else
			self:_send()
		end
	end)
	self.input = input
	self.sendButton = sendButton
end

-- Rendering --------------------------------------------------------------------

local ROLE_STYLES = {
	user = { font = Enum.Font.SourceSans, color = COLORS.text, background = COLORS.userBubble },
	assistant = { font = Enum.Font.SourceSans, color = COLORS.text, selectable = true },
	tool = { font = Enum.Font.SourceSans, color = COLORS.dim, prefix = "› ", size = 13 },
	info = { font = Enum.Font.SourceSansItalic, color = COLORS.dim },
	error = { font = Enum.Font.SourceSans, color = COLORS.error },
}

function ChatPanel:_messageView(message: any, order: number): GuiObject
	local style = ROLE_STYLES[message.role] or ROLE_STYLES.info
	-- Assistant replies are read-only TextBoxes so their text can be selected and copied.
	local view = create(if style.selectable then "TextBox" else "TextLabel", {
		LayoutOrder = order,
		BackgroundColor3 = style.background or COLORS.field,
		BackgroundTransparency = if style.background then 0 else 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Font = style.font,
		TextSize = style.size or 15,
		TextColor3 = style.color,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Text = (style.prefix or "") .. message.text,
	}, { corner(4), padding(6, 3) })
	if style.selectable then
		view.TextEditable = false
		view.ClearTextOnFocus = false
	end
	return view
end

function ChatPanel:_renderHistory()
	self._historyDirty = false
	self.history:ClearAllChildren()
	corner(4).Parent = self.history
	create("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4), Parent = self.history })
	create("UIPadding", {
		PaddingLeft = UDim.new(0, 6),
		PaddingRight = UDim.new(0, 10),
		PaddingTop = UDim.new(0, 6),
		PaddingBottom = UDim.new(0, 6),
		Parent = self.history,
	})
	for index, message in self._messages do
		-- Command runs aren't useful to show here (older conversations stored them).
		if not (message.role == "tool" and string.sub(message.text, 1, 5) == "Run: ") then
			self:_messageView(message, index).Parent = self.history
		end
	end
	if self._running then
		create("TextLabel", {
			LayoutOrder = #self._messages + 1,
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Font = Enum.Font.SourceSansItalic,
			TextSize = 14,
			TextColor3 = COLORS.dim,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = "Working… " .. self._activity,
			Parent = self.history,
		})
	end
	self._stickToBottom = true
end

-- The one-line summary shown in compact mode.
function ChatPanel:_previewLine(): (string, Color3)
	if self._problem then
		return self._problem, COLORS.error
	end
	if self._unavailableReason then
		return self._unavailableReason, COLORS.dim
	end
	if self._running then
		return "Working… " .. self._activity, COLORS.dim
	end
	for i = #self._messages, 1, -1 do
		local message = self._messages[i]
		if message.role == "assistant" then
			return (string.gsub(message.text, "%s+", " ")), COLORS.text
		elseif message.role == "error" then
			return message.text, COLORS.error
		end
	end
	return "", COLORS.dim
end

function ChatPanel:_update()
	local ui = self._ui
	local expanded = ui.expanded and #self._messages > 0
	self.panel.Visible = ui.open
	self.header.Visible = expanded
	self.history.Visible = expanded
	if expanded and self._historyDirty then
		self:_renderHistory()
	end

	local text, color = self:_previewLine()
	if expanded then
		-- In the expanded view the history shows everything; keep only problems.
		text = self._problem or self._unavailableReason or ""
	end
	self.previewText.Text = text
	self.previewText.TextColor3 = color
	self.expandButton.Visible = not expanded and #self._messages > 0
	self.preview.Visible = text ~= "" or self.expandButton.Visible

	local unavailable = self._unavailableReason ~= nil and not self._running
	self.input.TextEditable = not unavailable
	self.input.PlaceholderText = if unavailable then "Unavailable" else "What would you like to change?"
	self.sendButton.Text = if self._running then "Stop" else "Send"
	self.sendButton.BackgroundColor3 = if self._running then COLORS.stop elseif unavailable then COLORS.button else COLORS.send
	self.sendButton.AutoButtonColor = not unavailable
	self.sendButton.TextColor3 = if unavailable then COLORS.dim else Color3.new(1, 1, 1)
	self.launcher.Text = if self._running then "Tools Agent …" else "Tools Agent"
end

function ChatPanel:_setOpen(open: boolean)
	self._ui.open = open
	self:_update()
	if open then
		self.input:CaptureFocus()
	end
end

function ChatPanel:_setExpanded(expanded: boolean)
	self._ui.expanded = expanded
	self._historyDirty = true
	self:_update()
end

-- Server -------------------------------------------------------------------------

function ChatPanel:_post(path: string, body: any?)
	task.spawn(function()
		local ok, result = ServerApi.request(self.host.serverUrl, "POST", path, body)
		if not self._alive then
			return
		end
		self._problem = if ok then nil else tostring(result)
		self:_update()
	end)
end

function ChatPanel:_send()
	local text = self.input.Text
	if self._running or self._unavailableReason or not string.find(text, "%S") then
		return
	end
	task.spawn(function()
		local ok, result = ServerApi.request(self.host.serverUrl, "POST", "/chat", { message = text })
		if not self._alive then
			return
		end
		if ok then
			self._problem = nil
			if self.input.Text == text then
				self.input.Text = ""
			end
		else
			self._problem = tostring(result)
		end
		self:_update()
	end)
end

function ChatPanel:_apply(data: any)
	if data.reset or data.conversationId ~= self._conversationId then
		self._messages = {}
		self._lastId = 0
		self._conversationId = data.conversationId or ""
	end
	for _, message in data.messages or {} do
		table.insert(self._messages, message)
		self._lastId = math.max(self._lastId, message.id)
	end
	self._revision = data.revision or self._revision
	self._running = data.running == true
	self._activity = data.activity or ""
	-- Older servers don't send `available`; treat that as available.
	self._unavailableReason = if data.available == false
		then (if type(data.unavailableReason) == "string" then data.unavailableReason else "The Tools Agent isn't available.")
		else nil
	self._historyDirty = true
	self:_update()
end

function ChatPanel:_pollLoop()
	while self._alive do
		local path = string.format(
			"/chat/poll?rev=%d&after=%d&conversation=%s",
			self._revision,
			self._lastId,
			HttpService:UrlEncode(self._conversationId)
		)
		local ok, data = ServerApi.request(self.host.serverUrl, "GET", path, nil)
		if not self._alive then
			break
		end
		if ok and type(data) == "table" then
			if self._problem and string.find(self._problem, "^Chat server") then
				self._problem = nil
			end
			self:_apply(data)
		else
			self._problem = "Chat server unavailable: " .. tostring(data)
			self:_update()
			task.wait(RETRY_DELAY)
		end
	end
end

-- Input --------------------------------------------------------------------------

-- True while the mouse is over the launcher or the open chat box.
function ChatPanel:isBlockingInput(): boolean
	if next(self._hovered) ~= nil then
		return true
	end
	local mouse = self.host.plugin:GetMouse()
	return contains(self.launcher, mouse.X, mouse.Y) or (self._ui.open and contains(self.panel, mouse.X, mouse.Y))
end

function ChatPanel:destroy()
	self._alive = false
	self._maid:clean()
end

return ChatPanel
