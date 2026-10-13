--[[
	Type definitions for the tool contract (API version 1). Types only; this
	module returns an empty table. Re-exported from the SDK module, and
	copied into each tool pack's generated SDK.luau by `npm run export-sdk`,
	so it must stay self-contained (no requires).
]]

-- How the palette shows a setting. Only affects presentation, never the
-- value. Options that don't apply to a setting's type are ignored.
export type SettingExtendedOptions = {
	-- number / integer: "field" (a text field, the default) or "slider" (a
	-- slider with the value beside it; needs min and max, else it falls back
	-- to a field).
	widget: ("field" | "slider")?,
	-- string: grey hint text shown while the field is empty.
	placeholder: string?,
}

-- One entry in a tool's `settings`. The palette builds the widgets from these;
-- tools never create settings UI themselves.
--   number / integer   a number (integer: whole numbers only), as a text field or slider
--   string             a line of text
--   boolean            On/Off
--   color              a swatch that opens a color picker
--   enum               a dropdown of `options`
--   button             an action, not a value: a full-width button labeled
--                      `label` that calls the tool's onAction(key)
--   label              display-only text (its `label`), not a value; change
--                      it with ctx:setSettingState(key, { label = ... })
export type SettingSchema = {
	key: string,
	label: string?,
	type: "number" | "integer" | "string" | "boolean" | "color" | "enum" | "button" | "label",
	default: any, -- not used by "button" or "label"
	-- Shown when the mouse rests on the setting's row (any type).
	tooltip: string?,
	-- Presentation options (see SettingExtendedOptions).
	extended: SettingExtendedOptions?,
	-- number / integer / string: shown in a field the user can't edit (no
	-- slider); only the tool sets it, with ctx:setSetting. Not remembered
	-- between sessions: it starts at `default`.
	readOnly: boolean?,
	-- number / integer (an integer's step is a whole number, default 1)
	min: number?,
	max: number?,
	step: number?,
	-- string
	maxLength: number?,
	-- enum
	options: { string }?,
	-- color: swatches offered in the picker
	presets: { Color3 }?,
}

-- Input --------------------------------------------------------------------

-- A position in the viewport and the world-space ray through it.
export type InputPoint = {
	position: Vector2, -- viewport pixels from the top-left (same space as GUI AbsolutePosition)
	ray: Ray, -- from the camera through `position`; Direction is a unit vector
}

-- One mouse button or modifier key in an InputState.
export type ButtonState = {
	pressed: boolean, -- went down in this update (down is also true)
	down: boolean, -- is held down
	released: boolean, -- went up in this update (down is false)
}

-- A snapshot of the mouse and modifier keys, made by the system for each
-- input event and passed to InputBehaviors.
export type InputState = {
	point: InputPoint,
	previousPoint: InputPoint, -- point of the previous update (the same for key-only updates)
	left: ButtonState,
	middle: ButtonState, -- currently always up: middle-button input is disabled (Studio pans the camera with it)
	right: ButtonState, -- currently always up: right-button input is disabled (Studio rotates the camera with it)
	shift: ButtonState,
	ctrl: ButtonState,
	alt: ButtonState,
	cmd: ButtonState, -- Command on macOS, the Windows key on Windows
	time: number, -- os.clock() of the update
}

-- Which modifier keys are held, passed to the standard behaviors' callbacks.
export type Modifiers = {
	shift: boolean,
	ctrl: boolean,
	alt: boolean,
	cmd: boolean,
}

export type MouseButton = "Left" | "Middle" | "Right"

-- Returned by an InputBehavior's capture and hover methods:
--   Begin     start capturing / hovering (from beginCapture / beginHover)
--   Continue  keep capturing / hovering (from updateCapture / updateHover)
--   End       finished; the system calls endCapture / endHover next
--   Ignore    don't capture / hover after all (from beginCapture / beginHover)
export type CaptureState = "Begin" | "Continue" | "End" | "Ignore"

-- Returned by wantsCapture / wantsHover to ask for the mouse; nil means no.
-- depth is the hit's distance along the input ray: among requests of equal
-- priority, the nearest wins.
export type CaptureRequest = {
	depth: number,
}

-- Hit test used by the standard behaviors: the distance along point.ray to
-- whatever the behavior should act on, or nil if there's nothing there.
export type HitTest = (point: InputPoint) -> number?

