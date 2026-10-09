--[[
	Studio Tools SDK: the public, versioned API that tool packs build on.

	Pack modules get it with:

		local SDK = require(script:FindFirstAncestor("StudioTools").SDK)

	Everything reachable from this module (plus the ToolContext passed to
	tools) is covered by API_VERSION. Anything under System/ is internal and
	may change without notice. See docs/TOOLPACKS.md for the full contract.
]]

local Maid = require(script.Maid)
local Signal = require(script.Signal)
local Tool = require(script.Tool)
local Types = require(script.Types)
local InputBehavior = require(script.Input.InputBehavior)
local SingleClickInputBehavior = require(script.Input.SingleClickInputBehavior)
local ClickDragInputBehavior = require(script.Input.ClickDragInputBehavior)
local ClickOrDragInputBehavior = require(script.Input.ClickOrDragInputBehavior)
local HoverInputBehavior = require(script.Input.HoverInputBehavior)

export type SettingSchema = Types.SettingSchema
export type ToolContext = Types.ToolContext
export type ToolDefinition = Types.ToolDefinition
export type UndoRecording = Types.UndoRecording
export type UndoAction = Types.UndoAction
export type PackManifest = Types.PackManifest
export type Maid = Types.Maid
export type Signal = Types.Signal
export type Connection = Types.Connection
export type ToolClass = Types.ToolClass
export type ShutdownType = Types.ShutdownType
export type ShutdownReason = Types.ShutdownReason
export type ShutdownButton = Types.ShutdownButton
export type ShutdownTrigger = Types.ShutdownTrigger
export type ConfirmOptions = Types.ConfirmOptions
export type ShutdownOptions = Types.ShutdownOptions
export type InputPoint = Types.InputPoint
export type ButtonState = Types.ButtonState
export type InputState = Types.InputState
export type Modifiers = Types.Modifiers
export type MouseButton = Types.MouseButton
export type CaptureState = Types.CaptureState
export type CaptureRequest = Types.CaptureRequest
export type HitTest = Types.HitTest
export type InputBehavior = Types.InputBehavior
export type SingleClickInputBehavior = Types.SingleClickInputBehavior
export type ClickDragInputBehavior = Types.ClickDragInputBehavior
export type ClickOrDragInputBehavior = Types.ClickOrDragInputBehavior
export type HoverInputBehavior = Types.HoverInputBehavior

-- Bumped on breaking changes to the tool/pack contract. (server/sdk.js reads
-- this line when generating pack SDK files, so keep the format.)
local API_VERSION = 1
-- Oldest API version the system can still load.
local MIN_API_VERSION = 1

local SDK = {
	API_VERSION = API_VERSION,
	MIN_API_VERSION = MIN_API_VERSION,
	Tool = Tool,
	-- Values for a tool's `shutdown.type`.
	ShutdownType = table.freeze({
		Done = "Done",
		AcceptCancel = "AcceptCancel",
	}),
	-- Values passed to Tool:deactivate(ctx, reason).
	ShutdownReason = table.freeze({
		Done = "Done",
		Accept = "Accept",
		Cancel = "Cancel",
		Force = "Force",
	}),
	-- Values passed to Tool:confirmShutdown(reason, trigger).
	ShutdownTrigger = table.freeze({
		Button = "Button",
		Escape = "Escape",
	}),
	-- Values returned by InputBehavior capture and hover methods.
	CaptureState = table.freeze({
		Begin = "Begin",
		Continue = "Continue",
		End = "End",
		Ignore = "Ignore",
	}),
	-- Input behaviors (see Input/InputBehavior.luau): the base class for
	-- custom ones, and the standard ones most tools are built from.
	InputBehavior = InputBehavior,
	SingleClickInputBehavior = SingleClickInputBehavior,
	ClickDragInputBehavior = ClickDragInputBehavior,
	ClickOrDragInputBehavior = ClickOrDragInputBehavior,
	HoverInputBehavior = HoverInputBehavior,
	Maid = Maid,
	Signal = Signal,
}

function SDK.isApiVersionSupported(apiVersion: any): boolean
	return type(apiVersion) == "number" and apiVersion >= MIN_API_VERSION and apiVersion <= API_VERSION
end

return SDK
