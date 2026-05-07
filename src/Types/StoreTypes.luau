--!strict

local ConnectionModule = require(script.Parent.Parent.Internal.Connection)
local SignalTypes       = require(script.Parent.SignalTypes)

export type Connection = ConnectionModule.Connection

-- StoreCore<Value>: non-transform methods shared by all store types.
type StoreCore<Value> = {
	get:       (self: StoreCore<Value>) -> Value,
	subscribe: (self: StoreCore<Value>, listener: (newValue: Value, oldValue: Value?) -> ()) -> Connection,
	name:      (self: StoreCore<Value>) -> string?,
	
	changed: (self: StoreCore<Value>) -> SignalTypes.Signal<{ new: Value, old: Value? }>,
	equals: (self: StoreCore<Value>, equality: (Value, Value) -> boolean) -> StoreCore<Value>,
	
	destroy: (self: StoreCore<Value>) -> (),
}

-- ReadableStore<Value>: full read-only store type including transform methods.
-- Returned by store.value(), store.const(), store.derive(), and most combinators.
export type ReadableStore<Value> = StoreCore<Value> & {
	map:     <Mapped>(self: ReadableStore<Value>, picker: (Value) -> Mapped, equality: ((Mapped, Mapped) -> boolean)?) -> StoreCore<Mapped>,
	deps:  (self: ReadableStore<Value>) -> { StoreCore<any> },
}

-- WritableStore<Value>: extends ReadableStore with mutation methods.
-- Returned by store.value().
export type WritableStore<Value> = ReadableStore<Value> & {
	set:    (self: WritableStore<Value>, newValue: Value) -> (),
	update: (self: WritableStore<Value>, updater: (currentValue: Value) -> Value) -> (),
}

-- DerivedStore<Value>: semantically distinct alias for ReadableStore.
-- Returned by store.derive(), store.select(), and combinators.
-- Structurally identical to ReadableStore; the distinction is semantic only.
export type DerivedStore<Value> = ReadableStore<Value>

return nil

