--!strict

local Connection = require(script.Parent.Connection)

local Destruction = require(script._Destruction)
local Keys = require(script._Keys)
local Lookup = require(script._Lookup)
local Records = require(script._Records)
local Types = require(script._Types)
local Validation = require(script._Validation)
local Views = require(script._Views)


export type ContextKey<Value> = Types.ContextKey<Value>
export type ContextValues = Types.ContextValues
export type LazyValueProvider<Value> = Types.LazyValueProvider<Value>
export type DestroyCallback = Types.DestroyCallback
export type BaseContext<Value> = Types.BaseContext<Value>
export type Context<Value> = Types.Context<Value>
export type ContextModule = Types.ContextModule


type ContextPrivateState = Types.ContextPrivateState


local Context = {} :: ContextModule
local ContextHandleMethods: { [string]: unknown } = {}


function Context.Root<Values>(values: Values): Context<Values>
	local validatedValues = Validation.GetValidatedRootValues(values)

	return Records.CreateRootContextHandle(validatedValues)
end

function Context.Key<Value>(name: string): ContextKey<Value>
	return Keys.CreateContextKey(name)
end

function Context.IsContext(value: unknown): boolean
	return Records.ValueIsContextHandle(value)
end


function ContextHandleMethods.Require<ResolvedValue>(
	contextHandle: BaseContext<unknown>,
	key: ContextKey<ResolvedValue> | string
): ResolvedValue
	local validatedKey = Validation.GetValidatedLookupKey(key, "Context.Require")
	local resolvedValue = Lookup.GetRequiredValueFromContextTree(contextHandle, validatedKey)

	return resolvedValue :: ResolvedValue
end

function ContextHandleMethods.Maybe<ResolvedValue>(
	contextHandle: BaseContext<unknown>,
	key: ContextKey<ResolvedValue> | string
): ResolvedValue?
	local validatedKey = Validation.GetValidatedLookupKeyOrNil(key)

	if validatedKey == nil then
		Records.GetLiveContextPrivateStateOrRaiseUsageError(contextHandle, "Context.Maybe: context is destroyed")
		return nil
	end

	return Lookup.GetOptionalValueFromContextTree(contextHandle, validatedKey) :: ResolvedValue?
end

function ContextHandleMethods.Has(
	contextHandle: BaseContext<unknown>,
	key: ContextKey<unknown> | string
): boolean
	local validatedKey = Validation.GetValidatedLookupKeyOrNil(key)

	if validatedKey == nil then
		Records.GetLiveContextPrivateStateOrRaiseUsageError(contextHandle, "Context.Has: context is destroyed")
		return false
	end

	Records.GetLiveContextPrivateStateOrRaiseUsageError(contextHandle, "Context.Has: context is destroyed")

	return Lookup.ContextTreeContainsKeyWithoutResolvingLazyProviders(contextHandle, validatedKey)
end


function ContextHandleMethods.Set<StoredValue>(
	contextHandle: BaseContext<unknown>,
	key: ContextKey<StoredValue> | string,
	value: StoredValue
): ()
	local contextPrivateState = Records.GetLiveContextPrivateStateOrRaiseUsageError(
		contextHandle,
		"Context.Set: context is destroyed"
	)

	if not contextPrivateState.IsMutable then
		error("Context.Set: context is read-only", 2)
	end

	local validatedKey = Validation.GetValidatedLookupKey(key, "Context.Set")

	Records.StoreValueInContextPrivateState(contextPrivateState, validatedKey, value)
end

function ContextHandleMethods.Provide(contextHandle: BaseContext<unknown>, values: ContextValues): ()
	local contextPrivateState = Records.GetLiveContextPrivateStateOrRaiseUsageError(
		contextHandle,
		"Context.Provide: context is destroyed"
	)

	if not contextPrivateState.IsMutable then
		error("Context.Provide: context is read-only", 2)
	end

	local validatedValues = Validation.GetValidatedProvidedValues(values, "Context.Provide")

	Records.StoreValidatedValuesIntoContextPrivateState(contextPrivateState, validatedValues)
