--!strict

local ErrorHandler = require(script.Parent.ErrorHandler)

local Connection = {}

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

type Record = {
	Connected: boolean,
	DisconnectFn: (() -> ())?,
}

-- Weak keys: records are kept as long as the handle has a strong reference.
local records: { [any]: Record } = setmetatable({}, { __mode = "k" }) :: any

local function disconnect(self: Connection): ()
	local record: Record? = records[self :: any]
	if record == nil then
		error("Connection.Disconnect: invalid connection")
	end
	if not record.Connected then
		return
	end
	-- Set Connected = false before running DisconnectFn.
	record.Connected = false
	local fn = record.DisconnectFn
	-- Clear before calling so it cannot run twice, even if Report throws.
	record.DisconnectFn = nil
	if fn ~= nil then
		ErrorHandler.Protect(fn, "Connection", "Disconnect")
	end
end

local handleMeta = {
	__index = function(self: any, key: string): any
		if key == "Connected" then
			local record: Record? = records[self]
			return if record ~= nil then record.Connected else false
		elseif key == "Disconnect" then
			return disconnect
		end
		return nil
	end,
	__newindex = function(_self: any, key: string, _value: any): ()
		error(`Connection: '{tostring(key)}' is read-only`)
	end,
	__metatable = "Connection",
}

function Connection.New(disconnectFn: (() -> ())?): Connection
	if disconnectFn ~= nil and type(disconnectFn) ~= "function" then
		error("Connection.New: disconnectFn must be a function or nil")
	end
	local handle: any = setmetatable({}, handleMeta)
	records[handle] = {
		Connected = true,
		DisconnectFn = disconnectFn,
	}
	return handle :: Connection
end

function Connection.IsConnection(value: unknown): boolean
	if type(value) ~= "table" then
		return false
	end
	return records[value :: any] ~= nil
end

return Connection

