--[[
	Minimal signal. Handlers run in their own threads so one failing handler
	can't break the caller or other handlers.
]]

local Signal = {}
Signal.__index = Signal

export type Connection = { Disconnect: (Connection) -> () }
export type Signal = typeof(setmetatable({} :: { _handlers: { [any]: boolean } }, Signal))

function Signal.new(): Signal
	return setmetatable({ _handlers = {} }, Signal)
end

function Signal.connect(self: Signal, fn: (...any) -> ()): Connection
	local handler = { fn = fn }
	self._handlers[handler] = true
	local connection = {}
	function connection.Disconnect()
		self._handlers[handler] = nil
	end
	return connection :: any
end

function Signal.fire(self: Signal, ...: any)
	for handler in table.clone(self._handlers) do
		task.spawn(handler.fn, ...)
	end
end

function Signal.destroy(self: Signal)
	table.clear(self._handlers)
end

return Signal
