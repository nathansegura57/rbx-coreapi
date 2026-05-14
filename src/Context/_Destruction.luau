--!strict

local Connection = require(script.Parent.Parent.Connection)
local ErrorHandler = require(script.Parent.Parent.ErrorHandler)
local Scheduler = require(script.Parent.Parent.Scheduler)
local Records = require(script.Parent._Records)
local Types = require(script.Parent._Types)


type BaseContext<Value> = Types.BaseContext<Value>
type ContextPrivateState = Types.ContextPrivateState
type DestroyCallback = Types.DestroyCallback
type DestroyCallbackEntry = Types.DestroyCallbackEntry


local Destruction = {}


function Destruction.DestroyContextHandleIfStillAlive(contextHandle: BaseContext<unknown>): ()
	local contextPrivateState = Records.GetContextPrivateStateWithoutValidation(contextHandle)

	if contextPrivateState == nil or contextPrivateState.IsDestroyed then
		return
	end

	contextPrivateState.IsDestroyed = true

	Destruction.DestroyChildContexts(contextPrivateState)
	Destruction.RunContextCleanupCallbackIfPresent(contextPrivateState)
	Destruction.RunRegisteredDestroyCallbacks(contextPrivateState)
	Destruction.ReleaseContextOwnedStorage(contextPrivateState)
end

function Destruction.DestroyChildContexts(contextPrivateState: ContextPrivateState): ()
	local childContextHandles = table.clone(contextPrivateState.ChildContextHandles)
	table.clear(contextPrivateState.ChildContextHandles)

	for _, childContextHandle in childContextHandles do
		Destruction.DestroyContextHandleIfStillAlive(childContextHandle :: any)
	end
end

function Destruction.RunContextCleanupCallbackIfPresent(contextPrivateState: ContextPrivateState): ()
	local cleanupCallback = contextPrivateState.CleanupCallback
	contextPrivateState.CleanupCallback = nil

	if cleanupCallback ~= nil then
		ErrorHandler.Protect(cleanupCallback, "Context", "Destroy")
	end
end

function Destruction.RunRegisteredDestroyCallbacks(contextPrivateState: ContextPrivateState): ()
	local destroyCallbackEntries = table.clone(contextPrivateState.DestroyCallbackEntries)
	table.clear(contextPrivateState.DestroyCallbackEntries)

	for _, destroyCallbackEntry in destroyCallbackEntries do
		ErrorHandler.Protect(destroyCallbackEntry.Callback, "Context", "OnDestroy")
	end
end

function Destruction.ReleaseContextOwnedStorage(contextPrivateState: ContextPrivateState): ()
	table.clear(contextPrivateState.StoredValueByKey)
	table.clear(contextPrivateState.LazyProviderByKey)
end

function Destruction.RegisterDestroyCallback(
	contextPrivateState: ContextPrivateState,
	destroyCallback: DestroyCallback
): Connection.Connection
	local destroyCallbackEntry = {
		Callback = destroyCallback,
	}

	table.insert(contextPrivateState.DestroyCallbackEntries, destroyCallbackEntry)

	return Connection.New(function()
		Destruction.RemoveDestroyCallbackEntryFromList(
			contextPrivateState.DestroyCallbackEntries,
			destroyCallbackEntry
		)
	end)
end

function Destruction.ScheduleDestroyCallbackBecauseContextIsAlreadyDestroyed(
	destroyCallback: DestroyCallback
): Connection.Connection
	Scheduler.Defer(destroyCallback)

	local alreadyDisconnectedConnection = Connection.New(nil)
	alreadyDisconnectedConnection:Disconnect()

	return alreadyDisconnectedConnection
end

function Destruction.RemoveDestroyCallbackEntryFromList(
	destroyCallbackEntries: { DestroyCallbackEntry },
	destroyCallbackEntryToRemove: DestroyCallbackEntry
): ()
	for index, destroyCallbackEntry in destroyCallbackEntries do
		if destroyCallbackEntry == destroyCallbackEntryToRemove then
			table.remove(destroyCallbackEntries, index)
			return
		end
	end
end


return table.freeze(Destruction)

