--[[
	Maid: collects cleanup tasks (connections, instances, functions, objects
	with Destroy/destroy/Disconnect) and runs them all in reverse order on clean().
]]

local Maid = {}
Maid.__index = Maid

export type Maid = typeof(setmetatable({} :: { _tasks: { any } }, Maid))

function Maid.new(): Maid
	return setmetatable({ _tasks = {} }, Maid)
end

function Maid.add<T>(self: Maid, task: T): T
	table.insert(self._tasks, task)
	return task
end

local function runTask(task: any)
	local kind = typeof(task)
	if kind == "function" then
		task()
	elseif kind == "RBXScriptConnection" then
		task:Disconnect()
	elseif kind == "Instance" then
		task:Destroy()
	elseif kind == "table" then
		if type(task.Destroy) == "function" then
			task:Destroy()
		elseif type(task.destroy) == "function" then
			task:destroy()
		elseif type(task.Disconnect) == "function" then
			task:Disconnect()
		end
	end
end

function Maid.clean(self: Maid)
	local tasks = self._tasks
	self._tasks = {}
	for i = #tasks, 1, -1 do
		local ok, err = pcall(runTask, tasks[i])
		if not ok then
			warn("[StudioTools] cleanup task failed: " .. tostring(err))
		end
	end
end

Maid.destroy = Maid.clean

return Maid
