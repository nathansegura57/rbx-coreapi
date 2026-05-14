--!strict

local Connection = require(script.Parent.Parent.Connection)


export type ContextKey<Value> = {}

export type ContextValues = {
	[any]: unknown,
}

export type LazyValueProvider<Value> = (context: BaseContext<unknown>) -> Value
export type DestroyCallback = () -> ()

export type BaseContext<Value> = {
	Require: <ResolvedValue>(self: BaseContext<Value>, key: ContextKey<ResolvedValue> | string) -> ResolvedValue,
	Maybe: <ResolvedValue>(self: BaseContext<Value>, key: ContextKey<ResolvedValue> | string) -> ResolvedValue?,
	Has: (self: BaseContext<Value>, key: ContextKey<unknown> | string) -> boolean,

	Set: <StoredValue>(self: BaseContext<Value>, key: ContextKey<StoredValue> | string, value: StoredValue) -> (),
	Provide: (self: BaseContext<Value>, values: ContextValues) -> (),

	Readonly: (self: BaseContext<Value>) -> BaseContext<Value>,

	Destroy: (self: BaseContext<Value>) -> (),
	IsDestroyed: (self: BaseContext<Value>) -> boolean,
	OnDestroy: (self: BaseContext<Value>, callback: DestroyCallback) -> Connection.Connection,
}

export type Context<Value> = BaseContext<Value> & {
	ProvideLazy: <ResolvedValue>(
		self: Context<Value>,
		key: ContextKey<ResolvedValue> | string,
		provider: LazyValueProvider<ResolvedValue>
	) -> (),

	Layer: <LayerValues>(
		self: Context<Value>,
		values: LayerValues,
		cleanupCallback: DestroyCallback?
	) -> BaseContext<LayerValues>,

	View: (
		self: Context<Value>,
		keys: { ContextKey<unknown> | string }
	) -> BaseContext<unknown>,
}

export type ContextModule = {
	Root: <Values>(values: Values) -> Context<Values>,
	Key: <Value>(name: string) -> ContextKey<Value>,
	IsContext: (value: unknown) -> boolean,
}

export type ContextKind = "Root" | "Layer" | "View"

export type ContextStorageEntry = {
	Value: unknown,
}

export type LazyProviderEntry = {
	Provider: LazyValueProvider<unknown>,
	IsCurrentlyResolving: boolean,
}

export type DestroyCallbackEntry = {
	Callback: DestroyCallback,
}

export type ContextPrivateState = {
	Kind: ContextKind,
	ParentContextHandle: BaseContext<unknown>?,
	SourceContextHandle: BaseContext<unknown>?,
	VisibleKeySet: { [any]: true }?,
	IsMutable: boolean,
	IsDestroyed: boolean,

	StoredValueByKey: { [any]: ContextStorageEntry },
	LazyProviderByKey: { [any]: LazyProviderEntry },
	ChildContextHandles: { BaseContext<unknown> },

	CleanupCallback: DestroyCallback?,
	DestroyCallbackEntries: { DestroyCallbackEntry },
}

export type ContextKeyPrivateState = {
	Name: string,
}

export type LookupResult = {
	WasFound: boolean,
	Value: unknown,
}

return table.freeze({})

