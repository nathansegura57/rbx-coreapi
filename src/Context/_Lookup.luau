--!strict

local LazyProviders = require(script.Parent._LazyProviders)
local Records = require(script.Parent._Records)
local Types = require(script.Parent._Types)
local Views = require(script.Parent._Views)


type BaseContext<Value> = Types.BaseContext<Value>
type ContextPrivateState = Types.ContextPrivateState
type LookupResult = Types.LookupResult


local Lookup = {}


function Lookup.GetRequiredValueFromContextTree(requestingContextHandle: BaseContext<unknown>, key: unknown): unknown
	local requestingContextPrivateState = Records.GetLiveContextPrivateStateOrRaiseUsageError(
		requestingContextHandle,
		"Context.Require: context is destroyed"
	)

	Records.GetLiveSourceContextPrivateStateOrRaiseUsageError(
		requestingContextPrivateState,
		"Context.Require: source context is destroyed"
	)

	if not Views.ContextPrivateStateCanSeeKey(requestingContextPrivateState, key) then
		error(`Context.Require: key '{Records.GetReadableKeyName(key)}' is not visible in this view`, 3)
	end

	local lookupResult = Lookup.FindValueInContextTree(requestingContextHandle, requestingContextHandle, key)

	if lookupResult.WasFound then
		return lookupResult.Value
	end

	error(`Context.Require: missing key '{Records.GetReadableKeyName(key)}'`, 3)
end

function Lookup.GetOptionalValueFromContextTree(requestingContextHandle: BaseContext<unknown>, key: unknown): unknown?
	local requestingContextPrivateState = Records.GetLiveContextPrivateStateOrRaiseUsageError(
		requestingContextHandle,
		"Context.Maybe: context is destroyed"
	)

	Records.GetLiveSourceContextPrivateStateOrRaiseUsageError(
		requestingContextPrivateState,
		"Context.Maybe: source context is destroyed"
	)

	if not Views.ContextPrivateStateCanSeeKey(requestingContextPrivateState, key) then
		return nil
	end

	local lookupResult = Lookup.FindValueInContextTree(requestingContextHandle, requestingContextHandle, key)

	if lookupResult.WasFound then
		return lookupResult.Value
	end

	return nil
end

function Lookup.ContextTreeContainsKeyWithoutResolvingLazyProviders(
	contextHandle: BaseContext<unknown>,
	key: unknown
): boolean
	local contextPrivateState = Records.GetLiveContextPrivateStateOrRaiseUsageError(
		contextHandle,
		"Context.Has: context is destroyed"
	)

	Records.GetLiveSourceContextPrivateStateOrRaiseUsageError(contextPrivateState, "Context.Has: source context is destroyed")

	if not Views.ContextPrivateStateCanSeeKey(contextPrivateState, key) then
		return false
	end

	if contextPrivateState.Kind == "View" then
		local sourceContextHandle = contextPrivateState.SourceContextHandle

		if sourceContextHandle == nil then
			return false
		end

		return Lookup.ContextTreeContainsKeyWithoutResolvingLazyProviders(sourceContextHandle, key)
	end

	if Lookup.ContextPrivateStateDirectlyContainsKeyWithoutResolvingLazyProviders(contextPrivateState, key) then
		return true
	end

	local parentContextHandle = contextPrivateState.ParentContextHandle

	if parentContextHandle ~= nil then
		return Lookup.ContextTreeContainsKeyWithoutResolvingLazyProviders(parentContextHandle, key)
	end

	return false
end

function Lookup.FindValueInContextTree(
	requestingContextHandle: BaseContext<unknown>,
	currentContextHandle: BaseContext<unknown>,
	key: unknown
): LookupResult
	local currentContextPrivateState = Records.GetContextPrivateStateWithoutValidation(currentContextHandle)

	if currentContextPrivateState == nil or currentContextPrivateState.IsDestroyed then
		return Lookup.CreateMissingLookupResult()
	end

	if currentContextPrivateState.Kind == "View" then
		return Lookup.FindValueInViewSource(requestingContextHandle, currentContextPrivateState, key)
	end

	local directLookupResult = Lookup.FindValueInStoredOrLazyEntries(
		requestingContextHandle,
		currentContextPrivateState,
		key
	)

	if directLookupResult.WasFound then
		return directLookupResult
	end

	return Lookup.FindValueInParentContext(requestingContextHandle, currentContextPrivateState, key)
end

function Lookup.FindValueInViewSource(
	requestingContextHandle: BaseContext<unknown>,
	viewPrivateState: ContextPrivateState,
	key: unknown
): LookupResult
	if not Views.ContextPrivateStateCanSeeKey(viewPrivateState, key) then
		return Lookup.CreateMissingLookupResult()
	end

	local sourceContextHandle = viewPrivateState.SourceContextHandle

	if sourceContextHandle == nil then
		return Lookup.CreateMissingLookupResult()
	end

	return Lookup.FindValueInContextTree(requestingContextHandle, sourceContextHandle, key)
end

function Lookup.FindValueInStoredOrLazyEntries(
	requestingContextHandle: BaseContext<unknown>,
	currentContextPrivateState: ContextPrivateState,
	key: unknown
): LookupResult
	local storedValueEntry = currentContextPrivateState.StoredValueByKey[key]

	if storedValueEntry ~= nil then
		return Lookup.CreateFoundLookupResult(storedValueEntry.Value)
	end

	local lazyProviderEntry = currentContextPrivateState.LazyProviderByKey[key]

	if lazyProviderEntry ~= nil then
		return Lookup.CreateFoundLookupResult(LazyProviders.ResolveLazyProviderValue(
			requestingContextHandle,
			currentContextPrivateState,
			key,
			lazyProviderEntry
			))
	end

	return Lookup.CreateMissingLookupResult()
end

function Lookup.FindValueInParentContext(
	requestingContextHandle: BaseContext<unknown>,
	currentContextPrivateState: ContextPrivateState,
	key: unknown
): LookupResult
	local parentContextHandle = currentContextPrivateState.ParentContextHandle

	if parentContextHandle == nil then
		return Lookup.CreateMissingLookupResult()
	end

	return Lookup.FindValueInContextTree(requestingContextHandle, parentContextHandle, key)
end

function Lookup.ContextPrivateStateDirectlyContainsKeyWithoutResolvingLazyProviders(
	contextPrivateState: ContextPrivateState,
	key: unknown
): boolean
	return contextPrivateState.StoredValueByKey[key] ~= nil or contextPrivateState.LazyProviderByKey[key] ~= nil
end

function Lookup.CreateMissingLookupResult(): LookupResult
	return {
		WasFound = false,
		Value = nil,
	}
end

function Lookup.CreateFoundLookupResult(value: unknown): LookupResult
	return {
		WasFound = true,
		Value = value,
	}
end


return table.freeze(Lookup)