end

function ContextHandleMethods.ProvideLazy<ResolvedValue>(
	contextHandle: Context<unknown>,
	key: ContextKey<ResolvedValue> | string,
	provider: LazyValueProvider<ResolvedValue>
): ()
	local contextPrivateState = Records.GetLiveContextPrivateStateOrRaiseUsageError(
		contextHandle,
		"Context.ProvideLazy: context is destroyed"
	)

	if not contextPrivateState.IsMutable then
		error("Context.ProvideLazy: context is read-only", 2)
	end

	local validatedKey = Validation.GetValidatedLookupKey(key, "Context.ProvideLazy")

	if typeof(provider) ~= "function" then
		error("Context.ProvideLazy: provider must be a function", 2)
	end

	Records.StoreLazyProviderInContextPrivateState(contextPrivateState, validatedKey, provider :: LazyValueProvider<unknown>)
end


function ContextHandleMethods.Layer<LayerValues>(
	contextHandle: Context<unknown>,
	values: LayerValues,
	cleanupCallback: DestroyCallback?
): BaseContext<LayerValues>
	Records.GetLiveContextPrivateStateOrRaiseUsageError(contextHandle, "Context.Layer: context is destroyed")

	local validatedValues = Validation.GetValidatedProvidedValues(values, "Context.Layer")
	local validatedCleanupCallback = Validation.GetValidatedOptionalDestroyCallback(
		cleanupCallback,
		"Context.Layer: cleanupCallback must be a function or nil"
	)

	return Records.CreateLayerContextHandle(contextHandle, validatedValues, validatedCleanupCallback)
end

function ContextHandleMethods.View(
	contextHandle: Context<unknown>,
	keys: { ContextKey<unknown> | string }
): BaseContext<unknown>
	Records.GetLiveContextPrivateStateOrRaiseUsageError(contextHandle, "Context.View: context is destroyed")

	local validatedKeyList = Validation.GetValidatedVisibleKeyList(keys)
	local visibleKeySet = Views.GetVisibleKeySetFromValidatedKeyList(validatedKeyList)

	return Records.CreateViewContextHandle(contextHandle, visibleKeySet)
end

function ContextHandleMethods.Readonly(contextHandle: BaseContext<unknown>): BaseContext<unknown>
	local contextPrivateState = Records.GetLiveContextPrivateStateOrRaiseUsageError(
		contextHandle,
		"Context.Readonly: context is destroyed"
	)

	return Records.CreateViewContextHandle(contextHandle, contextPrivateState.VisibleKeySet)
end


function ContextHandleMethods.Destroy(contextHandle: BaseContext<unknown>): ()
	Destruction.DestroyContextHandleIfStillAlive(contextHandle)
end

function ContextHandleMethods.IsDestroyed(contextHandle: BaseContext<unknown>): boolean
	local contextPrivateState = Records.GetContextPrivateStateIfValueIsContextHandle(contextHandle)

	return contextPrivateState == nil or contextPrivateState.IsDestroyed
end

function ContextHandleMethods.OnDestroy(
	contextHandle: BaseContext<unknown>,
	callback: DestroyCallback
): Connection.Connection
	local validatedCallback = Validation.GetValidatedDestroyCallback(
		callback,
		"Context.OnDestroy: callback must be a function"
	)

	local contextPrivateState = Records.GetContextPrivateStateIfValueIsContextHandle(contextHandle)

	if contextPrivateState == nil or contextPrivateState.IsDestroyed then
		return Destruction.ScheduleDestroyCallbackBecauseContextIsAlreadyDestroyed(validatedCallback)
	end

	return Destruction.RegisterDestroyCallback(contextPrivateState, validatedCallback)
end


Records.SetContextHandleMethods(ContextHandleMethods)

return table.freeze(Context)

