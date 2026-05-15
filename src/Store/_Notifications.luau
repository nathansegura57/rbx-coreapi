--!strict

local Notifications = {}

local ErrorHandler = require(script.Parent.Parent.ErrorHandler)
local Scheduler = require(script.Parent.Parent.Scheduler)
local Records = require(script.Parent._Records)
local Types = require(script.Parent._Types)

type StoreRecord = Types.StoreRecord

local batchDepth = 0
local transactionDepth = 0
local dirtyStores: { [any]: boolean } = {}
local flushIsScheduled = false

function Notifications.DefaultValuesAreEqual(firstValue: any, secondValue: any): boolean
	return firstValue == secondValue
end

function Notifications.StoreValuesAreEqual(storeRecord: StoreRecord, firstValue: any, secondValue: any): boolean
	local valuesAreEqual: (any, any) -> boolean = if storeRecord.Equals ~= nil then storeRecord.Equals else Notifications.DefaultValuesAreEqual

	local equalitySucceeded, equalityResult = ErrorHandler.Protect(function(): boolean
		return valuesAreEqual(firstValue, secondValue)
	end, "Store", "Equals")

	if not equalitySucceeded then
		return false
	end

	return equalityResult == true
end

function Notifications.MarkStoreDirty(storeHandle: any, oldValue: any): ()
	local storeRecord = Records.GetStoreRecord(storeHandle)

	if storeRecord == nil or storeRecord.Destroyed or storeRecord.Dirty then
		return
	end

	storeRecord.Dirty = true
	storeRecord.DirtyOldValue = oldValue
	dirtyStores[storeHandle] = true

	if batchDepth > 0 or transactionDepth > 0 then
		return
	end

	Notifications.ScheduleDeferredFlushIfNeeded()
end

function Notifications.RecomputeDerivedStore(storeHandle: any): ()
	local storeRecord = Records.GetStoreRecord(storeHandle)

	if storeRecord == nil or storeRecord.Destroyed or storeRecord.Compute == nil then
		return
	end

	local oldValue = storeRecord.Value
	local computeSucceeded, computedValue = ErrorHandler.Protect(storeRecord.Compute, "Store", "Derive")

	if not computeSucceeded then
		return
	end

	if Notifications.StoreValuesAreEqual(storeRecord, oldValue, computedValue) then
		return
	end

	storeRecord.Value = computedValue
	Notifications.MarkStoreDirty(storeHandle, oldValue)

	for _, derivedConsumer in storeRecord.DerivedConsumers do
		Notifications.RecomputeDerivedStore(derivedConsumer)
	end
end

function Notifications.FlushStore(storeHandle: any): ()
	local storeRecord = Records.GetStoreRecord(storeHandle)

	if storeRecord == nil or not storeRecord.Dirty then
		return
	end

	local newValue = storeRecord.Value
	local oldValue = storeRecord.DirtyOldValue

	storeRecord.Dirty = false
	storeRecord.DirtyOldValue = nil

	local subscribersSnapshot = table.clone(storeRecord.Subscribers)

	for _, subscriberRecord in subscribersSnapshot do
		if subscriberRecord.Connected then
			ErrorHandler.Protect(function()
				subscriberRecord.Listener(newValue, oldValue)
			end, "Store", "Subscribe")
		end
	end

	local connectedSubscribers = {}

	for _, subscriberRecord in storeRecord.Subscribers do
		if subscriberRecord.Connected then
			table.insert(connectedSubscribers, subscriberRecord)
		end
	end

	storeRecord.Subscribers = connectedSubscribers

	if storeRecord.ChangedSignal ~= nil and not storeRecord.ChangedSignal:IsDestroyed() then
		storeRecord.ChangedSignal:Fire({
			New = newValue,
			Old = oldValue,
		})
	end

	local waitersSnapshot = table.clone(storeRecord.Waiters)
	table.clear(storeRecord.Waiters)

	for _, waiterRecord in waitersSnapshot do
		local waitingThread = waiterRecord.Thread

		Scheduler.Defer(function()
			coroutine.resume(waitingThread, true, newValue, oldValue)
		end)
	end
end

function Notifications.FlushAllDirtyStores(): ()
	while next(dirtyStores) ~= nil do
		local dirtyStoreSnapshot = {}

		for storeHandle in dirtyStores do
			table.insert(dirtyStoreSnapshot, storeHandle)
		end

		table.clear(dirtyStores)

		for _, storeHandle in dirtyStoreSnapshot do
			Notifications.FlushStore(storeHandle)
		end
	end
end

function Notifications.ScheduleDeferredFlushIfNeeded(): ()
	if flushIsScheduled then
		return
	end

	flushIsScheduled = true

	Scheduler.Defer(function()
		flushIsScheduled = false
		Notifications.FlushAllDirtyStores()
	end)
end

function Notifications.EnterBatch(): ()
	batchDepth += 1
end

function Notifications.LeaveBatchAndFlushIfOutermost(): ()
	batchDepth -= 1

	if batchDepth == 0 and transactionDepth == 0 then
		Notifications.FlushAllDirtyStores()
	end
end

function Notifications.EnterTransaction(): ()
	transactionDepth += 1
end

function Notifications.LeaveTransactionAndScheduleFlushIfOutermost(): ()
	transactionDepth -= 1

	if batchDepth == 0 and transactionDepth == 0 then
		Notifications.ScheduleDeferredFlushIfNeeded()
	end
end

return Notifications

