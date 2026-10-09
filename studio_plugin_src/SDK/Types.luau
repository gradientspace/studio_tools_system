--[[
	Type definitions for the tool contract (API version 1). Types only; this
	module returns an empty table. Re-exported from the SDK module, and
	copied into each tool pack's generated SDK.luau by `npm run export-sdk`,
	so it must stay self-contained (no requires).
]]

export type SettingSchema = {
	key: string,
	label: string?,
	type: "number" | "boolean" | "color" | "enum",
	default: any,
	-- number
	min: number?,
	max: number?,
	step: number?,
	-- enum
	options: { string }?,
	-- color
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
	middle: ButtonState, -- note that Studio also pans the camera with the middle button
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

export type MouseButton = "Left" | "Middle"

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
	-- fn(action, waypointName) after the user undoes or redoes while the tool is active.
	onUndoRedo: (self: ToolContext, fn: (UndoAction, string) -> ()) -> (),

	excludeFromRaycast: (self: ToolContext, instance: Instance) -> (),
	-- Raycasts along an InputPoint's ray (from the camera through that point).
	raycastAt: (self: ToolContext, point: InputPoint, maxDistance: number?, extraExclude: { Instance }?) -> RaycastResult?,
	partAt: (self: ToolContext, point: InputPoint) -> (BasePart?, RaycastResult?),

	-- Shows a confirmation dialog in the viewport and waits for the answer
	-- (yields). Escape, or the tool being shut down, answers false.
	confirm: (self: ToolContext, options: ConfirmOptions) -> boolean,
	-- Re-queries canAccept() now instead of waiting for the next poll.
	refreshShutdownButtons: (self: ToolContext) -> (),

	createBoxPreview: (self: ToolContext) -> BoxHandleAdornment,
	createHighlight: (self: ToolContext, color: Color3?) -> SelectionBox,

	beginUndo: (self: ToolContext, name: string) -> UndoRecording,
	recordUndo: (self: ToolContext, name: string, fn: (...any) -> ...any, ...any) -> (boolean, any),

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
	-- Base classes under Tools/ set this so they aren't listed. Not inherited.
	abstract: boolean?,
	settings: { SettingSchema }?,
	-- Shutdown overlay configuration; read by the default getShutdownOptions().
	shutdown: ShutdownOptions?,

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
	activate: (self: any, ctx: ToolContext) -> (),
	deactivate: (self: any, ctx: ToolContext, reason: ShutdownReason) -> (),
	getShutdownOptions: (self: any) -> ShutdownOptions,
	confirmShutdown: (self: any, reason: ShutdownReason, trigger: ShutdownTrigger) -> boolean,
	canAccept: (self: any) -> (boolean, string?),
	getInputBehaviors: (self: any) -> { InputBehavior },
	addInputBehavior: <T>(self: any, behavior: T) -> T,
	removeInputBehavior: (self: any, behavior: InputBehavior) -> (),
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