-- An object that turns mouse input into tool actions. Tools add behaviors
-- with self:addInputBehavior(); the system routes input to them. See
-- SDK.InputBehavior for the base class and docs/TOOLPACKS.md for the rules.
export type InputBehavior = {
	id: string, -- names the behavior in warnings
	priority: number, -- lower wins over higher, regardless of depth (default 100)
	enableHover: boolean, -- whether wantsHover is called at all (default false)

	wantsCapture: (self: any, input: InputState) -> CaptureRequest?,
	beginCapture: (self: any, input: InputState) -> CaptureState,
	updateCapture: (self: any, input: InputState) -> CaptureState,
	endCapture: (self: any, input: InputState) -> (),
	-- The capture was taken away: the tool is shutting down, its behaviors
	-- changed, or Studio lost focus.
	forceEndCapture: (self: any, input: InputState) -> (),

	wantsHover: (self: any, input: InputState) -> CaptureRequest?,
	beginHover: (self: any, input: InputState) -> CaptureState,
	updateHover: (self: any, input: InputState) -> CaptureState,
	endHover: (self: any, input: InputState) -> (),
}

-- Options shared by the standard behaviors.
export type BehaviorOptions = {
	id: string?,
	priority: number?,
	button: MouseButton?, -- default "Left" (click and drag behaviors)
}

-- SDK.SingleClickInputBehavior: a press and release on a target. hitTest
-- runs on press (to capture) and again on release; onClick only fires if
-- the release still hits, so moving off the target cancels the click.
export type SingleClickInputBehavior = InputBehavior & {
	hitTest: HitTest?,
	onClick: ((point: InputPoint, modifiers: Modifiers) -> ())?,
	button: MouseButton,
}
export type SingleClickOptions = BehaviorOptions & {
	hitTest: HitTest?,
	onClick: ((point: InputPoint, modifiers: Modifiers) -> ())?,
}

-- SDK.ClickDragInputBehavior: a press on a target starts a drag
-- (onBeginDrag at the press point), every input update while the button is
-- held calls onUpdateDrag, and the release calls onEndDrag. If the drag is
-- taken away, onCancelDrag is called, or onEndDrag at the last point if
-- there's no onCancelDrag.
export type ClickDragInputBehavior = InputBehavior & {
	hitTest: HitTest?,
	onBeginDrag: ((point: InputPoint, modifiers: Modifiers) -> ())?,
	onUpdateDrag: ((point: InputPoint, modifiers: Modifiers) -> ())?,
	onEndDrag: ((point: InputPoint, modifiers: Modifiers) -> ())?,
	onCancelDrag: (() -> ())?,
	button: MouseButton,
}
export type ClickDragOptions = BehaviorOptions & {
	hitTest: HitTest?,
	onBeginDrag: ((point: InputPoint, modifiers: Modifiers) -> ())?,
	onUpdateDrag: ((point: InputPoint, modifiers: Modifiers) -> ())?,
	onEndDrag: ((point: InputPoint, modifiers: Modifiers) -> ())?,
	onCancelDrag: (() -> ())?,
}

-- SDK.ClickOrDragInputBehavior: a click if the mouse is released within
-- dragThreshold pixels of where it was pressed (and hitTest still hits),
-- otherwise a drag that begins at the press point once the mouse moves
-- further than that.
export type ClickOrDragInputBehavior = ClickDragInputBehavior & {
	onClick: ((point: InputPoint, modifiers: Modifiers) -> ())?,
	dragThreshold: number,
}
export type ClickOrDragOptions = ClickDragOptions & {
	onClick: ((point: InputPoint, modifiers: Modifiers) -> ())?,
	dragThreshold: number?, -- pixels, default 4
}

-- SDK.HoverInputBehavior: hover only. Hovers while hitTest hits and no
-- other behavior wins the hover; onBeginHover defaults to onUpdateHover.
export type HoverInputBehavior = InputBehavior & {
	hitTest: HitTest?,
	onBeginHover: ((point: InputPoint, modifiers: Modifiers) -> ())?,
	onUpdateHover: ((point: InputPoint, modifiers: Modifiers) -> ())?,
	onEndHover: (() -> ())?,
}
export type HoverOptions = {
	id: string?,
	priority: number?,
	hitTest: HitTest?,
	onBeginHover: ((point: InputPoint, modifiers: Modifiers) -> ())?,
	onUpdateHover: ((point: InputPoint, modifiers: Modifiers) -> ())?,
	onEndHover: (() -> ())?,
}

