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
	Maid = Maid,
	Signal = Signal,
}

function SDK.isApiVersionSupported(apiVersion: any): boolean
	return type(apiVersion) == "number" and apiVersion >= MIN_API_VERSION and apiVersion <= API_VERSION
end

return SDK
