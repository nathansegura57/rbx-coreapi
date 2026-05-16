--!strict

local InstanceMethods = {}

local Connection = require(script.Parent.Parent.Connection)
local ErrorHandler = require(script.Parent.Parent.ErrorHandler)
local Scheduler = require(script.Parent.Parent.Scheduler)
local Signal = require(script.Parent.Parent.Signal)
local Factories = require(script.Parent._Factories)
local Notifications = require(script.Parent._Notifications)
local Records = require(script.Parent._Records)
local Types = require(script.Parent._Types)
local Validation = require(script.Parent._Validation)

type SubscriberRecord = Types.SubscriberRecord

function InstanceMethods:Get(): any
	return Records.GetRequiredStoreRecord(self, "Store.Get: store is destroyed").Value
end

function InstanceMethods:Set(value: any): ()
	local storeRecord = Records.GetRequiredStoreRecord(self, "Store.Set: store is destroyed")

	if storeRecord.Kind == "readonly" then
		ErrorHandler.RaiseUsageError("Store.Set: store is read-only")
	end

	if storeRecord.Kind ~= "value" then
		ErrorHandler.RaiseUsageError("Store.Set: only writable stores support Set")
	end

	local oldValue = storeRecord.Value
	if Notifications.StoreValuesAreEqual(storeRecord, oldValue, value) then
		return
	end

	storeRecord.Value = value

	for _, derivedConsumer in storeRecord.DerivedConsumers do
		Notifications.RecomputeDerivedStore(derivedConsumer)
	end

	Notifications.MarkStoreDirty(self, oldValue)
end

function InstanceMethods:Update(updater: any): ()
	local storeRecord = Records.GetRequiredStoreRecord(self, "Store.Update: store is destroyed")

	if type(updater) ~= "function" then
		ErrorHandler.RaiseUsageError("Store.Update: updater must be a function")
	end

	local updateSucceeded, updatedValue, updateError = ErrorHandler.Protect(function(): any
		return updater(storeRecord.Value)
	end, "Store", "Update")

	if not updateSucceeded then
		return
	end

	InstanceMethods.Set(self, updatedValue)
end

function InstanceMethods:Subscribe(listener: any, options: any?): Connection.Connection
	local storeRecord = Records.GetRequiredStoreRecord(self, "Store.Subscribe: store is destroyed")

	if type(listener) ~= "function" then
		ErrorHandler.RaiseUsageError("Store.Subscribe: listener must be a function")
	end

	local immediate, deferred = Validation.GetValidatedSubscribeOptions(options)
	local subscriberRecord: SubscriberRecord = {
		Connected = true,
		Listener = listener,
	}

	table.insert(storeRecord.Subscribers, subscriberRecord)

	local connection = Connection.New(function()
		subscriberRecord.Connected = false
	end)

	if immediate and not deferred then
		ErrorHandler.Protect(function()
			listener(storeRecord.Value, nil)
		end, "Store", "Subscribe")
	elseif immediate and deferred then
		local currentValue = storeRecord.Value

		Scheduler.Defer(function()
			if subscriberRecord.Connected then
				ErrorHandler.Protect(function()
					listener(currentValue, nil)
				end, "Store", "Subscribe")
			end
		end)
	end

	return connection
end

function InstanceMethods:Changed(): any
	local storeRecord = Records.GetRequiredStoreRecord(self, "Store.Changed: store is destroyed")

	if storeRecord.ChangedSignal == nil then
		storeRecord.ChangedSignal = Signal.New()
	end

	return storeRecord.ChangedSignal
end

function InstanceMethods:Map(picker: any, equals: any?): any
	return Factories.Select(self, picker, equals)
end

function InstanceMethods:Equals(equals: any): any
	Records.GetRequiredStoreRecord(self, "Store.Equals: store is destroyed")

	if type(equals) ~= "function" then
		ErrorHandler.RaiseUsageError("Store.Equals: equals must be a function")
	end

	local sourceStore = self

	return Factories.Derive(function(): any
		return Records.GetRequiredStoreRecord(sourceStore, "Store.Equals: source store destroyed").Value
	end, { sourceStore }, {
		Equals = equals,
	})
end

function InstanceMethods:Name(): string?
	local storeRecord = Records.GetStoreRecord(self)

	if storeRecord == nil or storeRecord.Destroyed then
		return nil
	end

	return storeRecord.Name
end

function InstanceMethods:Deps(): { any }
	local storeRecord = Records.GetStoreRecord(self)

	if storeRecord == nil or storeRecord.Destroyed then
		return {}
	end

	return table.clone(storeRecord.Dependencies)
end

function InstanceMethods:Wait(): (any, any)
	local storeRecord = Records.GetRequiredStoreRecord(self, "Store.Wait: store destroyed")

	if not coroutine.isyieldable() then
		ErrorHandler.RaiseUsageError("Store.Wait: must be called from a yieldable coroutine")
	end

	local waitingThread = coroutine.running() :: thread
	table.insert(storeRecord.Waiters, {
		Thread = waitingThread,
	})

	local resumedSuccessfully, newValue, oldValue = coroutine.yield()

	if not resumedSuccessfully then
		ErrorHandler.RaiseUsageError("Store.Wait: store destroyed")
	end

	return newValue, oldValue
end

function InstanceMethods:DisconnectAll(): ()
	local storeRecord = Records.GetStoreRecord(self)

	if storeRecord == nil then
		return
	end

	for _, subscriberRecord in storeRecord.Subscribers do
		subscriberRecord.Connected = false
	end

	table.clear(storeRecord.Subscribers)
end

function InstanceMethods:IsDestroyed(): boolean
	local storeRecord = Records.GetStoreRecord(self)
	return storeRecord == nil or storeRecord.Destroyed
end

function InstanceMethods:Destroy(): ()
	local storeRecord = Records.GetStoreRecord(self)

	if storeRecord == nil or storeRecord.Destroyed then
		return
	end

	storeRecord.Destroyed = true

	local derivedConsumers = table.clone(storeRecord.DerivedConsumers)
	table.clear(storeRecord.DerivedConsumers)

	for _, derivedConsumer in derivedConsumers do
		InstanceMethods.Destroy(derivedConsumer)
	end

	for _, subscriberRecord in storeRecord.Subscribers do
		subscriberRecord.Connected = false
	end

	table.clear(storeRecord.Subscribers)

	local waiters = table.clone(storeRecord.Waiters)
	table.clear(storeRecord.Waiters)

	for _, waiterRecord in waiters do
		local waitingThread = waiterRecord.Thread

		Scheduler.Defer(function()
			coroutine.resume(waitingThread, false, nil, nil)
		end)
	end

	if storeRecord.ChangedSignal ~= nil then
		storeRecord.ChangedSignal:Destroy()
		storeRecord.ChangedSignal = nil
	end

	if storeRecord.Name ~= nil then
		Records.ForgetNamedStoreIfStillRegistered(storeRecord.Name, self)
	end

	for _, dependencyStore in storeRecord.Dependencies do
		Records.DetachDerivedConsumerFromDependency(dependencyStore, self)
	end

	table.clear(storeRecord.Dependencies)
end

return InstanceMethods

