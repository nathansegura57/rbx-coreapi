--!strict

local Types = {}

local Connection = require(script.Parent.Parent.Connection)
local Signal = require(script.Parent.Parent.Signal)

export type SubscribeOptions = {
	Immediate: boolean?,
	Deferred: boolean?,
}

export type ValueOptions<Value> = {
	Name: string?,
	Equals: ((Value, Value) -> boolean)?,
	ReplaceName: boolean?,
}

export type DeriveOptions<Value> = ValueOptions<Value>

export type RestoreOptions = {
	Strict: boolean?,
}

export type Snapshot = { [any]: any }

export type StoreKind = "value" | "const" | "derived" | "readonly"

export type SubscriberRecord = {
	Connected: boolean,
	Listener: (any, any?) -> (),
}

export type WaiterRecord = {
	Thread: thread,
}

export type StoreRecord = {
	Destroyed: boolean,
	Kind: StoreKind,
	Value: any,
	Dirty: boolean,
	DirtyOldValue: any,
	Subscribers: { SubscriberRecord },
	Waiters: { WaiterRecord },
	ChangedSignal: Signal.Signal<{ New: any, Old: any }>?,
	Name: string?,
	Equals: ((any, any) -> boolean)?,
	Compute: (() -> any)?,
	Dependencies: { any },
	DerivedConsumers: { any },
}

export type BaseReadableStore<Value> = {
	Get: (self: BaseReadableStore<Value>) -> Value,
	Subscribe: (
		self: BaseReadableStore<Value>,
		listener: (Value, Value?) -> (),
		options: SubscribeOptions?
	) -> Connection.Connection,
	Changed: (self: BaseReadableStore<Value>) -> Signal.Signal<{ New: Value, Old: Value }>,
	Equals: (self: BaseReadableStore<Value>, equals: (Value, Value) -> boolean) -> BaseReadableStore<Value>,
	Name: (self: BaseReadableStore<Value>) -> string?,
	Deps: (self: BaseReadableStore<Value>) -> { any },
	Wait: (self: BaseReadableStore<Value>) -> (Value, Value),
	DisconnectAll: (self: BaseReadableStore<Value>) -> (),
	IsDestroyed: (self: BaseReadableStore<Value>) -> boolean,
	Destroy: (self: BaseReadableStore<Value>) -> (),
}

export type ReadableStore<Value> = BaseReadableStore<Value> & {
	Map: <SelectedValue>(
		self: ReadableStore<Value>,
		picker: (Value) -> SelectedValue,
		equals: ((SelectedValue, SelectedValue) -> boolean)?
	) -> BaseReadableStore<SelectedValue>,
}

export type WritableStore<Value> = ReadableStore<Value> & {
	Set: (self: WritableStore<Value>, value: Value) -> (),
	Update: (self: WritableStore<Value>, updater: (Value) -> Value) -> (),
}

export type History<Value> = {
	CanUndo: ReadableStore<boolean>,
	CanRedo: ReadableStore<boolean>,
	Undo: () -> boolean,
	Redo: () -> boolean,
	Clear: () -> (),
	Destroy: () -> (),
}

return table.freeze(Types)

