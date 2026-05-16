--!strict

local ErrorHandler = require(script.Parent.Parent.ErrorHandler)
local Types = require(script.Parent._Types)


type BaseContext<Value> = Types.BaseContext<Value>
type Context<Value> = Types.Context<Value>
type ContextKind = Types.ContextKind
type ContextKey<Value> = Types.ContextKey<Value>
type ContextValues = Types.ContextValues
type ContextPrivateState = Types.ContextPrivateState
type ContextKeyPrivateState = Types.ContextKeyPrivateState
type ContextStorageEntry = Types.ContextStorageEntry
type LazyProviderEntry = Types.LazyProviderEntry
type LazyValueProvider<Value> = Types.LazyValueProvider<Value>
type DestroyCallback = Types.DestroyCallback


type ContextHandleMetatable = {
	__index: (contextHandle: BaseContext<unknown>, key: string) -> unknown,
	__newindex: (contextHandle: BaseContext<unknown>, key: string, value: unknown) -> never,
	__metatable: string,
}

type ContextKeyMetatable = {
	__newindex: (contextKey: ContextKey<unknown>, key: string, value: unknown) -> never,
	__metatable: string,
}

local ContextHandleMetatable: ContextHandleMetatable
local ContextKeyMetatable: ContextKeyMetatable


local Records = {}

local contextHandleMethods: { [string]: unknown } = {}

local contextPrivateStateByHandle: { [BaseContext<unknown>]: ContextPrivateState } = setmetatable({}, {
	__mode = "k",
}) :: any

local contextKeyPrivateStateByHandle: { [ContextKey<unknown>]: ContextKeyPrivateState } = setmetatable({}, {
	__mode = "k",
}) :: any


function Records.SetContextHandleMethods(methods: { [string]: unknown }): ()
	contextHandleMethods = methods
end


function Records.CreateRootContextHandle<Values>(validatedValues: ContextValues): Context<Values>
	local contextHandle = Records.CreateContextHandle() :: Context<Values>

	contextPrivateStateByHandle[contextHandle] = Records.CreateRootContextPrivateState(validatedValues)

	return contextHandle
end

function Records.CreateLayerContextHandle<LayerValues>(
	parentContextHandle: BaseContext<unknown>,
	validatedValues: ContextValues,
	cleanupCallback: DestroyCallback?
): BaseContext<LayerValues>
	local childContextHandle = Records.CreateContextHandle() :: BaseContext<LayerValues>

	contextPrivateStateByHandle[childContextHandle] = Records.CreateLayerContextPrivateState(
		parentContextHandle,
		validatedValues,
		cleanupCallback
	)

	Records.AppendChildContextToParent(parentContextHandle, childContextHandle)

	return childContextHandle
end

function Records.CreateViewContextHandle(
	sourceContextHandle: BaseContext<unknown>,
	visibleKeySet: { [any]: true }?
): BaseContext<unknown>
	local viewContextHandle = Records.CreateContextHandle()

	contextPrivateStateByHandle[viewContextHandle] = Records.CreateViewContextPrivateState(
		sourceContextHandle,
		visibleKeySet
	)

	Records.AppendChildContextToParent(sourceContextHandle, viewContextHandle)

	return viewContextHandle
end

function Records.CreateContextHandle(): BaseContext<unknown>
	return setmetatable({}, ContextHandleMetatable) :: any
end

function Records.CreateContextKeyHandle<Value>(name: string): ContextKey<Value>
	local contextKeyHandle: ContextKey<Value> = setmetatable({}, ContextKeyMetatable) :: any

	contextKeyPrivateStateByHandle[contextKeyHandle :: any] = {
		Name = name,
	}

	return contextKeyHandle
end


function Records.CreateRootContextPrivateState(validatedValues: ContextValues): ContextPrivateState
	local contextPrivateState = Records.CreateEmptyContextPrivateState("Root")

	Records.StoreValidatedValuesIntoContextPrivateState(contextPrivateState, validatedValues)

	return contextPrivateState
end

function Records.CreateLayerContextPrivateState(
	parentContextHandle: BaseContext<unknown>,
	validatedValues: ContextValues,
	cleanupCallback: DestroyCallback?
): ContextPrivateState
	local contextPrivateState = Records.CreateEmptyContextPrivateState("Layer")

	contextPrivateState.ParentContextHandle = parentContextHandle
	contextPrivateState.CleanupCallback = cleanupCallback

	Records.StoreValidatedValuesIntoContextPrivateState(contextPrivateState, validatedValues)

	return contextPrivateState
end

function Records.CreateViewContextPrivateState(
	sourceContextHandle: BaseContext<unknown>,
	visibleKeySet: { [any]: true }?
): ContextPrivateState
	local contextPrivateState = Records.CreateEmptyContextPrivateState("View")

	contextPrivateState.SourceContextHandle = sourceContextHandle
	contextPrivateState.VisibleKeySet = visibleKeySet
	contextPrivateState.IsMutable = false

	return contextPrivateState
end

function Records.CreateEmptyContextPrivateState(kind: ContextKind): ContextPrivateState
	return {
		Kind = kind,
		ParentContextHandle = nil,
		SourceContextHandle = nil,
		VisibleKeySet = nil,
		IsMutable = true,
		IsDestroyed = false,

		StoredValueByKey = {},
		LazyProviderByKey = {},
		ChildContextHandles = {},

		CleanupCallback = nil,
		DestroyCallbackEntries = {},
	}
