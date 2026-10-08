--[[
	ServerApi: JSON requests from System code to the dev server.

	Every request carries the X-Studio-Tools header the server requires for
	POSTs (see server/server.js). Never throws: returns ok, data (decoded
	JSON body) or ok = false and an error message.
]]

local HttpService = game:GetService("HttpService")

local ServerApi = {}

local HEADERS = { ["X-Studio-Tools"] = "1" }

-- method: "GET" | "POST"; body is JSON-encoded for POST.
function ServerApi.request(serverUrl: string, method: string, path: string, body: any?): (boolean, any)
	local request = {
		Url = serverUrl .. path,
		Method = method,
		Headers = table.clone(HEADERS),
	}
	if body ~= nil then
		request.Headers["Content-Type"] = "application/json"
		request.Body = HttpService:JSONEncode(body)
	end

	local ok, response = pcall(HttpService.RequestAsync, HttpService, request)
	if not ok then
		return false, tostring(response)
	end
	local decoded, data = pcall(HttpService.JSONDecode, HttpService, response.Body)
	if not decoded then
		data = nil
	end
	if not response.Success then
		local message = if type(data) == "table" and data.error then data.error else ("HTTP " .. response.StatusCode)
		return false, message
	end
	return true, data
end

return ServerApi