-- SDK.InputBehavior: base class for custom behaviors. extend() makes a
-- subclass; Class:new(fields) makes an instance with `fields` copied onto
-- it, then calls its init().
export type InputBehaviorClass = {
	extend: (self: any, definition: { [string]: any }?) -> any,
	new: (self: any, fields: { [string]: any }?) -> any,
	getModifiers: (input: InputState) -> Modifiers,
	getButton: (input: InputState, button: MouseButton) -> ButtonState,
	-- { depth = hitTest(point) } if that's a number, else nil.
	requestIfHit: (hitTest: HitTest?, point: InputPoint) -> CaptureRequest?,
}

-- Undo ---------------------------------------------------------------------

export type UndoAction = "Undo" | "Redo"

export type UndoRecording = {
	commit: () -> (),
	cancel: () -> (),
}

-- Tool UI --------------------------------------------------------------------

-- Passed to ctx:setSettingState to change how one setting's widget is shown
-- while the tool is active. Only the fields given change; the others keep
-- their current values. Every widget starts visible, enabled, and with its
-- schema's label and tooltip.
export type SettingState = {
	visible: boolean?, -- false hides the widget's row
	enabled: boolean?, -- false greys it out; it can't be edited (or clicked, for a button)
	label: string?, -- replaces the label (a button's text)
	tooltip: string?, -- replaces the tooltip ("" removes it)
}

-- Where ctx:createViewportPanel puts a panel. Panels at the same position
-- stack downward.
export type ViewportPanelPosition = "Top" | "TopLeft" | "TopRight"

export type ViewportPanelOptions = {
	position: ViewportPanelPosition?, -- default "Top" (top center of the viewport)
	name: string?, -- the Frame's Name
}

-- SDK.ViewportStyle: the look of the system's viewport UI (the Tools Agent
-- chat, the shutdown overlay), for tools styling the contents of their
-- viewport panels to match.
export type ViewportStyle = {
	panel: Color3, -- panel background
	field: Color3, -- inset areas, text fields
	button: Color3, -- ordinary buttons
	accent: Color3, -- primary buttons
	text: Color3,
	dimText: Color3,
	errorText: Color3,
	font: Enum.Font,
	boldFont: Enum.Font,
	textSize: number,
	cornerRadius: number, -- panels; use about half for buttons
	padding: number,
	rowHeight: number, -- buttons and single-line fields
}

-- Tools Agent requests (ctx:askAgent) --------------------------------------

-- "sending": not accepted by the server yet; "queued": waiting for the agent
-- to finish earlier work; "running": the agent is working on it. The other
-- three are final.
export type AgentRequestStatus = "sending" | "queued" | "running" | "done" | "failed" | "cancelled"

-- How an agent request ended.
export type AgentResult = {
	ok: boolean, -- true when status is "done"
	status: AgentRequestStatus, -- "done", "failed" or "cancelled"
	reply: string?, -- the agent's final text reply (when done)
	error: string?, -- why it failed
}

export type AgentRequest = {
	id: string?, -- the server's id, once accepted
	status: AgentRequestStatus,
	position: number?, -- place in the queue while "queued" (1 = next)
	result: AgentResult?, -- set when finished
	isFinished: (self: AgentRequest) -> boolean,
	-- Yields until the request finishes. Input behavior callbacks must not
	-- yield, so call this from task.spawn, or use onFinished.
	await: (self: AgentRequest) -> AgentResult,
	-- fn(result) in its own thread when the request finishes (right away if it has).
	onFinished: (self: AgentRequest, fn: (AgentResult) -> ()) -> (),
	-- Finishes the request as "cancelled" now. The server drops it from the
	-- queue, or stops the agent if it's working on it (changes it already
	-- made to the place stay).
	cancel: (self: AgentRequest) -> (),
}

export type AskAgentOptions = {
	-- Cancel the request if the tool deactivates before it finishes. Default
	-- false: requests outlive the tool, so one can be sent on Accept.
	cancelOnDeactivate: boolean?,
}

