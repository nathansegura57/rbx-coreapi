--!strict

local ErrorHandler = require(script.Parent.Parent.ErrorHandler)
local Records = require(script.Parent._Records)
local Types = require(script.Parent._Types)


type BaseContext<Value> = Types.BaseContext<Value>
type ContextPrivateState = Types.ContextPrivateState
type LazyProviderEntry = Types.LazyProviderEntry
type LazyValueProvider<Value> = Types.LazyValueProvider<Value>


local LazyProviders = {}


function LazyProviders.ResolveLazyProviderValue(
	requestingContextHandle: BaseContext<unknown>,
	currentContextPrivateState: ContextPrivateState,
	key: unknown,
	lazyProviderEntry: LazyProviderEntry
): unknown
	if lazyProviderEntry.IsCurrentlyResolving then
		error(`Context.Require: lazy provider cycle for key '{Records.GetReadableKeyName(key)}'`, 3)
	end

	lazyProviderEntry.IsCurrentlyResolving = true

	local resolvedValue = LazyProviders.RunLazyProviderThroughErrorHandler(
		requestingContextHandle,
		key,
		lazyProviderEntry.Provider
	)

	lazyProviderEntry.IsCurrentlyResolving = false

	currentContextPrivateState.StoredValueByKey[key] = Records.CreateStoredValueEntry(resolvedValue)
	currentContextPrivateState.LazyProviderByKey[key] = nil

	return resolvedValue
end

function LazyProviders.RunLazyProviderThroughErrorHandler(
	requestingContextHandle: BaseContext<unknown>,
	key: unknown,
	lazyProvider: LazyValueProvider<unknown>
): unknown
	local providerSucceeded, resolvedValue = ErrorHandler.Protect(function()
		return lazyProvider(requestingContextHandle)
	end, "Context", "LazyProvider", Records.GetReadableKeyName(key))

	if providerSucceeded then
		return resolvedValue
	end

	error(`Context.Require: lazy provider failed for key '{Records.GetReadableKeyName(key)}'`, 3)
end


return table.freeze(LazyProviders)

