--[[
	Tool: base class for every tool.

	Define a tool by extending Tool, or any subclass of it:

		local MyTool = SDK.Tool:extend({
			apiVersion = 1,
			id = "MyTool",
			name = "My Tool",
		})

		function MyTool:activate(ctx)
			...
		end

		return MyTool

	Each activation gets a fresh instance, setmetatable({ ctx = ctx }, MyTool),
	so per-activation state can live on `self`. Class fields (id, settings,
	helper methods, ...) are readable through the instance.

	Subclasses override methods and call the base version explicitly:

		local Derived = Base:extend({ ... })

		function Derived:activate(ctx)
			Base.activate(self, ctx)
			...
		end

	While a tool is active, the system shows a shutdown overlay at the bottom
	of the viewport: a "Done" button by default, or Accept/Cancel. Configure
	it with a `shutdown` field (see SDK.ShutdownOptions), or override
	getShutdownOptions(). The button the user picks, or "Force" if the tool
	was shut down some other way, is passed to deactivate(ctx, reason).

	Before a user-initiated shutdown (button or Escape) the system calls
	confirmShutdown(reason, trigger), which can ask the user (ctx:confirm)
	and return false to keep the tool running. For Accept/Cancel tools,
	canAccept() is polled to enable or disable the Accept button.

	apiVersion is deliberately not defined here: every tool, or a base class
	in its own pack, must state which API version it was written against.
]]

local Tool = {}
Tool.__index = Tool

-- Creates a subclass of `base`. The given table becomes the class.
function Tool.extend(base: any, definition: { [string]: any }?): any
	local class = definition or {}
	class.__index = class
	return setmetatable(class, base)
end

-- True for classes (and instances) derived from Tool, but not Tool itself.
function Tool.isSubclass(value: any): boolean
	if type(value) ~= "table" or value == Tool then
		return false
	end
	local current = getmetatable(value)
	while type(current) == "table" do
		if current == Tool then
			return true
		end
		current = getmetatable(current)
	end
	return false
end

-- Called when the tool becomes active. Must be overridden.
function Tool:activate(_ctx: any)
	error(string.format("tool '%s' does not implement activate()", tostring(self.id)), 2)
end

-- Called when the tool is deactivated, before the context cleans up after it.
-- `reason` is "Done", "Accept", "Cancel" or "Force" (see SDK.ShutdownReason).
-- Optional: anything created or connected through ctx is cleaned up anyway.
function Tool:deactivate(_ctx: any, _reason: string) end

-- Called by the system right after activate() to configure the shutdown
-- overlay. The default returns the class's `shutdown` field, or Done.
function Tool:getShutdownOptions(): any
	return self.shutdown or { type = "Done" }
end

-- Called before a user-initiated shutdown: an overlay button or Escape (not
-- Force, which can't be refused). May yield, e.g. to ask with ctx:confirm().
-- Return false to keep the tool running. Default: always allow.
function Tool:confirmShutdown(_reason: string, _trigger: string): boolean
	return true
end

-- Polled while an Accept/Cancel tool is active. Return false to disable the
-- Accept button, optionally with a short explanation shown as its tooltip.
-- Default: always allowed.
function Tool:canAccept(): (boolean, string?)
	return true, nil
end

return Tool
