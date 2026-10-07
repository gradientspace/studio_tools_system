--[[
	Tool system entry point, required and started by the StudioToolsLoader
	plugin every time a new build is loaded.

	start(host, root) receives:
	  host  - long-lived objects owned by the loader: plugin, widget, container
	          (parent for UI), persist (table that survives hot reloads), log,
	          and build = { version, hash, packs = { PackManifest } }
	  root  - the ModuleScript tree: root.System, root.SDK, root.Packs.<packId>

	It must return an object with:
	  stop()       - tear down everything start() created
	  canReload()  - false while a hot reload would be disruptive (a tool is active)
]]

local SDK = require(script.Parent.SDK)
local Palette = require(script.Palette)
local ToolManager = require(script.ToolManager)

local System = {}

function System.start(host: any, root: Instance)
	local maid = SDK.Maid.new()

	local ok, result = pcall(function()
		local manager = maid:add(ToolManager.new(host, root:FindFirstChild("Packs")))
		maid:add(Palette.new(host, manager))

		local system = {}
		function system.canReload(_self)
			return manager:getActiveTool() == nil
		end
		function system.stop(_self)
			maid:clean()
		end
		return system
	end)

	if not ok then
		-- Leave nothing behind; the loader will fall back to the previous build.
		maid:clean()
		error(result, 0)
	end
	return result
end

return System
