--!strict

local Records = {}

local ErrorHandler = require(script.Parent.Parent.ErrorHandler)
local Types = require(script.Parent._Types)

type StoreKind = Types.StoreKind
type StoreRecord = Types.StoreRecord

local storeRecordsByHandle: { [any]: StoreRecord } = setmetatable({}, { __mode = "k" }) :: any
local namedStoresByName: { [string]: any } = {}
local instanceMethodsByName: { [string]: any } = {}

local storeHandleMetatable = {
	__index = function(_storeHandle: any, key: string): any
		return instanceMethodsByName[key]
	end,

	__newindex = function(_storeHandle: any, key: string, _value: any): ()
		ErrorHandler.RaiseUsageError(`Store: '{tostring(key)}' is read-only`)
	end,

	__metatable = "Store",
}


function Records.UseInstanceMethods(instanceMethods: { [string]: any }): ()
	for methodName, method in instanceMethods do
		instanceMethodsByName[methodName] = method
	end
end

function Records.CreateStoreHandle(storeKind: StoreKind): any
	local storeHandle = setmetatable({}, storeHandleMetatable)

	storeRecordsByHandle[storeHandle] = {
		Destroyed = false,
		Kind = storeKind,
		Value = nil,
		Dirty = false,
		DirtyOldValue = nil,
		Subscribers = {},
		Waiters = {},
		ChangedSignal = nil,
		Name = nil,
		Equals = nil,
		Compute = nil,
		Dependencies = {},
		DerivedConsumers = {},
	}

	return storeHandle
end

function Records.ValueIsLiveStoreHandle(value: unknown): boolean
	return type(value) == "table" and storeRecordsByHandle[value :: any] ~= nil
end

function Records.GetStoreRecord(storeHandle: any): StoreRecord?
	return storeRecordsByHandle[storeHandle]
end

function Records.GetRequiredStoreRecord(storeHandle: any, usageErrorMessage: string): StoreRecord
	local storeRecord = storeRecordsByHandle[storeHandle]

	if storeRecord == nil or storeRecord.Destroyed then
		ErrorHandler.RaiseUsageError(usageErrorMessage)
	end

	return storeRecord
end

function Records.RegisterNamedStore(name: string, storeHandle: any): ()
	namedStoresByName[name] = storeHandle
end

function Records.ForgetNamedStoreIfStillRegistered(name: string, storeHandle: any): ()
	if namedStoresByName[name] == storeHandle then
		namedStoresByName[name] = nil
	end
end

function Records.GetNamedStore(name: string): any?
	return namedStoresByName[name]
end

function Records.NameIsAlreadyRegistered(name: string): boolean
	return namedStoresByName[name] ~= nil
end

function Records.DetachDerivedConsumerFromDependency(dependencyStoreHandle: any, consumerStoreHandle: any): ()
	local dependencyRecord = Records.GetStoreRecord(dependencyStoreHandle)

	if dependencyRecord == nil then
		return
	end

	for index, derivedConsumer in dependencyRecord.DerivedConsumers do
		if derivedConsumer == consumerStoreHandle then
			table.remove(dependencyRecord.DerivedConsumers, index)
			return
		end
	end
end

return Records

