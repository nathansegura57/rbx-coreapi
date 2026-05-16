--!strict

local ErrorHandler = require(script.Parent.ErrorHandler)


export type DisconnectCallback = () -> ()

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

export type ConnectionModule = {
	New: (disconnectCallback: DisconnectCallback?) -> Connection,
	IsConnection: (value: unknown) -> boolean,
}


local Connection = {} :: ConnectionModule
local ConnectionHandleMethods = {}


type ConnectionPrivateState = {
	IsConnected: boolean,
	DisconnectCallback: DisconnectCallback?,
}

type ConnectionPrivateStateByHandle = {
	[Connection]: ConnectionPrivateState,
}

type ConnectionHandleMetatable = {
	__index: (connectionHandle: Connection, key: string) -> unknown,
	__newindex: (connectionHandle: Connection, key: string, value: unknown) -> never,
	__metatable: string,
}


local connectionPrivateStateByHandle: ConnectionPrivateStateByHandle = setmetatable({}, {
	__mode = "k",
}) :: any

local ConnectionHandleMetatable: ConnectionHandleMetatable


function Connection.New(disconnectCallback: DisconnectCallback?): Connection
	local validatedDisconnectCallback = getValidatedDisconnectCallback(disconnectCallback)
	local connectionHandle = createConnectionHandle()

	connectionPrivateStateByHandle[connectionHandle] = createConnectionPrivateState(validatedDisconnectCallback)

	return connectionHandle
end

function Connection.IsConnection(value: unknown): boolean
	return valueIsConnectionHandle(value)
end


function ConnectionHandleMethods.Disconnect(connectionHandle: Connection): ()
	local connectionPrivateState = getConnectionPrivateStateOrRaiseInvalidHandleError(connectionHandle)

	disconnectConnectionIfStillConnected(connectionHandle, connectionPrivateState)
end


function createConnectionHandle(): Connection
	return setmetatable({}, ConnectionHandleMetatable) :: any
end

function createConnectionPrivateState(disconnectCallback: DisconnectCallback?): ConnectionPrivateState
	return {
		IsConnected = true,
		DisconnectCallback = disconnectCallback,
	}
end


function valueIsConnectionHandle(value: unknown): boolean
	return getConnectionPrivateStateIfValueIsConnectionHandle(value) ~= nil
end

function getConnectionPrivateStateIfValueIsConnectionHandle(value: unknown): ConnectionPrivateState?
	if typeof(value) ~= "table" then
		return nil
	end

	return connectionPrivateStateByHandle[value :: Connection]
end

function getConnectionPrivateStateOrRaiseInvalidHandleError(connectionHandle: Connection): ConnectionPrivateState
	local connectionPrivateState = connectionPrivateStateByHandle[connectionHandle]

	if connectionPrivateState ~= nil then
		return connectionPrivateState
	end

	return raiseConnectionUsageError("Connection.Disconnect: invalid connection handle")
end


function getConnectionHandlePublicProperty(connectionHandle: Connection, key: string): unknown
	if key == "Connected" then
		return getCurrentConnectedState(connectionHandle)
	end

	if key == "Disconnect" then
		return ConnectionHandleMethods.Disconnect
	end

	return nil
end

function rejectConnectionHandlePublicMutation(_connectionHandle: Connection, key: string, _value: unknown): never
	return raiseConnectionUsageError(`Connection: '{tostring(key)}' is read-only`)
end


function getCurrentConnectedState(connectionHandle: Connection): boolean
	local connectionPrivateState = connectionPrivateStateByHandle[connectionHandle]

	if connectionPrivateState == nil then
		return false
	end

	return connectionPrivateState.IsConnected
end

function disconnectConnectionIfStillConnected(
	_connectionHandle: Connection,
	connectionPrivateState: ConnectionPrivateState
): ()
	if not connectionPrivateState.IsConnected then
		return
	end

	connectionPrivateState.IsConnected = false

	local disconnectCallback = takeDisconnectCallbackFromConnectionPrivateState(connectionPrivateState)

	if disconnectCallback ~= nil then
		runDisconnectCallbackThroughErrorHandler(disconnectCallback)
	end
end

function takeDisconnectCallbackFromConnectionPrivateState(
	connectionPrivateState: ConnectionPrivateState
): DisconnectCallback?
	local disconnectCallback = connectionPrivateState.DisconnectCallback
	connectionPrivateState.DisconnectCallback = nil

	return disconnectCallback
end

function runDisconnectCallbackThroughErrorHandler(disconnectCallback: DisconnectCallback): ()
	ErrorHandler.Protect(disconnectCallback, "Connection", "Disconnect")
end


function getValidatedDisconnectCallback(untrustedDisconnectCallback: unknown?): DisconnectCallback?
	if untrustedDisconnectCallback == nil then
		return nil
	end

	if typeof(untrustedDisconnectCallback) == "function" then
		return untrustedDisconnectCallback :: DisconnectCallback
	end

	return raiseConnectionUsageError("Connection.New: disconnectCallback must be a function or nil")
end

function raiseConnectionUsageError(message: string): never
	return ErrorHandler.RaiseUsageError(message)
end


ConnectionHandleMetatable = table.freeze({
	__index = getConnectionHandlePublicProperty,
	__newindex = rejectConnectionHandlePublicMutation,
	__metatable = "Connection",
})


return table.freeze(Connection)

