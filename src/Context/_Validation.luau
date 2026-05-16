--!strict

local ErrorHandler = require(script.Parent.Parent.ErrorHandler)
local Records = require(script.Parent._Records)
local Types = require(script.Parent._Types)


type ContextValues = Types.ContextValues
type DestroyCallback = Types.DestroyCallback


local Validation = {}


function Validation.ValueIsNonEmptyString(value: unknown): boolean
	return typeof(value) == "string" and #(value :: string) > 0
end

function Validation.ValueIsValidContextLookupKey(value: unknown): boolean
	return Validation.ValueIsNonEmptyString(value) or Records.ValueIsContextKeyHandle(value)
end

function Validation.ValueIsSequentialArray(value: unknown): boolean
	if typeof(value) ~= "table" then
		return false
	end

	local array = value :: { [any]: unknown }
	local itemCount = 0

	for key in array do
		if typeof(key) ~= "number" then
			return false
		end

		if key % 1 ~= 0 or key < 1 then
			return false
		end

		itemCount += 1
	end

	for index = 1, itemCount do
		if array[index] == nil then
			return false
		end
	end

	return true
end


function Validation.GetValidatedRootValues(untrustedValues: unknown): ContextValues
	if typeof(untrustedValues) ~= "table" then
		return ErrorHandler.RaiseUsageError("Context.Root: values must be a table")
	end

	local values = untrustedValues :: ContextValues

	for key in values do
		if not Validation.ValueIsValidContextLookupKey(key) then
			return ErrorHandler.RaiseUsageError("Context.Root: key must be a ContextKey or non-empty string")
		end
	end

	return values
end

function Validation.GetValidatedProvidedValues(untrustedValues: unknown, usageErrorPrefix: string): ContextValues
	if typeof(untrustedValues) ~= "table" then
		return ErrorHandler.RaiseUsageError(`{usageErrorPrefix}: values must be a table`)
	end

	local values = untrustedValues :: ContextValues

	for key in values do
		if not Validation.ValueIsValidContextLookupKey(key) then
			return ErrorHandler.RaiseUsageError(`{usageErrorPrefix}: key must be a ContextKey or non-empty string`)
		end
	end

	return values
end

function Validation.GetValidatedLookupKey(untrustedKey: unknown, usageErrorPrefix: string): unknown
	if Validation.ValueIsValidContextLookupKey(untrustedKey) then
		return untrustedKey
	end

	return ErrorHandler.RaiseUsageError(`{usageErrorPrefix}: key must be a ContextKey or non-empty string`)
end

function Validation.GetValidatedLookupKeyOrNil(untrustedKey: unknown): unknown?
	if Validation.ValueIsValidContextLookupKey(untrustedKey) then
		return untrustedKey
	end

	return nil
end

function Validation.GetValidatedKeyName(untrustedName: unknown): string
	if Validation.ValueIsNonEmptyString(untrustedName) then
		return untrustedName :: string
	end

	return ErrorHandler.RaiseUsageError("Context.Key: name must be a non-empty string")
end

function Validation.GetValidatedDestroyCallback(untrustedCallback: unknown, usageErrorMessage: string): DestroyCallback
	if typeof(untrustedCallback) == "function" then
		return untrustedCallback :: DestroyCallback
	end

	return ErrorHandler.RaiseUsageError(usageErrorMessage)
end

function Validation.GetValidatedOptionalDestroyCallback(
	untrustedCallback: unknown?,
	usageErrorMessage: string
): DestroyCallback?
	if untrustedCallback == nil then
		return nil
	end

	return Validation.GetValidatedDestroyCallback(untrustedCallback, usageErrorMessage)
end

function Validation.GetValidatedVisibleKeyList(untrustedKeys: unknown): { unknown }
	if not Validation.ValueIsSequentialArray(untrustedKeys) then
		return ErrorHandler.RaiseUsageError("Context.View: keys must be an array")
	end

	local keys = untrustedKeys :: { unknown }

	for _, key in keys do
		if not Validation.ValueIsValidContextLookupKey(key) then
			return ErrorHandler.RaiseUsageError("Context.View: key must be a ContextKey or non-empty string")
		end
	end

	return keys
end


return table.freeze(Validation)