end

function Records.CreateStoredValueEntry(value: unknown): ContextStorageEntry
	return {
		Value = value,
	}
end

function Records.CreateLazyProviderEntry(provider: LazyValueProvider<unknown>): LazyProviderEntry
	return {
		Provider = provider,
		IsCurrentlyResolving = false,
	}
end


function Records.StoreValidatedValuesIntoContextPrivateState(
	contextPrivateState: ContextPrivateState,
	validatedValues: ContextValues
): ()
	for key, value in validatedValues do
		Records.StoreValueInContextPrivateState(contextPrivateState, key, value)
	end
end

function Records.StoreValueInContextPrivateState(
	contextPrivateState: ContextPrivateState,
	key: unknown,
	value: unknown
): ()
	contextPrivateState.StoredValueByKey[key] = Records.CreateStoredValueEntry(value)
	contextPrivateState.LazyProviderByKey[key] = nil
end

function Records.StoreLazyProviderInContextPrivateState(
	contextPrivateState: ContextPrivateState,
	key: unknown,
	provider: LazyValueProvider<unknown>
): ()
	contextPrivateState.LazyProviderByKey[key] = Records.CreateLazyProviderEntry(provider)
	contextPrivateState.StoredValueByKey[key] = nil
end


function Records.ValueIsContextHandle(value: unknown): boolean
	return Records.GetContextPrivateStateIfValueIsContextHandle(value) ~= nil
end

function Records.ValueIsContextKeyHandle(value: unknown): boolean
	if typeof(value) ~= "table" then
		return false
	end

	return contextKeyPrivateStateByHandle[value :: any] ~= nil
end

function Records.GetContextPrivateStateIfValueIsContextHandle(value: unknown): ContextPrivateState?
	if typeof(value) ~= "table" then
		return nil
	end

	return contextPrivateStateByHandle[value :: any]
end

function Records.GetContextPrivateStateOrRaiseUsageError(
	contextHandle: BaseContext<unknown>,
	usageErrorMessage: string
): ContextPrivateState
	local contextPrivateState = contextPrivateStateByHandle[contextHandle]

	if contextPrivateState ~= nil then
		return contextPrivateState
	end

	return ErrorHandler.RaiseUsageError(usageErrorMessage)
end

function Records.GetLiveContextPrivateStateOrRaiseUsageError(
	contextHandle: BaseContext<unknown>,
	usageErrorMessage: string
): ContextPrivateState
	local contextPrivateState = Records.GetContextPrivateStateOrRaiseUsageError(contextHandle, usageErrorMessage)

	if not contextPrivateState.IsDestroyed then
		return contextPrivateState
	end

	return ErrorHandler.RaiseUsageError(usageErrorMessage)
end

function Records.GetLiveSourceContextPrivateStateOrRaiseUsageError(
	contextPrivateState: ContextPrivateState,
	usageErrorMessage: string
): ContextPrivateState?
	local sourceContextHandle = contextPrivateState.SourceContextHandle

	if sourceContextHandle == nil then
		return nil
	end

	return Records.GetLiveContextPrivateStateOrRaiseUsageError(sourceContextHandle, usageErrorMessage)
end

function Records.GetContextPrivateStateWithoutValidation(
	contextHandle: BaseContext<unknown>
): ContextPrivateState?
	return contextPrivateStateByHandle[contextHandle]
end

function Records.ContextPrivateStateCanSeeKey(contextPrivateState: ContextPrivateState, key: unknown): boolean
	local visibleKeySet = contextPrivateState.VisibleKeySet
	return visibleKeySet == nil or visibleKeySet[key] == true
end


function Records.AppendChildContextToParent(
	parentContextHandle: BaseContext<unknown>,
	childContextHandle: BaseContext<unknown>
): ()
	local parentContextPrivateState = contextPrivateStateByHandle[parentContextHandle]

	if parentContextPrivateState ~= nil and not parentContextPrivateState.IsDestroyed then
		table.insert(parentContextPrivateState.ChildContextHandles, childContextHandle)
	end
end

function Records.GetReadableKeyName(key: unknown): string
	if typeof(key) == "string" then
		return key
	end

	local contextKeyPrivateState = contextKeyPrivateStateByHandle[key :: any]

	if contextKeyPrivateState ~= nil then
		return contextKeyPrivateState.Name
	end

	return "<unknown>"
end


function Records.GetContextHandlePublicProperty(_contextHandle: BaseContext<unknown>, key: string): unknown
	return contextHandleMethods[key]
end

function Records.RejectContextHandlePublicMutation(
	_contextHandle: BaseContext<unknown>,
	key: string,
	_value: unknown
): never
	ErrorHandler.RaiseUsageError(`Context: '{tostring(key)}' is read-only`)
end

function Records.RejectContextKeyPublicMutation(_contextKey: ContextKey<unknown>, key: string, _value: unknown): never
	ErrorHandler.RaiseUsageError(`ContextKey: '{tostring(key)}' is read-only`)
end


ContextHandleMetatable = table.freeze({
	__index = Records.GetContextHandlePublicProperty,
	__newindex = Records.RejectContextHandlePublicMutation,
	__metatable = "Context",
})

ContextKeyMetatable = table.freeze({
	__newindex = Records.RejectContextKeyPublicMutation,
	__metatable = "ContextKey",
})


return table.freeze(Records)

