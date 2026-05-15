--!strict

local Store = {}

local Factories = require(script._Factories)
local History = require(script._History)
local InstanceMethods = require(script._InstanceMethods)
local Records = require(script._Records)
local Snapshots = require(script._Snapshots)
local Transactions = require(script._Transactions)
local Types = require(script._Types)

export type ReadableStore<Value> = Types.ReadableStore<Value>
export type WritableStore<Value> = Types.WritableStore<Value>
export type SubscribeOptions = Types.SubscribeOptions
export type ValueOptions<Value> = Types.ValueOptions<Value>
export type DeriveOptions<Value> = Types.DeriveOptions<Value>
export type RestoreOptions = Types.RestoreOptions
export type Snapshot = Types.Snapshot
export type History<Value> = Types.History<Value>

Records.UseInstanceMethods(InstanceMethods)


function Store.Value<Value>(initialValue: Value, options: ValueOptions<Value>?): WritableStore<Value>
	return Factories.Value(initialValue, options)
end

function Store.Const<Value>(value: Value): ReadableStore<Value>
	return Factories.Const(value)
end

function Store.Derive<Value>(
	computeValue: () -> Value,
	dependencies: { ReadableStore<any> },
	options: DeriveOptions<Value>?
): ReadableStore<Value>
	return Factories.Derive(computeValue, dependencies, options)
end

function Store.Select<InputValue, SelectedValue>(
	sourceStore: ReadableStore<InputValue>,
	selectValue: (InputValue) -> SelectedValue,
	valuesAreEqual: ((SelectedValue, SelectedValue) -> boolean)?
): ReadableStore<SelectedValue>
	return Factories.Select(sourceStore, selectValue, valuesAreEqual)
end

function Store.Combine(values: { [any]: ReadableStore<any> }): ReadableStore<{ any }>
	return Factories.Combine(values)
end

function Store.AllTruthy(stores: { ReadableStore<any> }): ReadableStore<boolean>
	return Factories.AllTruthy(stores)
end

function Store.AnyTruthy(stores: { ReadableStore<any> }): ReadableStore<boolean>
	return Factories.AnyTruthy(stores)
end

function Store.Match(sourceStore: ReadableStore<any>, cases: { [any]: ReadableStore<any> }): ReadableStore<any>
	return Factories.Match(sourceStore, cases)
end

function Store.Readonly<Value>(store: ReadableStore<Value>): ReadableStore<Value>
	return Factories.Readonly(store)
end

function Store.IsStore(value: unknown): boolean
	return Records.ValueIsLiveStoreHandle(value)
end

function Store.Batch(block: () -> ()): ()
	Transactions.Batch(block)
end

function Store.Transaction(block: () -> ()): ()
	Transactions.Transaction(block)
end

function Store.Snapshot(...: ReadableStore<any>): Snapshot
	return Snapshots.Snapshot(...)
end

function Store.Restore(snapshot: Snapshot, options: RestoreOptions?): ()
	Snapshots.Restore(snapshot, options)
end

function Store.History<Value>(store: WritableStore<Value>, limit: number?): History<Value>
	return History.Create(store, limit)
end


return table.freeze(Store)

