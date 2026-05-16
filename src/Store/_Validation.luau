--!strict

local Validation = {}

local ErrorHandler = require(script.Parent.Parent.ErrorHandler)
local Records = require(script.Parent._Records)
local Types = require(script.Parent._Types)

type StoreRecord = Types.StoreRecord

type ParsedValueOptions = {
	Name: string?,
	Equals: ((any, any) -> boolean)?,
	ReplaceName: boolean,
}

function Validation.GetValidatedValueOptions(callerName: string, options: unknown): ParsedValueOptions
	if options == nil then
		return {
			Name = nil,
			Equals = nil,
			ReplaceName = false,
		}
	end

	if type(options) ~= "table" then
		ErrorHandler.RaiseUsageError(`{callerName}: opts must be a table or nil`)
	end

	local optionTable = options :: { [string]: unknown }
	local name = optionTable.Name
	local equals = optionTable.Equals
	local replaceName = optionTable.ReplaceName

	if name ~= nil and (type(name) ~= "string" or #(name :: string) == 0) then
		ErrorHandler.RaiseUsageError(`{callerName}: Name must be a non-empty string or nil`)
	end

	if equals ~= nil and type(equals) ~= "function" then
		ErrorHandler.RaiseUsageError(`{callerName}: Equals must be a function or nil`)
	end

	if replaceName ~= nil and type(replaceName) ~= "boolean" then
		ErrorHandler.RaiseUsageError(`{callerName}: ReplaceName must be a boolean or nil`)
	end

	return {
		Name = name :: string?,
		Equals = equals :: ((any, any) -> boolean)?,
		ReplaceName = if replaceName == nil then false else replaceName :: boolean,
	}
end

function Validation.EnsureNameCanBeRegistered(callerName: string, name: string?, replaceName: boolean): ()
	if name ~= nil and Records.NameIsAlreadyRegistered(name) and not replaceName then
		ErrorHandler.RaiseUsageError(`{callerName}: duplicate store name '{name}'`)
	end
end

function Validation.EnsureValueIsLiveStore(value: unknown, usageErrorMessage: string): StoreRecord
	if not Records.ValueIsLiveStoreHandle(value) then
		ErrorHandler.RaiseUsageError(usageErrorMessage)
	end

	local storeRecord = Records.GetStoreRecord(value :: any)

	if storeRecord == nil or storeRecord.Destroyed then
		ErrorHandler.RaiseUsageError(usageErrorMessage)
	end

	return storeRecord
end

function Validation.EnsureDependencyArrayIsValid(
	callerName: string,
	dependencies: unknown,
	invalidDependencyMessage: (number) -> string
): { any }
	if type(dependencies) ~= "table" or #(dependencies :: { any }) == 0 then
		ErrorHandler.RaiseUsageError(`{callerName}: deps must be a non-empty dense array`)
	end

	local dependencyArray = dependencies :: { any }

	for index = 1, #dependencyArray do
		Validation.EnsureValueIsLiveStore(dependencyArray[index], invalidDependencyMessage(index))
	end

	return dependencyArray
end

function Validation.EnsureStoreArrayIsValid(callerName: string, stores: unknown): { any }
	if type(stores) ~= "table" or #(stores :: { any }) == 0 then
		ErrorHandler.RaiseUsageError(`{callerName}: stores must be a non-empty dense array of live Stores`)
	end

	local storeArray = stores :: { any }

	for index = 1, #storeArray do
		Validation.EnsureValueIsLiveStore(storeArray[index], `{callerName}: entry at index {index} is not a live Store`)
	end

	return storeArray
end

function Validation.GetValidatedSubscribeOptions(options: unknown): (boolean, boolean)
	if options == nil then
		return true, false
	end

	if type(options) ~= "table" then
		ErrorHandler.RaiseUsageError("Store.Subscribe: opts must be a table or nil")
	end

	local optionTable = options :: { [string]: unknown }
	local immediate = optionTable.Immediate
	local deferred = optionTable.Deferred

	if immediate ~= nil and type(immediate) ~= "boolean" then
		ErrorHandler.RaiseUsageError("Store.Subscribe: Immediate must be a boolean or nil")
	end

	if deferred ~= nil and type(deferred) ~= "boolean" then
		ErrorHandler.RaiseUsageError("Store.Subscribe: Deferred must be a boolean or nil")
	end

	return if immediate == nil then true else immediate :: boolean, if deferred == nil then false else deferred :: boolean
end

function Validation.GetValidatedRestoreStrictOption(options: unknown): boolean
	if options == nil then
		return false
	end

	if type(options) ~= "table" then
		ErrorHandler.RaiseUsageError("Store.Restore: opts must be a table or nil")
	end

	local strict = (options :: { [string]: unknown }).Strict

	if strict ~= nil and type(strict) ~= "boolean" then
		ErrorHandler.RaiseUsageError("Store.Restore: Strict must be a boolean or nil")
	end

	return if strict == nil then false else strict :: boolean
end

function Validation.EnsurePositiveInteger(value: unknown, usageErrorMessage: string): number
	if type(value) ~= "number" or value < 1 or value ~= math.floor(value) then
		ErrorHandler.RaiseUsageError(usageErrorMessage)
	end

	return value :: number
end

return Validation
