--[[
	StudioToolsLoader

	The only piece of the Studio Tools System that is installed as a Studio
	plugin. It owns the things that can't be safely recreated at runtime (the
	toolbar, the dock widget, the Plugin object) and fetches everything else
	(the tool framework and the tools) from the dev server as source code.

	Source files are turned into a tree of ModuleScripts that mirrors the
	bundle's file paths (Rojo-style: a folder with init.luau becomes a
	ModuleScript). The bundle holds studio_plugin_src/ (System, SDK) plus each
	tool pack under Packs/<packId>/. Then System is required and started.

	Hot reload:
	  * The server is long-polled for changes.
	  * A new build is only swapped in when no tool is active.
	  * Every module in the new build is required up front. If the framework
	    (System, SDK) fails to compile/load, or System.start errors, the new
	    build is discarded and the previous system keeps running. Each tool
	    pack is then checked separately; a failing pack is dropped from the
	    build (its tools are omitted) without blocking the reload.
	  * The last good build is cached in plugin settings so tools still work
	    when the server isn't running.

	Libraries (libraries.json, e.g. geometry3luau) are installed with the
	plugin as children of this script's Libraries folder, so they aren't
	re-sent with every reload. The folder is moved into each build as
	StudioTools/Libraries; the same ModuleScripts are reused, so require()
	keeps them loaded across reloads.

	Studio output that mentions "StudioTools" (this loader's messages, plus
	errors and stack traces from any module in the StudioTools tree) is
	forwarded to the server, which writes it to logs/studio-tools.log.

	Install with `npm run install-plugin`, which packs this script and the
	libraries into StudioToolsLoader.rbxmx in the local Plugins folder.
]]

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

if RunService:IsRunning() then
	-- Don't load the tool system inside play-test sessions.
	return
end

local SETTINGS_PREFIX = "StudioToolsSystem."
local DEFAULT_SERVER_URL = "http://localhost:34873"
local RETRY_DELAY = 3
local APPLY_CHECK_INTERVAL = 0.25

local serverUrl = plugin:GetSetting(SETTINGS_PREFIX .. "ServerUrl") or DEFAULT_SERVER_URL

local function log(...)
	print("[StudioTools]", ...)
end

local function warnf(fmt, ...)
	warn("[StudioTools] " .. string.format(fmt, ...))
end

----------------------------------------------------------------------------
-- Output forwarding (queued here, sent by the flush loop further down)
----------------------------------------------------------------------------

local LogService = game:GetService("LogService")

local FORWARD_MARKER = "StudioTools"
local MAX_QUEUED_OUTPUT = 500
local OUTPUT_FLUSH_INTERVAL = 0.5

local MESSAGE_KINDS = {
	[Enum.MessageType.MessageOutput] = "output",
	[Enum.MessageType.MessageInfo] = "info",
	[Enum.MessageType.MessageWarning] = "warning",
	[Enum.MessageType.MessageError] = "error",
}

local outputQueue = {}
local outputConnection = LogService.MessageOut:Connect(function(message, messageType)
	if #outputQueue < MAX_QUEUED_OUTPUT and string.find(message, FORWARD_MARKER, 1, true) then
		table.insert(outputQueue, { kind = MESSAGE_KINDS[messageType] or "output", message = message })
	end
end)

----------------------------------------------------------------------------
-- Toolbar + dock widget (created once, survive hot reloads)
----------------------------------------------------------------------------

local toolbar = plugin:CreateToolbar("Studio Tools")

local paletteButton = toolbar:CreateButton(
	"StudioToolsPalette",
	"Show or hide the Studio Tools palette",
	"", -- TODO: icon asset id
	"GS-STS"
)
paletteButton.ClickableWhenViewportHidden = true

-- Popup menu opened from the gear button in the status bar.
local settingsMenu = plugin:CreatePluginMenu("StudioToolsSettingsMenu", "Studio Tools")
local reloadAction = settingsMenu:AddNewAction("StudioToolsReloadAction", "Reload Tools")

local widget = plugin:CreateDockWidgetPluginGuiAsync(
	"StudioToolsSystemPalette",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Left, false, false, 280, 480, 220, 240)
)
widget.Name = "StudioToolsSystem"
widget.Title = "Studio Tools"
widget.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

paletteButton:SetActive(widget.Enabled)
paletteButton.Click:Connect(function()
	widget.Enabled = not widget.Enabled
end)
widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	paletteButton:SetActive(widget.Enabled)
end)

