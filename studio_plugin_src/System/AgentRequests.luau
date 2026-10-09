--[[
	AgentRequests: prompts that tools send to the Tools Agent (ctx:askAgent).

	submit() returns an SDK.AgentRequest handle right away (it never yields)
	and sends the prompt to the dev server in the background. The server
	(server/chat.js) runs it in the chat's agent session, after anything the
	agent is already doing, and shows it in the chat labeled with the tool.
	This module long-polls the request until it finishes, then hands the
	SDK.AgentResult to await()ing threads and onFinished callbacks.

	Requests outlive the tool that sent them (so a tool can send one on
	Accept) and hot reloads: the polling thread only needs HttpService, so it
	keeps going after the build that started it is gone. The server keeps
	requests in memory, so a server restart loses them and they fail.
]]

local HttpService = game:GetService("HttpService")

local SDK = require(script.Parent.Parent.SDK)
local ServerApi = require(script.Parent.ServerApi)

local RETRY_DELAY = 3
local MAX_CONNECTION_FAILURES = 10 -- about 30 seconds without reaching the server

local FINISHED = { done = true, failed = true, cancelled = true }

local AgentRequest = {}
AgentRequest.__index = AgentRequest

function AgentRequest:isFinished(): boolean
	return self.result ~= nil
end

-- Yields until the request finishes.
function AgentRequest:await(): SDK.AgentResult
	if self.result then
		return self.result
	end
	table.insert(self._threads, coroutine.running())
	return coroutine.yield()
end

-- fn(result) in its own thread when the request finishes (right away if it has).
function AgentRequest:onFinished(fn: (SDK.AgentResult) -> ())
	if self.result then
		task.spawn(fn, self.result)
	else
		table.insert(self._callbacks, fn)
	end
end

-- Finishes the request as cancelled now, and tells the server to drop it
-- (or stop the agent, if it's already working on it).
function AgentRequest:cancel()
	if self.result then
		return
	end
	self:_finish("cancelled", nil, nil)
	if self.id then
		task.spawn(ServerApi.request, self._serverUrl, "POST", "/chat/requests/cancel", { id = self.id })
	end
	-- Otherwise it's still being sent, and _run cancels it once the server answers.
end

function AgentRequest:_finish(status: string, reply: string?, err: string?)
	if self.result then
		return
	end
	self.status = status
	self.position = nil
	self.result = table.freeze({ ok = status == "done", status = status, reply = reply, error = err })
	local threads, callbacks = self._threads, self._callbacks
	self._threads, self._callbacks = {}, {}
	for _, thread in threads do
		task.spawn(thread, self.result)
	end
	for _, fn in callbacks do
		task.spawn(fn, self.result)
	end
end

function AgentRequest:_run(body: any)
	local serverUrl = self._serverUrl
	local ok, info, code = ServerApi.request(serverUrl, "POST", "/chat/requests", body)
	if not ok then
		local reason = if code then tostring(info) else "Couldn't reach the tool server: " .. tostring(info)
		self:_finish("failed", nil, reason)
		return
	elseif type(info) ~= "table" or type(info.id) ~= "string" then
		self:_finish("failed", nil, "Unexpected answer from the tool server.")
		return
	end
	self.id = info.id
	if self.result then
		-- Cancelled while it was being sent.
		ServerApi.request(serverUrl, "POST", "/chat/requests/cancel", { id = self.id })
		return
	end

	local failures = 0
	while not self.result do
		if FINISHED[info.status] then
			self:_finish(info.status, info.reply, info.error)
			return
		end
		self.status = info.status
		self.position = info.position

		local path = string.format(
			"/chat/requests/poll?id=%s&status=%s",
			HttpService:UrlEncode(self.id),
			HttpService:UrlEncode(tostring(info.status))
		)
		local polled, data, pollCode = ServerApi.request(serverUrl, "GET", path, nil)
		if self.result then
			return -- cancelled meanwhile
		end
		if polled and type(data) == "table" and type(data.status) == "string" then
			failures = 0
			info = data
		elseif polled then
			self:_finish("failed", nil, "Unexpected answer from the tool server.")
		elseif pollCode then
			-- The server answered with an error, e.g. it restarted and forgot the request.
			self:_finish("failed", nil, tostring(data))
		else
			failures += 1
			if failures >= MAX_CONNECTION_FAILURES then
				self:_finish("failed", nil, "Lost contact with the tool server: " .. tostring(data))
			else
				task.wait(RETRY_DELAY)
			end
		end
	end
end

local AgentRequests = {}

-- source: the tool sending it, { toolId = "<packId>/<toolId>", name = display name }.
function AgentRequests.submit(serverUrl: string, prompt: string, source: { toolId: string, name: string }): SDK.AgentRequest
	local request = setmetatable({
		id = nil :: string?,
		status = "sending",
		position = nil :: number?,
		result = nil :: SDK.AgentResult?,
		_serverUrl = serverUrl,
		_threads = {} :: { thread },
		_callbacks = {} :: { (SDK.AgentResult) -> () },
	}, AgentRequest)
	task.spawn(function()
		local ok, err = xpcall(request._run, debug.traceback, request, {
			prompt = prompt,
			toolId = source.toolId,
			toolName = source.name,
		})
		if not ok then
			request:_finish("failed", nil, "Internal error: " .. tostring(err))
		end
	end)
	return request :: any
end

return AgentRequests