export type ToolContext = {
	plugin: Plugin,
	toolId: string, -- "<packId>/<toolId>"
	definition: any,
	settings: { [string]: any },
	state: { [any]: any },

	addCleanup: <T>(self: ToolContext, task: T) -> T,
	connect: (self: ToolContext, signal: RBXScriptSignal, fn: (...any) -> ()) -> RBXScriptConnection,

	-- Tells the system the tool's getInputBehaviors() result changed.
	-- (Tool:addInputBehavior/removeInputBehavior call this for you.)
	inputBehaviorsChanged: (self: ToolContext) -> (),
	-- Re-runs hover and capture handling at the current mouse position, for
	-- when the tool changed something its hit tests depend on. Undo/redo,
	-- setting changes and camera moves do this automatically.
	refreshInput: (self: ToolContext) -> (),

	isKeyDown: (self: ToolContext, ...Enum.KeyCode) -> boolean,
	isShiftDown: (self: ToolContext) -> boolean,
	onKey: (self: ToolContext, fn: (InputObject, boolean) -> ()) -> (),
	onSettingChanged: (self: ToolContext, fn: (string, any) -> ()) -> any,
	-- Changes one of the tool's settings as if the user had edited it (saved,
	-- shown in the palette, onSettingChanged handlers run).
	setSetting: (self: ToolContext, key: string, value: any) -> (),
	-- fn(action, waypointName) after the user undoes or redoes while the tool is active.
	onUndoRedo: (self: ToolContext, fn: (UndoAction, string) -> ()) -> (),

	excludeFromRaycast: (self: ToolContext, instance: Instance) -> (),
	-- Raycasts along an InputPoint's ray (from the camera through that point).
	raycastAt: (self: ToolContext, point: InputPoint, maxDistance: number?, extraExclude: { Instance }?) -> RaycastResult?,
	partAt: (self: ToolContext, point: InputPoint) -> (BasePart?, RaycastResult?),

	-- Shows a confirmation dialog in the viewport and waits for the answer
	-- (yields). Escape, or the tool being shut down, answers false.
	confirm: (self: ToolContext, options: ConfirmOptions) -> boolean,
	-- Shows a message (e.g. an error) in a dialog with one button and waits
	-- until it's dismissed (yields): the button, Escape, or the tool being
	-- shut down.
	alert: (self: ToolContext, options: AlertOptions) -> (),
	-- Shows a modal progress dialog (message and an animated bar) while the
	-- tool works on something the user must wait for, e.g. an upload on
	-- Accept. Blocks viewport input, the shutdown buttons and Escape until
	-- handle:close() (or deactivate). Doesn't yield.
	showProgress: (self: ToolContext, options: ProgressOptions) -> ProgressHandle,

	-- Local meshes: EditableMesh content isn't saved with the place. After
	-- creating or changing a MeshPart that shows an EditableMesh, call
	-- saveLocalMesh(part) inside the same undo recording: the part gets a
	-- mesh id and the mesh is stored on the dev server (in the background),
	-- and it's restored when the place is opened again. Returns the id.
	saveLocalMesh: (self: ToolContext, part: MeshPart) -> string,
	-- Stops treating the part as a local mesh (e.g. it now uses an uploaded
	-- mesh asset). Call inside the undo recording that changed it.
	clearLocalMesh: (self: ToolContext, part: MeshPart) -> (),
	-- Uploads a MeshPart's mesh as a new Mesh asset owned by the Studio user
	-- and loads it back as an unparented MeshPart, to give to parts with
	-- MeshPart:ApplyMesh (destroy it afterwards). Yields; errors with a
	-- message for the user. Needs the Studio beta "CreateAssetAsync Luau API".
	uploadMesh: (self: ToolContext, part: MeshPart, options: UploadMeshOptions) -> UploadedMesh,
	-- Re-queries canAccept() now instead of waiting for the next poll.
	refreshShutdownButtons: (self: ToolContext) -> (),

	createBoxPreview: (self: ToolContext) -> BoxHandleAdornment,
	createHighlight: (self: ToolContext, color: Color3?) -> SelectionBox,
	-- Any HandleAdornment class by name ("LineHandleAdornment",
	-- "SphereHandleAdornment", ...), adorning the Terrain so its CFrame is
	-- world space. Never saved or recorded; removed on deactivate.
	createAdornment: (self: ToolContext, className: string) -> HandleAdornment,
	-- A Model in the Workspace for temporary 3D content (e.g. a preview
	-- mesh). It and its contents are non-archivable (never saved, copied or
	-- recorded in undo history), its parts are locked and ignored by
	-- raycastAt, and it's destroyed on deactivate.
	createTemporaryModel: (self: ToolContext, name: string?) -> Model,
	-- Moves the camera to frame a box (center/orientation and size), keeping
	-- the view direction, and orbits around its center afterwards. Animated.
	focusView: (self: ToolContext, cframe: CFrame, size: Vector3) -> (),
	-- Pans the camera (no rotation or zoom) to put a world point at the
	-- center of the view, and orbits around it afterwards. Animated.
	centerView: (self: ToolContext, point: Vector3) -> (),
	-- Sets Studio's camera fly and mouse-wheel speeds to suit an object of
	-- this size. The user's own speeds come back when the tool deactivates.
	autoCameraSpeed: (self: ToolContext, size: Vector3) -> (),

	beginUndo: (self: ToolContext, name: string) -> UndoRecording,
	recordUndo: (self: ToolContext, name: string, fn: (...any) -> ...any, ...any) -> (boolean, any),
	-- Adds a Studio undo waypoint for a change the tool already made to its
	-- own state (not the place, e.g. a mesh it keeps in memory). undo() and
	-- redo() run when the user undoes/redoes it while the tool is active;
	-- they must not yield. Afterwards the waypoints remain but do nothing.
	addUndoStep: (self: ToolContext, name: string, undo: () -> (), redo: () -> ()) -> (),

	-- Sends a prompt to the Tools Agent, which can edit the place through the
	-- Roblox Studio MCP. Returns right away (never yields).
	askAgent: (self: ToolContext, prompt: string, options: AskAgentOptions?) -> AgentRequest,

	-- A line of text under the tool's name in the palette (nil hides it).
	setStatus: (self: ToolContext, text: string?) -> (),
	-- Shows/hides, enables/disables or relabels one setting's widget (any
	-- type, including buttons).
	setSettingState: (self: ToolContext, key: string, state: SettingState) -> (),
	-- A panel in the viewport for UI that doesn't fit the settings panel.
	-- Prefer settings, "button" settings and setStatus. Returns a Frame styled like the
	-- system's viewport UI, with a horizontal UIListLayout named "Layout";
	-- fill it with your own GUI objects and restyle it freely. Clicks inside
	-- it don't reach the tool's input behaviors. Removed on deactivate.
	createViewportPanel: (self: ToolContext, options: ViewportPanelOptions?) -> Frame,

	log: (self: ToolContext, ...any) -> (),
}

