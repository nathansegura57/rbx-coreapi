--!strict

local Connection = require(script.Parent.Parent.Connection)
local Scheduler = require(script.Parent.Parent.Scheduler)
local ErrorHandler = require(script.Parent.Parent.ErrorHandler)
local Types = require(script.Parent._Types)

local Records = {}

type ListenerEntry = Types.ListenerEntry
type WaiterEntry = Types.WaiterEntry
type ReplayEntry = Types.ReplayEntry
type SignalRecord = Types.SignalRecord
type SignalMethods = Types.SignalMethods


local signalRecordsByHandle: { [any]: SignalRecord } =
	setmetatable({}, { __mode = "k" }) :: any


function Records.getSignalRecord(signalHandle: any): SignalRecord?
	return signalRecordsByHandle[signalHandle]
end

function Records.getLiveSignalRecordOrError(signalHandle: any, usageErrorMessage: string): SignalRecord
	local signalRecord = signalRecordsByHandle[signalHandle]

	if signalRecord == nil or signalRecord.Destroyed then
		error(usageErrorMessage, 2)
	end

	return signalRecord
end

function Records.isLiveSignalHandle(value: unknown): boolean
	if type(value) ~= "table" then
		return false
	end

	local signalRecord = signalRecordsByHandle[value :: any]

	return signalRecord ~= nil and not signalRecord.Destroyed
end

function Records.createSignalHandle(signalMethods: SignalMethods, isNeverSignal: boolean): any
	local signalHandle = setmetatable({}, {
		__index = function(_self: any, key: string): any
			return signalMethods[key]
		end,

		__newindex = function(_self: any, key: string, _value: any): ()
			error(`Signal: '{tostring(key)}' is read-only`, 2)
		end,

		__metatable = "Signal",
	})

	signalRecordsByHandle[signalHandle] = {
		Destroyed = false,
		IsNever = isNeverSignal,

		Listeners = {},
		FireDepth = 0,
		Waiters = {},

		ReplayPolicy = nil,
		ReplayCountLimit = 0,
		ReplayTimeWindow = 0,
		ReplayBuffer = {},

		CleanupCallbacks = {},
		TimerHandles = {},
	}

	return signalHandle
end


function Records.compactDisconnectedListenersWhenSafe(signalRecord: SignalRecord): ()
	if signalRecord.FireDepth > 0 then
		return
	end

	local connectedListeners: { ListenerEntry } = {}

	for _, listenerEntry in signalRecord.Listeners do
		if listenerEntry.Connected then
			table.insert(connectedListeners, listenerEntry)
		end
	end

	signalRecord.Listeners = connectedListeners
end

function Records.createConnectionForListener(signalRecord: SignalRecord, listenerEntry: ListenerEntry): Connection.Connection
	return Connection.New(function()
		listenerEntry.Connected = false
		Records.compactDisconnectedListenersWhenSafe(signalRecord)
	end)
end

function Records.attachCleanupCallback(signalHandle: any, cleanupCallback: () -> ()): ()
	local signalRecord = signalRecordsByHandle[signalHandle]

	if signalRecord == nil or signalRecord.Destroyed then
		ErrorHandler.Protect(cleanupCallback, "Signal", "Cleanup")
		return
	end

	table.insert(signalRecord.CleanupCallbacks, cleanupCallback)
end

function Records.attachTimerHandle(signalHandle: any, timerHandle: any): ()
	local signalRecord = signalRecordsByHandle[signalHandle]

	if signalRecord == nil or signalRecord.Destroyed then
		Scheduler.Cancel(timerHandle)
		return
	end

	table.insert(signalRecord.TimerHandles, timerHandle)
end

function Records.clearTimerHandles(signalRecord: SignalRecord): ()
	for _, timerHandle in signalRecord.TimerHandles do
		Scheduler.Cancel(timerHandle)
	end

	table.clear(signalRecord.TimerHandles)
end


function Records.connectDerivedSignal(sourceSignal: any, derivedSignal: any, listener: (any) -> ()): ListenerEntry
	local sourceRecord = Records.getLiveSignalRecordOrError(sourceSignal, "Signal: source signal is destroyed")
	local derivedRecord = Records.getLiveSignalRecordOrError(derivedSignal, "Signal: derived signal is destroyed")

	local listenerEntry: ListenerEntry = {
		Connected = true,
		Fn = listener,
	}

	table.insert(sourceRecord.Listeners, listenerEntry)

	table.insert(sourceRecord.CleanupCallbacks, function()
		if not derivedRecord.Destroyed then
			derivedSignal:Destroy()
		end
	end)

	table.insert(derivedRecord.CleanupCallbacks, function()
		listenerEntry.Connected = false
		Records.compactDisconnectedListenersWhenSafe(sourceRecord)
	end)

	return listenerEntry
end


return table.freeze(Records)

