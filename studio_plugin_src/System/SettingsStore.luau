--[[
	Per-tool setting values, validated against each tool's `settings` schema
	and persisted with plugin:SetSetting so they survive Studio restarts.

	Supported setting types:
	  number   { min?, max?, step? }
	  integer  { min?, max?, step? }  like number, but always a whole number
	  string   { maxLength? }
	  boolean
	  color    (Color3; stored as hex) { presets? = { Color3 } }
	  enum     { options = { string } }
	  button   an action (Tool:onAction), not a value: never stored
	  label    display-only text, not a value: never stored

	(A schema's `extended` options only affect how the palette shows it.)
]]

local SETTINGS_KEY_PREFIX = "StudioToolsSystem.ToolSettings."

local SettingsStore = {}
SettingsStore.__index = SettingsStore

local function coerce(schema: any, value: any): any
	local kind = schema.type
	if kind == "number" or kind == "integer" then
		if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
			return nil
		end
		local step = schema.step
		if kind == "integer" then
			step = math.max(1, math.round(step or 1))
		end
		if step and step > 0 then
			value = math.round(value / step) * step
		end
		if schema.min then
			value = math.max(value, if kind == "integer" then math.ceil(schema.min) else schema.min)
		end
		if schema.max then
			value = math.min(value, if kind == "integer" then math.floor(schema.max) else schema.max)
		end
		return value
	elseif kind == "string" then
		if type(value) ~= "string" then
			return nil
		end
		if type(schema.maxLength) == "number" and #value > schema.maxLength then
			value = string.sub(value, 1, schema.maxLength)
		end
		return value
	elseif kind == "boolean" then
		return if type(value) == "boolean" then value else nil
	elseif kind == "color" then
		if typeof(value) == "Color3" then
			return value
		elseif type(value) == "string" then
			local ok, color = pcall(Color3.fromHex, value)
			return if ok then color else nil
		end
		return nil
	elseif kind == "enum" then
		return if table.find(schema.options or {}, value) then value else nil
	elseif kind == "button" or kind == "label" then
		return nil
	end
	return value
end

local function serialize(schema: any, value: any): any
	if schema.type == "color" then
		return (value :: Color3):ToHex()
	end
	return value
end

SettingsStore.coerce = coerce

function SettingsStore.new(plugin: Plugin)
	return setmetatable({ plugin = plugin, _values = {} }, SettingsStore)
end

-- `entry` is a ToolManager entry: { id = "<packId>/<toolId>", definition = class }.
function SettingsStore:getSchema(entry: any, key: string): any
	for _, schema in entry.definition.settings or {} do
		if schema.key == key then
			return schema
		end
	end
	return nil
end

-- Returns the live values table for a tool (the same table is handed to the tool's context).
function SettingsStore:get(entry: any): { [string]: any }
	local values = self._values[entry.id]
	if values then
		return values
	end

	local ok, saved = pcall(self.plugin.GetSetting, self.plugin, SETTINGS_KEY_PREFIX .. entry.id)
	if not ok or type(saved) ~= "table" then
		saved = {}
	end

	values = {}
	for _, schema in entry.definition.settings or {} do
		local value = coerce(schema, saved[schema.key])
		if value == nil then
			value = schema.default
		end
		values[schema.key] = value
	end
	self._values[entry.id] = values
	return values
end

-- Returns the coerced value that was stored, or nil if the value was rejected.
function SettingsStore:set(entry: any, key: string, value: any): any
	local schema = self:getSchema(entry, key)
	if not schema then
		return nil
	end
	local coerced = coerce(schema, value)
	if coerced == nil then
		return nil
	end
	local values = self:get(entry)
	values[key] = coerced

	local serialized = {}
	for _, s in entry.definition.settings or {} do
		if values[s.key] ~= nil then
			serialized[s.key] = serialize(s, values[s.key])
		end
	end
	pcall(self.plugin.SetSetting, self.plugin, SETTINGS_KEY_PREFIX .. entry.id, serialized)
	return coerced
end

return SettingsStore
