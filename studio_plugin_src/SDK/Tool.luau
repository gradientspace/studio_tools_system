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

	Tools take mouse input through input behaviors (SDK.InputBehavior and
	the standard ones built on it), added with self:addInputBehavior(),
	usually in activate(). The system routes input to them, decides which
	one captures the mouse, and ends captures when the tool shuts down.
	A tool that manages its own list can override getInputBehaviors() and
	call self.ctx:inputBehaviorsChanged() whenever its result changes.

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

-- The behaviors that receive the tool's mouse input. The system calls this
-- after activate() and after ctx:inputBehaviorsChanged().
function Tool:getInputBehaviors(): { any }
	return rawget(self, "_inputBehaviors") or {}
end

-- Adds an input behavior (it receives input from the next update on).
-- Returns the behavior.
function Tool:addInputBehavior<T>(behavior: T): T
	local behaviors = rawget(self, "_inputBehaviors")
	if not behaviors then
		behaviors = {}
		self._inputBehaviors = behaviors
	end
	if not table.find(behaviors, behavior) then
		table.insert(behaviors, behavior)
		self.ctx:inputBehaviorsChanged()
	end
	return behavior
end

-- Removes an input behavior, ending its capture or hover if it has one.
function Tool:removeInputBehavior(behavior: any)
	local behaviors = rawget(self, "_inputBehaviors")
	local index = behaviors and table.find(behaviors, behavior)
	if index then
		table.remove(behaviors, index)
		self.ctx:inputBehaviorsChanged()
	end
end

-- Called when the user clicks one of the tool's "button" settings, with the
-- setting's key. Runs in its own thread, so it may yield. Default: nothing.
function Tool:onAction(_key: string) end

-- Polled while an Accept/Cancel tool is active. Return false to disable the
-- Accept button, optionally with a short explanation shown as its tooltip.
-- Default: always allowed.
function Tool:canAccept(): (boolean, string?)
	return true, nil
end

return Tool
