--!strict

local Connection = require(script.Parent.Connection)
local ErrorHandler = require(script.Parent.ErrorHandler)

local Destruction = require(script._Destruction)
local Lookup = require(script._Lookup)
local Records = require(script._Records)
local Types = require(script._Types)
local Validation = require(script._Validation)


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


local function createVisibleKeySetFromValidatedKeyList(validatedKeyList: { unknown }): { [any]: true }
	local visibleKeySet = {}
	for _, key in validatedKeyList do
		visibleKeySet[key] = true
	end
	return visibleKeySet :: any
end


function Context.Root<Values>(values: Values): Context<Values>
	local validatedValues = Validation.GetValidatedRootValues(values)

	return Records.CreateRootContextHandle(validatedValues)
end

function Context.Key<Value>(name: string): ContextKey<Value>
	local validatedName = Validation.GetValidatedKeyName(name)
	return Records.CreateContextKeyHandle(validatedName)
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
		ErrorHandler.RaiseUsageError("Context.Set: context is read-only")
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
		ErrorHandler.RaiseUsageError("Context.Provide: context is read-only")
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
		ErrorHandler.RaiseUsageError("Context.ProvideLazy: context is read-only")
	end

	local validatedKey = Validation.GetValidatedLookupKey(key, "Context.ProvideLazy")

	if typeof(provider) ~= "function" then
		ErrorHandler.RaiseUsageError("Context.ProvideLazy: provider must be a function")
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
	local visibleKeySet = createVisibleKeySetFromValidatedKeyList(validatedKeyList)

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

