--!strict
--!optimize 2

-- Internal: canonical Connection handle factory.
-- Signal, Store, and Task each implement their own disconnect logic as closures;
-- this module provides the single shared handle type and lifecycle management.
--
-- Disconnect idempotency is guaranteed by this module — performDisconnect is
-- called at most once per Connection, so implementations need not guard for it.

export type Connection = {
	Connected:  boolean,
	Disconnect: (self: Connection) -> (),
}

type ConnectionRecord = {
	isStillConnected:  () -> boolean,
	performDisconnect: () -> (),
}

-- Weak-keyed: GC collects abandoned Connection handles automatically.
local connectionRecords: { [any]: ConnectionRecord } =
	setmetatable({}, { __mode = "k" } :: { __mode: "k" }) :: any

local connectionMethods = {}

function connectionMethods:Disconnect()
	local record = connectionRecords[self]
	if not record then return end
	connectionRecords[self] = nil
	record.performDisconnect()
end

local CONNECTION_META = {
	__metatable = "Connection",
	__newindex  = function(_, key: string)
		error(`Connection: '{key}' is read-only`, 2)
	end,
	__index = function(self, key: string): any
		if key == "Connected" then
			local record = connectionRecords[self]
			return record ~= nil and record.isStillConnected()
		end
		return connectionMethods[key]
	end,
}

-- Creates a live Connection handle.
--   isStillConnected  — returns true while the underlying subscription is active.
--   performDisconnect — invoked exactly once on the first Disconnect() call.
local function create(
	isStillConnected:  () -> boolean,
	performDisconnect: () -> ()
): Connection
	local handle = setmetatable({}, CONNECTION_META)
	connectionRecords[handle] = {
		isStillConnected  = isStillConnected,
		performDisconnect = performDisconnect,
	}
	return handle :: any
end

-- A permanently-disconnected Connection singleton.
-- Returned by Token:onCancel() when the token is already cancelled at call time.
local DEAD_CONNECTION_META = {
	__metatable = "Connection",
	__newindex  = function(_, key: string)
		error(`Connection: '{key}' is read-only`, 2)
	end,
	__index = function(_, key: string): any
		if key == "Connected"  then return false end
		if key == "Disconnect" then return function() end end
		return nil
	end,
}

local deadConnectionHandle: Connection = setmetatable({}, DEAD_CONNECTION_META) :: any

local function dead(): Connection
	return deadConnectionHandle
end

table.freeze(connectionMethods)
return table.freeze({
	create = create,
	dead   = dead,
})

