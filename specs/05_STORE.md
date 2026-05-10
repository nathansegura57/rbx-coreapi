# 05 — Store

Store is reactive state.

## Public API

```luau
Store.Value(initial: T, opts?): WritableStore<T>
Store.Const(value: T): ReadableStore<T>
Store.Derive(compute: () -> T, deps: { ReadableStore<any> }, opts?): ReadableStore<T>
Store.Select(source: ReadableStore<S>, picker: (S) -> T, equals?): ReadableStore<T>
Store.Combine(values): ReadableStore<any>
Store.AllTruthy(stores: { ReadableStore<any> }): ReadableStore<boolean>
Store.AnyTruthy(stores: { ReadableStore<any> }): ReadableStore<boolean>
Store.Match(source, cases): ReadableStore<any>
Store.Readonly(store: WritableStore<T>): ReadableStore<T>
Store.IsStore(value: unknown): boolean
Store.Batch(block: () -> ()): ()
Store.Transaction(block: () -> ()): ()
Store.Snapshot(...stores): Snapshot
Store.Restore(snapshot, opts?): ()
Store.History(store, limit?): History<T>
```

Readable methods:

```luau
store:Get(): T
store:Peek(): T
store:Subscribe(listener, opts?): Connection
store:Changed(): Signal<{ New: T, Old: T }>
store:Map(picker: (T) -> U, equals?): ReadableStore<U>
store:Equals(equals): ReadableStore<T>
store:Name(): string?
store:Deps(): { ReadableStore<any> }
store:Wait(): (T, T?)
store:DisconnectAll(): ()
store:IsDestroyed(): boolean
store:Destroy(): ()
```

Writable methods:

```luau
store:Set(value: T): ()
store:Update(updater: (T) -> T): ()
```

## Core semantics

- `Set` updates value immediately.
- Derived stores recompute immediately during cascades.
- Subscriber notifications are scheduled through Scheduler unless inside Batch.
- Multiple writes before flush coalesce.
- Listener errors route through ErrorHandler.
- Destroy is idempotent.
- Destroying source destroys derived consumers recursively.
- Readonly stores/views do not expose Set or Update.

## Options

Value/Derive options:

```luau
{
    Name: string?,
    Equals: ((oldValue: T, newValue: T) -> boolean)?,
}
```

Default equality is `==`.

## `Value`

Creates writable store.

Behavior:

- stores initial value
- optional name registers store for snapshot/restore
- duplicate names error unless `ReplaceName = true` is explicitly supported; preferred: error

Duplicate error:

```text
Store.Value: duplicate store name '<name>'
```

## `Const`

Creates read-only constant store.

- Get returns value.
- Subscribe delivers initial value but never future changes.
- Destroy works.
- Set/Update not available on type and must error if accessed dynamically.

## `Derive`

Requires compute function and non-empty deps array.

Initial compute:

- runs immediately
- if it errors, construction errors

Later recompute:

- runs when any dep changes
- if compute errors, route through ErrorHandler
- keep previous value if policy does not throw
- if new value equals old value, do not notify

Destroy behavior:

- source dep destroyed destroys derived
- derived destroyed unlinks from deps

## `Select`

Derived from one source:

```luau
Store.Derive(function()
    return picker(source:Get())
end, { source }, { Equals = equals })
```

## `Combine`

Combines stores into the same shape.

If input is array:

```luau
Store.Combine({ A, B }) -> { AValue, BValue }
```

If input is object:

```luau
Store.Combine({
    Health = HealthStore,
    Name = NameStore,
}) -> {
    Health = health,
    Name = name,
}
```

Every value in input must be a store.

## `AllTruthy`

Returns true when every store value is truthy.

Requires non-empty array.

## `AnyTruthy`

Returns true when any store value is truthy.

Requires non-empty array.

## `Match`

Selects a case based on source value.

```luau
Store.Match(source, {
    Idle = IdleStore,
    Combat = CombatStore,
    _ = DefaultStore,
})
```

Behavior:

- source value is key
- if matching case exists, return that store's value
- otherwise use `_`
- if no case and no `_`, error through ErrorHandler during recompute; initial construction errors
- all case stores are static deps

## `Readonly`

Returns read-only view.

Behavior:

- Get/Subscribe/Changed/Map/etc work
- Set/Update are unavailable/error
- destroying readonly view does not destroy source
- source destroy makes view destroyed

## `Subscribe`

Signature:

```luau
listener: (newValue: T, oldValue: T?) -> ()
opts: {
    Immediate: boolean?, -- default true
    Deferred: boolean?, -- default false for initial call
}
```

Preferred behavior:

- default initial delivery is synchronous and immediate
- if `Deferred = true`, initial delivery uses Scheduler.Defer
- future notifications follow store flush rules
- if disconnected before deferred initial delivery, skip

## `Changed`

Returns Signal with payload:

```luau
{
    New: T,
    Old: T,
}
```

Fires after subscribers during notification flush.

## `Wait`

Yields until next actual changed notification. Does not return initial subscription value.

Returns:

```luau
newValue, oldValue
```

If destroyed while waiting, error:

```text
Store.Wait: store destroyed
```

## `DisconnectAll`

Disconnects subscribers. Store remains live. Changed signal listeners are not disconnected; call `store:Changed():DisconnectAll()` for those.

## `Batch`

Runs block. Values and derived values update immediately. Notifications flush synchronously when outermost batch exits.

If block errors, no rollback. Rethrow after restoring batch depth.

## `Transaction`

Runs block. Values and derived values update immediately. Notifications are deferred until outermost transaction exits.

If block errors, no rollback. Rethrow after restoring transaction depth.

## `Snapshot`

Creates shallow snapshot of named writable stores and explicit provided stores.

Behavior:

- values are shallow references
- named keys use store names
- unnamed explicit stores may use internal keys for inspection
- snapshot must record enough info to Restore named writable stores

## `Restore`

Restores named writable stores from snapshot.

Options:

```luau
{
    Strict: boolean?,
}
```

Strict false: ignore unknown/non-writable/destroyed.

Strict true: error on unknown/non-writable/destroyed key.

Runs inside Transaction.

## `History`

Creates undo/redo manager for writable store.

Returned API:

```luau
{
    Undo: () -> boolean,
    Redo: () -> boolean,
    Clear: () -> (),
    Destroy: () -> (),
    CanUndo: ReadableStore<boolean>,
    CanRedo: ReadableStore<boolean>,
}
```

Behavior:

- tracks actual changes, not initial subscription
- supports nil values correctly using explicit first-event flag
- limit default 100
- limit must be positive integer
- Destroy disconnects subscription and destroys CanUndo/CanRedo stores

## Collection and animation helpers

Do not put table/set/map/tween/spring helpers in Store core for this rewrite unless they already exist and are required. Keep kernel Store focused.