local STATUS_HEIGHT = 22

-- DockWidgetPluginGui has no background color of its own, so fill it with a frame.
local background = Instance.new("Frame")
background.Name = "Background"
background.BorderSizePixel = 0
background.Size = UDim2.fromScale(1, 1)
background.Parent = widget

-- The hot-loaded system puts its UI in here.
local container = Instance.new("Frame")
container.Name = "Content"
container.BorderSizePixel = 0
container.BackgroundTransparency = 1
container.Size = UDim2.new(1, 0, 1, -STATUS_HEIGHT)
container.Parent = background

local statusBar = Instance.new("Frame")
statusBar.Name = "StatusBar"
statusBar.BorderSizePixel = 0
statusBar.AnchorPoint = Vector2.new(0, 1)
statusBar.Position = UDim2.new(0, 0, 1, 0)
statusBar.Size = UDim2.new(1, 0, 0, STATUS_HEIGHT)
statusBar.Parent = background

local statusLabel = Instance.new("TextLabel")
statusLabel.Name = "Status"
statusLabel.BackgroundTransparency = 1
statusLabel.Position = UDim2.new(0, 8, 0, 0)
statusLabel.Size = UDim2.new(1, -(8 + STATUS_HEIGHT + 4), 1, 0)
statusLabel.Font = Enum.Font.SourceSans
statusLabel.TextSize = 14
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.TextTruncate = Enum.TextTruncate.AtEnd
statusLabel.Text = ""
statusLabel.Parent = statusBar

-- Gear button at the right end of the status bar; opens settingsMenu.
local GEAR_ICON = "rbxasset://textures/ui/Settings/MenuBarIcons/GameSettingsTab.png"
local GEAR_SIZE = 16

local gearButton = Instance.new("ImageButton")
gearButton.Name = "Settings"
gearButton.BackgroundTransparency = 1
gearButton.AnchorPoint = Vector2.new(1, 0.5)
gearButton.Position = UDim2.new(1, -(STATUS_HEIGHT - GEAR_SIZE) / 2 - 2, 0.5, 0)
gearButton.Size = UDim2.fromOffset(GEAR_SIZE, GEAR_SIZE)
gearButton.Image = GEAR_ICON
gearButton.ImageTransparency = 0.3
gearButton.Parent = statusBar

-- Text fallback in case the gear image isn't available in this Studio build.
local gearFallback = Instance.new("TextLabel")
gearFallback.BackgroundTransparency = 1
gearFallback.Size = UDim2.fromScale(1, 1)
gearFallback.Font = Enum.Font.SourceSansBold
gearFallback.TextSize = 14
gearFallback.Text = "..."
gearFallback.Visible = false
gearFallback.Parent = gearButton

task.spawn(function()
	game:GetService("ContentProvider"):PreloadAsync({ GEAR_ICON }, function(_, status)
		if status ~= Enum.AssetFetchStatus.Success then
			gearButton.Image = ""
			gearFallback.Visible = true
		end
	end)
end)

gearButton.MouseEnter:Connect(function()
	gearButton.ImageTransparency = 0
end)
gearButton.MouseLeave:Connect(function()
	gearButton.ImageTransparency = 0.3
end)
gearButton.Activated:Connect(function()
	settingsMenu:ShowAsync()
end)

local function applyTheme()
	local theme = settings().Studio.Theme
	background.BackgroundColor3 = theme:GetColor(Enum.StudioStyleGuideColor.MainBackground)
	statusBar.BackgroundColor3 = theme:GetColor(Enum.StudioStyleGuideColor.Titlebar)
	statusLabel.TextColor3 = theme:GetColor(Enum.StudioStyleGuideColor.DimmedText)
	gearButton.ImageColor3 = theme:GetColor(Enum.StudioStyleGuideColor.MainText)
	gearFallback.TextColor3 = theme:GetColor(Enum.StudioStyleGuideColor.MainText)
end
applyTheme()
local themeConnection = settings().Studio.ThemeChanged:Connect(applyTheme)

----------------------------------------------------------------------------
-- Host: the API handed to the hot-loaded system
----------------------------------------------------------------------------

local host = {
	plugin = plugin,
	widget = widget,
	-- Parent for the system's UI.
	container = container,
	-- Scratch table that survives hot reloads (but not Studio restarts).
	persist = {},
	serverUrl = serverUrl,
	-- Set to the build's { version, hash, packs, failedPacks } before System.start is called.
	build = nil,
	log = log,
}

