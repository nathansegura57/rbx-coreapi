--!strict

local Scheduler = require(script.Parent.Parent.Scheduler)
local ErrorHandler = require(script.Parent.Parent.ErrorHandler)

local Records = require(script.Parent._Records)
local Replay = require(script.Parent._Replay)
local Validation = require(script.Parent._Validation)
local Types = require(script.Parent._Types)

local Core = {}

type ListenerEntry = Types.ListenerEntry
type WaiterEntry = Types.WaiterEntry
type SignalRecord = Types.SignalRecord
type SignalMethods = Types.SignalMethods
type SignalModule = Types.SignalModule


function Core.disconnectAllListeners(signalRecord: SignalRecord): ()
	for _, listenerEntry in signalRecord.Listeners do
		listenerEntry.Connected = false
	end

	if signalRecord.FireDepth == 0 then
		table.clear(signalRecord.Listeners)
	end
end

function Core.resumeWaiterWithPayload(waiterThread: thread, payload: any): ()
	Scheduler.Defer(function()
		coroutine.resume(waiterThread, true, payload)
	end)
end

function Core.resumeWaiterWithDestroyedError(waiterThread: thread): ()
	Scheduler.Defer(function()
		coroutine.resume(waiterThread, false, nil)
	end)
end

function Core.runSignalCleanupCallbacks(signalRecord: SignalRecord): ()
	local cleanupCallbacks = table.clone(signalRecord.CleanupCallbacks)
	table.clear(signalRecord.CleanupCallbacks)

	for _, cleanupCallback in cleanupCallbacks do
		ErrorHandler.Protect(cleanupCallback, "Signal", "Cleanup")
	end
end


function Core.defineCoreInstanceMethods(signalMethods: SignalMethods): ()
	function signalMethods:Connect(listener: (any) -> ()): any
		Validation.ensureCallback(listener, "Signal.Connect: listener must be a function")

		local signalRecord = Records.getLiveSignalRecordOrError(self, "Signal.Connect: signal is destroyed")

		local listenerEntry: ListenerEntry = {
			Connected = true,
			Fn = listener,
		}

		table.insert(signalRecord.Listeners, listenerEntry)

		local connection = Records.createConnectionForListener(signalRecord, listenerEntry)

		Replay.scheduleReplayForNewListener(signalRecord, listenerEntry)

		return connection
	end

	function signalMethods:Once(listener: (any) -> ()): any
		Validation.ensureCallback(listener, "Signal.Once: listener must be a function")

		local signalRecord = Records.getLiveSignalRecordOrError(self, "Signal.Once: signal is destroyed")

		local listenerEntry: ListenerEntry

		listenerEntry = {
			Connected = true,

			Fn = function(payload: any): ()
				if not listenerEntry.Connected then
					return
				end

				listenerEntry.Connected = false
				Records.compactDisconnectedListenersWhenSafe(signalRecord)

				listener(payload)
			end,
		}

		table.insert(signalRecord.Listeners, listenerEntry)

		local connection = Records.createConnectionForListener(signalRecord, listenerEntry)

		Replay.scheduleReplayForNewListener(signalRecord, listenerEntry)

		return connection
	end

	function signalMethods:Fire(payload: any): ()
		local signalRecord = Records.getSignalRecord(self)

		if signalRecord == nil or signalRecord.Destroyed then
			return
		end

		if signalRecord.IsNever then
			error("Signal.Fire: cannot fire a never signal", 2)
		end

		Replay.storePayloadForActiveReplayPolicy(signalRecord, payload)

		signalRecord.FireDepth += 1

		local listenerSnapshot = signalRecord.Listeners
		local listenerCount = #listenerSnapshot

		for listenerIndex = 1, listenerCount do
			local listenerEntry = listenerSnapshot[listenerIndex]

			if listenerEntry.Connected then
				ErrorHandler.Protect(function()
					listenerEntry.Fn(payload)
				end, "Signal", "Listener")
			end
		end

		signalRecord.FireDepth -= 1

		if signalRecord.FireDepth == 0 then
			Records.compactDisconnectedListenersWhenSafe(signalRecord)
		end
	end

	function signalMethods:Wait(): any
		local signalRecord = Records.getLiveSignalRecordOrError(self, "Signal.Wait: signal is destroyed")

		if not coroutine.isyieldable() then
			error("Signal.Wait: must be called from a yieldable coroutine", 2)
		end

		local waiterThread = coroutine.running() :: thread

		local waiterEntry: WaiterEntry = {
			Thread = waiterThread,
		}

		table.insert(signalRecord.Waiters, waiterEntry)

		local listenerEntry: ListenerEntry

		listenerEntry = {
			Connected = true,

			Fn = function(payload: any): ()
				if not listenerEntry.Connected then
					return
				end

				listenerEntry.Connected = false

				for waiterIndex = 1, #signalRecord.Waiters do
					if signalRecord.Waiters[waiterIndex] == waiterEntry then
						table.remove(signalRecord.Waiters, waiterIndex)
						break
					end
				end

				Core.resumeWaiterWithPayload(waiterThread, payload)
			end,
		}

		table.insert(signalRecord.Listeners, listenerEntry)

		local waitSucceeded, waitedPayload = coroutine.yield()

		if not waitSucceeded then
			error("Signal.Wait: signal destroyed", 2)
		end

		return waitedPayload
	end

	function signalMethods:DisconnectAll(): ()
		local signalRecord = Records.getSignalRecord(self)

		if signalRecord == nil then
			return
		end

		Core.disconnectAllListeners(signalRecord)
	end

	function signalMethods:Destroy(): ()
		local signalRecord = Records.getSignalRecord(self)

		if signalRecord == nil or signalRecord.Destroyed then
			return
		end

		signalRecord.Destroyed = true

		Core.disconnectAllListeners(signalRecord)

		local waiters = table.clone(signalRecord.Waiters)
		table.clear(signalRecord.Waiters)

		for _, waiterEntry in waiters do
			Core.resumeWaiterWithDestroyedError(waiterEntry.Thread)
		end

		table.clear(signalRecord.ReplayBuffer)
		signalRecord.ReplayPolicy = nil

		Records.clearTimerHandles(signalRecord)
		Core.runSignalCleanupCallbacks(signalRecord)
	end

	function signalMethods:IsDestroyed(): boolean
		local signalRecord = Records.getSignalRecord(self)

		return signalRecord == nil or signalRecord.Destroyed
	end
end


return table.freeze(Core)