-- Which buttons the system's shutdown overlay shows while the tool is active.
export type ShutdownType = "Done" | "AcceptCancel"

-- Passed to Tool:deactivate(ctx, reason): why the tool is shutting down.
-- "Force" means the user didn't pick a button: another tool was chosen,
-- Studio switched tools, the plugin is unloading, or activation failed.
export type ShutdownReason = "Done" | "Accept" | "Cancel" | "Force"

-- What started a user-initiated shutdown (passed to confirmShutdown).
export type ShutdownTrigger = "Button" | "Escape"

-- Options for ctx:confirm().
export type ConfirmOptions = {
	title: string?,
	message: string,
	confirmText: string?, -- default "OK"
	cancelText: string?, -- default "Cancel"
}

export type AlertOptions = {
	title: string?,
	message: string,
	buttonText: string?, -- default "OK"
}

export type ProgressOptions = {
	title: string?,
	message: string,
}

export type ProgressHandle = {
	setMessage: (self: ProgressHandle, text: string) -> (),
	close: (self: ProgressHandle) -> (),
}

export type UploadMeshOptions = {
	name: string, -- the asset's name
	description: string?,
	onStatus: ((text: string) -> ())?, -- progress messages, e.g. for handle:setMessage
}

export type UploadedMesh = {
	assetId: number,
	uri: string, -- "rbxassetid://<assetId>"
	meshPart: MeshPart, -- unparented, made from the new asset
}

export type ShutdownButton = {
	text: string?,
	tooltip: string?,
}

export type ShutdownOptions = {
	type: ShutdownType?, -- default "Done"
	done: ShutdownButton?, -- used when type is "Done"
	accept: ShutdownButton?, -- used when type is "AcceptCancel"
	cancel: ShutdownButton?, -- used when type is "AcceptCancel"
}