----------------------------------------------------------------------------
-- Building / validating / starting a bundle
----------------------------------------------------------------------------

type Bundle = {
	version: number,
	hash: string,
	files: { { path: string, source: string } },
	-- Tool pack manifests; each pack's files are under Packs/<id>/.
	packs: { any }?,
}
-- failedPacks maps pack id -> error text for packs dropped from this build.
type Loaded = { root: Instance, system: any, bundle: Bundle, failedPacks: { [string]: string } }

local current: Loaded? = nil
local pendingBundle: Bundle? = nil
local forceReload = false
local lastFailedHash: string? = nil
local connected: boolean? = nil -- nil until the first request completes
local status = ""

local function updateStatusLabel()
	local parts = {}
	if connected == true then
		table.insert(parts, "● Connected")
	elseif connected == false then
		table.insert(parts, "○ Server offline")
	else
		table.insert(parts, "Connecting…")
	end
	if current then
		table.insert(parts, "build " .. tostring(current.bundle.version))
	end
	if status ~= "" then
		table.insert(parts, status)
	end
	statusLabel.Text = table.concat(parts, "  ·  ")
end

local function setStatus(text: string)
	status = text
	updateStatusLabel()
end

local function splitPath(filePath: string): (string, string)
	local dir, name = string.match(filePath, "^(.*)/([^/]+)$")
	if dir then
		return dir, name
	end
	return "", filePath
end

-- Bundled libraries, mounted into whichever build is loaded (see the header).
local librariesFolder = script:FindFirstChild("Libraries")

local function mountLibraries(root: Instance?)
	if librariesFolder then
		librariesFolder.Parent = root or script
	end
end

-- Destroys a build's tree, first taking the libraries back out of it.
local function destroyRoot(root: Instance)
	if librariesFolder and librariesFolder.Parent == root then
		librariesFolder.Parent = script
	end
	root:Destroy()
end

local function stripExtension(fileName: string): string?
	return string.match(fileName, "^(.*)%.luau$") or string.match(fileName, "^(.*)%.lua$")
end

-- Turns the bundle's flat file list into a ModuleScript tree. The root is
-- deliberately left parented to nil so it never touches the place file.
local function buildTree(bundle: Bundle): Instance
	local root = Instance.new("Folder")
	-- Part of the tool pack contract: packs find the SDK with
	-- script:FindFirstAncestor("StudioTools").SDK, so don't rename this.
	root.Name = "StudioTools"

	local initSources = {}
	for _, file in bundle.files do
		local dir, fileName = splitPath(file.path)
		if stripExtension(fileName) == "init" and dir ~= "" then
			initSources[dir] = file.source
		end
	end

	local dirs: { [string]: Instance } = { [""] = root }
	local function getDir(dirPath: string): Instance
		local existing = dirs[dirPath]
		if existing then
			return existing
		end
		local parentPath, name = splitPath(dirPath)
		local parent = getDir(parentPath)
		local instance: Instance
		local initSource = initSources[dirPath]
		if initSource then
			local module = Instance.new("ModuleScript")
			module.Source = initSource
			instance = module
		else
			instance = Instance.new("Folder")
		end
		instance.Name = name
		instance.Parent = parent
		dirs[dirPath] = instance
		return instance
	end

	for _, file in bundle.files do
		local dir, fileName = splitPath(file.path)
		local moduleName = stripExtension(fileName)
		if moduleName == "init" then
			getDir(dir)
		elseif moduleName then
			local module = Instance.new("ModuleScript")
			module.Name = moduleName
			module.Source = file.source
			module.Parent = getDir(dir)
		end
	end

	return root
end

-- Requires every ModuleScript in `instance` (including itself), returning
-- one line per module that failed.
local function requireAll(instance: Instance): { string }
	local modules = instance:GetDescendants()
	table.insert(modules, 1, instance)
	local errors = {}
	for _, module in modules do
		if module:IsA("ModuleScript") then
			local ok, err = pcall(require, module)
			if not ok then
				table.insert(errors, string.format("  %s: %s", module:GetFullName(), tostring(err)))
			end
		end
	end
	return errors
end

-- Requires every module in the tree so that syntax/load errors are caught
-- before we commit to the new build. Modules should therefore be free of
-- side effects at require time.
--
-- Libraries aren't required here: they're fixed for the plugin's lifetime and
-- load lazily.
--
-- The framework (everything outside Packs) is checked first, since packs
-- depend on it; any failure there rejects the build. Then each pack is
-- checked on its own, and failing packs are removed from the tree.
-- Returns ok, frameworkError, failedPacks (pack id -> error text).
local function validateTree(root: Instance): (boolean, string?, { [string]: string })
	local packsFolder = root:FindFirstChild("Packs")

	local frameworkErrors = {}
	for _, child in root:GetChildren() do
		if child ~= packsFolder and child ~= librariesFolder then
			local errors = requireAll(child)
			table.move(errors, 1, #errors, #frameworkErrors + 1, frameworkErrors)
		end
	end
	if #frameworkErrors > 0 then
		return false, table.concat(frameworkErrors, "\n"), {}
	end

	local failedPacks = {}
	if packsFolder then
		for _, pack in packsFolder:GetChildren() do
			local errors = requireAll(pack)
			if #errors > 0 then
				failedPacks[pack.Name] = table.concat(errors, "\n")
				pack:Destroy()
			end
		end
	end
	return true, nil, failedPacks
end

local function startSystem(root: Instance, bundle: Bundle, failedPacks: { [string]: string }): (any, string?)
	local entry = root:FindFirstChild("System")
	if not entry or not entry:IsA("ModuleScript") then
		return nil, "studio_plugin_src/System/init.luau not found"
	end
	local ok, SystemModule = pcall(require, entry)
	if not ok then
		return nil, tostring(SystemModule)
	end
	if type(SystemModule) ~= "table" or type(SystemModule.start) ~= "function" then
		return nil, "System module must return a table with a start(host, root) function"
	end
	host.build = {
		version = bundle.version,
		hash = bundle.hash,
		packs = bundle.packs or {},
		failedPacks = failedPacks,
	}
	local started, system = xpcall(SystemModule.start, debug.traceback, host, root)
	if not started then
		return nil, tostring(system)
	end
	if type(system) ~= "table" or type(system.stop) ~= "function" then
		return nil, "System.start must return an object with a stop() method"
	end
	return system, nil
end

local function stopSystem(loaded: Loaded)
	local ok, err = xpcall(loaded.system.stop, debug.traceback, loaded.system)
	if not ok then
		warnf("Error while stopping build %d:\n%s", loaded.bundle.version, tostring(err))
	end
	container:ClearAllChildren() -- in case stop() left anything behind
end

local function canReload(): boolean
	if not current or type(current.system.canReload) ~= "function" then
		return true
	end
	local ok, result = pcall(current.system.canReload, current.system)
	return not ok or result ~= false
end

local function applyBundle(bundle: Bundle): boolean
	local built, rootOrErr = pcall(buildTree, bundle)
	if not built then
		warnf("Failed to build module tree for build %d: %s", bundle.version, tostring(rootOrErr))
		lastFailedHash = bundle.hash
		setStatus("Reload failed (see Output)")
		return false
	end
	local root = rootOrErr :: Instance
	mountLibraries(root)

	local valid, validateErr, failedPacks = validateTree(root)
	if not valid then
		mountLibraries(if current then current.root else nil) -- back to the running build
		destroyRoot(root)
		lastFailedHash = bundle.hash
		warnf("Build %d failed to load; keeping the previous system.\n%s", bundle.version, validateErr or "")
		setStatus("Reload failed (see Output)")
		return false
	end
	local failedCount = 0
	for packId, err in failedPacks do
		failedCount += 1
		warnf("Tool pack '%s' failed to load; its tools are omitted from build %d.\n%s", packId, bundle.version, err)
	end

	local previous = current
	if previous then
		stopSystem(previous)
		current = nil
	end

	local system, startErr = startSystem(root, bundle, failedPacks)
	if not system then
		destroyRoot(root)
		lastFailedHash = bundle.hash
		warnf("Build %d failed to start; keeping the previous system.\n%s", bundle.version, startErr or "")
		container:ClearAllChildren()
		if previous then
			-- The old modules are still cached by require(), so this is cheap.
			mountLibraries(previous.root)
			local restored, restoreErr = startSystem(previous.root, previous.bundle, previous.failedPacks)
			if restored then
				previous.system = restored
				current = previous
			else
				warnf("Previous build %d also failed to restart:\n%s", previous.bundle.version, restoreErr or "")
				destroyRoot(previous.root)
			end
		end
		setStatus("Reload failed (see Output)")
		return false
	end

	if previous then
		destroyRoot(previous.root)
	end
	current = { root = root, system = system, bundle = bundle, failedPacks = failedPacks }
	lastFailedHash = nil
	log(string.format("Loaded build %d (%s)", bundle.version, bundle.hash))
	if failedCount > 0 then
		setStatus(string.format("%d pack%s failed (see Output)", failedCount, if failedCount == 1 then "" else "s"))
	else
		setStatus("")
	end
	pcall(plugin.SetSetting, plugin, SETTINGS_PREFIX .. "LastGoodBundle", bundle)
	return true
end

----------------------------------------------------------------------------
-- Server communication
----------------------------------------------------------------------------

local function httpGetJson(path: string): (any, string?)
	local ok, body = pcall(HttpService.GetAsync, HttpService, serverUrl .. path, true)
	if not ok then
		return nil, tostring(body)
	end
	local decoded, data = pcall(HttpService.JSONDecode, HttpService, body)
	if not decoded then
		return nil, "invalid JSON from server: " .. tostring(data)
	end
	return data, nil
end

local function setConnected(value: boolean, err: string?)
	if value == connected then
		return
	end
	connected = value
	if value then
		log("Connected to tool server at " .. serverUrl)
	else
		warnf("Tool server at %s is unreachable (%s). Run `npm start` in the repo.", serverUrl, err or "?")
	end
	updateStatusLabel()
end

local function fetchBundle(): Bundle?
	local data, err = httpGetJson("/bundle")
	if not data then
		setConnected(false, err)
		return nil
	end
	setConnected(true)
	return data
end

local running = true
local knownHash = ""

-- Start immediately from the cached build so tools work even if the server is down.
do
	local ok, cached = pcall(plugin.GetSetting, plugin, SETTINGS_PREFIX .. "LastGoodBundle")
	if ok and type(cached) == "table" and type(cached.files) == "table" then
		applyBundle(cached)
	end
	updateStatusLabel()
end

-- Long-poll loop: wakes up when the server reports a new hash.
task.spawn(function()
	while running do
		local data, err = httpGetJson("/poll?since=" .. HttpService:UrlEncode(knownHash))
		if not running then
			break
		end
		if not data then
			setConnected(false, err)
			task.wait(RETRY_DELAY)
		else
			setConnected(true)
			if data.hash ~= knownHash then
				local bundle = fetchBundle()
				if bundle then
					knownHash = bundle.hash
					pendingBundle = bundle
				end
			end
		end
	end
end)

-- Apply loop: swaps in pending builds once no tool is active.
task.spawn(function()
	local waitingLogged = false
	while running do
		local bundle = pendingBundle
		if bundle then
			local isCurrent = current ~= nil and current.bundle.hash == bundle.hash
			if not forceReload and (isCurrent or bundle.hash == lastFailedHash) then
				pendingBundle = nil
			elseif not canReload() then
				if not waitingLogged then
					waitingLogged = true
					setStatus("Update waiting for active tool to finish")
				end
			else
				pendingBundle = nil
				forceReload = false
				waitingLogged = false
				applyBundle(bundle)
			end
		end
		task.wait(APPLY_CHECK_INTERVAL)
	end
end)

-- Output flush loop: sends queued output to the server. While the server is
-- offline, output stays queued (up to MAX_QUEUED_OUTPUT) and is sent on reconnect.
task.spawn(function()
	while running do
		task.wait(OUTPUT_FLUSH_INTERVAL)
		if #outputQueue > 0 and connected == true then
			local entries = outputQueue
			outputQueue = {}
			local body = HttpService:JSONEncode({
				build = if current then current.bundle.version else nil,
				entries = entries,
			})
			-- Failures are dropped silently: anything printed here would be forwarded again.
			pcall(
				HttpService.PostAsync,
				HttpService,
				serverUrl .. "/log",
				body,
				Enum.HttpContentType.ApplicationJson,
				false,
				-- Required by the server for POSTs (keeps web pages from posting to it).
				{ ["X-Studio-Tools"] = "1" }
			)
		end
	end
end)

-- Settings menu > Reload Tools: re-fetch and reload even if nothing changed.
reloadAction.Triggered:Connect(function()
	task.spawn(function()
		local bundle = fetchBundle()
		if bundle then
			knownHash = bundle.hash
			forceReload = true
			pendingBundle = bundle
		end
	end)
end)

plugin.Unloading:Connect(function()
	running = false
	themeConnection:Disconnect()
	outputConnection:Disconnect()
	if current then
		stopSystem(current)
		current.root:Destroy()
		current = nil
	end
end)