export type ToolDefinition = {
	-- Studio Tools API version this tool was written against. Required.
	apiVersion: number,
	-- Unique within the pack; stable (saved settings are keyed on it). Required.
	id: string,
	-- Shown in the palette. Required.
	name: string,
	description: string?,
	-- The tool's own version, informational.
	version: string?,
	-- Palette sort order within the pack.
	order: number?,
	-- Palette tab to show the tool in (at most 24 characters). Default: the
	-- pack's `tab`.
	tab: string?,
	-- Section within the tab; tools with the same section are grouped, and
	-- sections are labeled when a tab has more than one. Default: the pack's name.
	section: string?,
	-- Base classes under Tools/ set this so they aren't listed. Not inherited.
	abstract: boolean?,
	settings: { SettingSchema }?,
	-- Shutdown overlay configuration; read by the default getShutdownOptions().
	shutdown: ShutdownOptions?,

	-- Called on the class (no ctx) to ask whether the tool can start now, e.g.
	-- whether a suitable selection exists. Return false and a short reason to
	-- grey out its palette button. Asked again when the selection changes;
	-- must be quick and must not yield. Default: always.
	canActivate: (self: any) -> (boolean, string?),
	activate: (self: any, ctx: ToolContext) -> (),
	deactivate: (self: any, ctx: ToolContext, reason: ShutdownReason) -> (),
	-- Called right after activate(). Override for options that depend on state.
	getShutdownOptions: (self: any) -> ShutdownOptions,
	-- Called before a user-initiated shutdown (button or Escape, not Force).
	-- May yield, e.g. for ctx:confirm(). Return false to keep the tool running.
	confirmShutdown: (self: any, reason: ShutdownReason, trigger: ShutdownTrigger) -> boolean,
	-- Polled while an Accept/Cancel tool is active. Return false (and
	-- optionally a reason, shown as the button's tooltip) to disable Accept.
	canAccept: (self: any) -> (boolean, string?),
	-- The behaviors that receive the tool's mouse input. The default returns
	-- those added with addInputBehavior().
	getInputBehaviors: (self: any) -> { InputBehavior },
	-- Called when the user clicks one of the tool's "button" settings, with
	-- its key. Runs in its own thread, so it may yield.
	onAction: (self: any, key: string) -> (),
}

export type Connection = {
	Disconnect: (self: Connection) -> (),
}

export type Signal = {
	connect: (self: Signal, fn: (...any) -> ()) -> Connection,
	fire: (self: Signal, ...any) -> (),
	destroy: (self: Signal) -> (),
}

export type Maid = {
	add: <T>(self: Maid, task: T) -> T,
	clean: (self: Maid) -> (),
	destroy: (self: Maid) -> (),
}

-- The SDK.Tool base class. extend() returns the new class (typed loosely, so
-- annotate methods yourself, e.g. `function MyTool:activate(ctx: SDK.ToolContext)`).
export type ToolClass = {
	extend: (self: any, definition: { [string]: any }?) -> any,
	isSubclass: (value: any) -> boolean,
	canActivate: (self: any) -> (boolean, string?),
	activate: (self: any, ctx: ToolContext) -> (),
	deactivate: (self: any, ctx: ToolContext, reason: ShutdownReason) -> (),
	getShutdownOptions: (self: any) -> ShutdownOptions,
	confirmShutdown: (self: any, reason: ShutdownReason, trigger: ShutdownTrigger) -> boolean,
	canAccept: (self: any) -> (boolean, string?),
	getInputBehaviors: (self: any) -> { InputBehavior },
	addInputBehavior: <T>(self: any, behavior: T) -> T,
	removeInputBehavior: (self: any, behavior: InputBehavior) -> (),
	onAction: (self: any, key: string) -> (),
}

-- The SDK module itself.
export type SDK = {
	API_VERSION: number,
	MIN_API_VERSION: number,
	isApiVersionSupported: (apiVersion: any) -> boolean,
	Tool: ToolClass,
	ShutdownType: { Done: ShutdownType, AcceptCancel: ShutdownType },
	ShutdownReason: { Done: ShutdownReason, Accept: ShutdownReason, Cancel: ShutdownReason, Force: ShutdownReason },
	ShutdownTrigger: { Button: ShutdownTrigger, Escape: ShutdownTrigger },
	CaptureState: { Begin: CaptureState, Continue: CaptureState, End: CaptureState, Ignore: CaptureState },
	InputBehavior: InputBehaviorClass,
	SingleClickInputBehavior: { new: (self: any, options: SingleClickOptions) -> SingleClickInputBehavior },
	ClickDragInputBehavior: { new: (self: any, options: ClickDragOptions) -> ClickDragInputBehavior },
	ClickOrDragInputBehavior: { new: (self: any, options: ClickOrDragOptions) -> ClickOrDragInputBehavior },
	HoverInputBehavior: { new: (self: any, options: HoverOptions) -> HoverInputBehavior },
	Maid: { new: () -> Maid },
	Signal: { new: () -> Signal },
	ViewportStyle: ViewportStyle,
}

-- Pack metadata from toolpack.json, as delivered by the server.
export type PackManifest = {
	id: string,
	name: string,
	version: string,
	apiVersion: number,
	description: string,
	tab: string, -- palette tab the pack's tools appear in (default "Core")
	origin: string,
}

return {}
