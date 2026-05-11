# 06 — Store Specification

`Store` is reactive state.

Stores hold values, derive values, notify subscribers, expose change signals, support snapshots, restore, and history.

Collection helpers and animation helpers are not part of Store core in this rewrite.

## Public API

```luau
Store.Value<T>(initial: T, opts: ValueOptions<T>?): Store.WritableStore<T>
Store.Const<T>(value: T): Store.ReadableStore<T>
Store.Derive<T>(compute: () -> T, deps: { Store.ReadableStore<any> }, opts: DeriveOptions<T>?): Store.ReadableStore<T>
Store.Select<S, T>(source: Store.ReadableStore<S>, picker: (S) -> T, equals: ((T, T) -> boolean)?): Store.ReadableStore<T>
Store.Combine(values: any): Store.ReadableStore<any>
Store.AllTruthy(stores: { Store.ReadableStore<any> }): Store.ReadableStore<boolean>
Store.AnyTruthy(stores: { Store.ReadableStore<any> }): Store.ReadableStore<boolean>
Store.Match(source: Store.ReadableStore<any>, cases: { [any]: Store.ReadableStore<any> }): Store.ReadableStore<any>
Store.Readonly<T>(store: Store.WritableStore<T>): Store.ReadableStore<T>
Store.IsStore(value: unknown): boolean
Store.Batch(block: () -> ()): ()
Store.Transaction(block: () -> ()): ()
Store.Snapshot(...stores: Store.ReadableStore<any>): Snapshot
Store.Restore(snapshot: Snapshot, opts: RestoreOptions?): ()
Store.History<T>(store: Store.WritableStore<T>, limit: number?): History<T>
```

## Readable methods

```luau
store:Get(): T
store:Peek(): T
store:Subscribe(listener: (newValue: T, oldValue: T?) -> (), opts: SubscribeOptions?): Connection.Connection
store:Changed(): Signal.Signal<{ New: T, Old: T }>
store:Map<U>(picker: (T) -> U, equals: ((U, U) -> boolean)?): Store.ReadableStore<U>
store:Equals(equals: (T, T) -> boolean): Store.ReadableStore<T>
store:Name(): string?
store:Deps(): { Store.ReadableStore<any> }
store:Wait(): (T, T)
store:DisconnectAll(): ()
store:IsDestroyed(): boolean
store:Destroy(): ()
```

## Writable methods

```luau
store:Set(value: T): ()
store:Update(updater: (T) -> T): ()
```

## Types

```luau
export type ReadableStore<T> = {
    Get: (self: ReadableStore<T>) -> T,
    Peek: (self: ReadableStore<T>) -> T,
    Subscribe: (self: ReadableStore<T>, listener: (T, T?) -> (), opts: SubscribeOptions?) -> Connection.Connection,
    Changed: (self: ReadableStore<T>) -> Signal.Signal<{ New: T, Old: T }>,
    Map: <U>(self: ReadableStore<T>, picker: (T) -> U, equals: ((U, U) -> boolean)?) -> ReadableStore<U>,
    Equals: (self: ReadableStore<T>, equals: (T, T) -> boolean) -> ReadableStore<T>,
    Name: (self: ReadableStore<T>) -> string?,
    Deps: (self: ReadableStore<T>) -> { ReadableStore<any> },
    Wait: (self: ReadableStore<T>) -> (T, T),
    DisconnectAll: (self: ReadableStore<T>) -> (),
    IsDestroyed: (self: ReadableStore<T>) -> boolean,
    Destroy: (self: ReadableStore<T>) -> (),
}

export type WritableStore<T> = ReadableStore<T> & {
    Set: (self: WritableStore<T>, value: T) -> (),
    Update: (self: WritableStore<T>, updater: (T) -> T) -> (),
}
```

## Core semantics

- `Set` updates current value immediately.
- Derived stores recompute immediately during cascades.
- Subscriber notifications are scheduled through `Scheduler.Defer` unless inside `Batch`.
- Multiple writes before flush coalesce.
- Listener errors route through `ErrorHandler`.
- Destroy is idempotent.
- Destroying a source destroys derived consumers recursively.
- Readonly stores/views do not expose `Set` or `Update` in public type.
- Dynamic access to `Set` or `Update` on readonly stores errors.
- No automatic dependency tracking is implemented.

## Handle model

Store handles may be opaque.

If opaque handles are used:

```text
getmetatable(store) == "Store"
```

Field assignment errors:

```text
Store: '<field>' is read-only
```

## Options

```luau
export type ValueOptions<T> = {
    Name: string?,
    Equals: ((oldValue: T, newValue: T) -> boolean)?,
    ReplaceName: boolean?,
}

export type DeriveOptions<T> = ValueOptions<T>
```

Default equality:

```luau
oldValue == newValue
```

`ReplaceName` default:

```luau
false
```

## `Store.Value(initial, opts?)`

Creates writable store.

### Validation

- `opts` must be table or nil.
- `Name`, if supplied, must be non-empty string.
- `Equals`, if supplied, must be function.
- `ReplaceName`, if supplied, must be boolean.

Duplicate names error unless `ReplaceName = true`.

Error:

```text
Store.Value: duplicate store name '<name>'
```

### Behavior

- Store initial value, including nil with presence.
- Kind is writable value.
- Optional name registers store for restore.
- Named registry stores the newest store only when `ReplaceName = true`.

## `Store.Const(value)`

Creates read-only constant store.

### Behavior

- `Get` returns value.
- `Subscribe` supports initial delivery according to options.
- Never emits future changes.
- `Changed` returns a signal that never fires unless destroyed.
- `Destroy` works.
- `Set`/`Update` dynamic access errors.

## `Store.Derive(compute, deps, opts?)`

Creates derived readable store.

### Validation

- `compute` function.
- `deps` non-empty dense array.
- Every dep is live Store.
- Initial compute must succeed or construction errors.

Errors:

```text
Store.Derive: compute must be a function
Store.Derive: deps must be a non-empty dense array
Store.Derive: dep at index <n> is not a live Store
Store.Derive: initial compute failed: <message>
```

### Behavior

- Run initial compute immediately.
- Store result.
- Subscribe internally to deps.
- When any dep changes, recompute eagerly.
- If compute errors after initialization:
  - report through `ErrorHandler` phase `"Derive"`
  - if policy is `"Throw"`, error propagates from the cascade/flush call path
  - if not `"Throw"`, keep previous value and do not notify
- If new value equals old value, do not mark dirty.
- Destroying any dep destroys derived.
- Destroying derived unlinks from deps.

## `Store.Select(source, picker, equals?)`

Derived from one source.

Equivalent to:

```luau
Store.Derive(function()
    return picker(source:Get())
end, { source }, { Equals = equals })
```

### Validation

- source live store
- picker function
- equals nil or function

Picker errors follow derived compute error behavior.

## `Store.Combine(values)`

Combines stores into same shape.

### Accepted input

Dense array of stores:

```luau
Store.Combine({ A, B })
```

Object record of stores:

```luau
Store.Combine({
    Health = HealthStore,
    Name = NameStore,
})
```

### Validation

- input table
- every contained value is live Store
- array input must be dense if treated as array
- empty input errors

### Behavior

- If input is array, derived value is array of current store values in order.
- If input is object, derived value is object with same keys and current values.
- Nil store values are preserved with appropriate representation; object fields with nil may be absent at runtime, so consumers needing nil distinction should use stores directly.
- Dependencies are all contained stores.

## `Store.AllTruthy(stores)`

Boolean derived store.

### Validation

Non-empty dense array of live stores.

### Behavior

Returns true when every store value is truthy using Luau truthiness.

## `Store.AnyTruthy(stores)`

Boolean derived store.

### Validation

Non-empty dense array of live stores.

### Behavior

Returns true when any store value is truthy.

## `Store.Match(source, cases)`

Selects case store by source value.

### Validation

- source live store
- cases table
- every case value is live store
- `_`, if present, must be live store
- initial case must exist or `_` must exist

### Behavior

- Read `source:Get()` as key.
- If `cases[key]` exists, use it.
- Else use `cases["_"]`.
- Result is selected case store's current value.
- All case stores are static dependencies.
- Missing case during later recompute reports through ErrorHandler phase `"Match"`.
- If policy not `"Throw"`, keep previous value.

## `Store.Readonly(store)`

Creates read-only view of writable store.

### Validation

`store` must be live Store.

### Behavior

- Readable methods delegate to source.
- `Set`/`Update` are unavailable in type and error dynamically.
- Destroying readonly view disconnects view subscribers and marks view destroyed.
- Destroying readonly view does not destroy source.
- Destroying source destroys/invalidates view.

## `Store.IsStore(value)`

Returns true for Store handles created by this module.

Destroyed stores still return true.

## `store:Get()`

Returns current value.

### Validation

Store must not be destroyed.

Error:

```text
Store.Get: store is destroyed
```

## `store:Peek()`

Currently identical to `Get`.

Reserved for future untracked-read semantics if automatic dependency tracking is added.

No automatic dependency tracking exists in this rewrite.

## `store:Set(value)`

Sets writable store.

### Validation

- store live
- store writable
- readonly view rejects

Errors:

```text
Store.Set: store is destroyed
Store.Set: store is read-only
Store.Set: only writable stores support Set
```

### Behavior

- If equality says equal, return with no notification.
- Else:
  1. store old value
  2. set current value immediately
  3. mark dirty with old value for notification
  4. cascade derived recomputation immediately
  5. schedule flush unless inside Batch/Transaction rules

## `store:Update(updater)`

Updates writable store from current value.

### Validation

`updater` function plus Set validations.

Error:

```text
Store.Update: updater must be a function
```

### Behavior

- Call updater with current value.
- If updater errors, propagate directly as invalid runtime inside caller function; also acceptable to report through ErrorHandler phase `"Update"` only if implementation consistently treats user callbacks this way.
- Set returned value.

Normative requirement: updater errors must not mutate the store.

## `store:Subscribe(listener, opts?)`

Subscribes to value notifications.

### Options

```luau
{
    Immediate: boolean?,
    Deferred: boolean?,
}
```

Defaults:

```luau
Immediate = true
Deferred = false
```

### Validation

- store live
- listener function
- opts table/nil
- option fields boolean/nil

### Behavior

- Register subscriber.
- Return Connection.
- If `Immediate = true` and `Deferred = false`, call listener synchronously with `(currentValue, nil)`.
- If `Immediate = true` and `Deferred = true`, schedule initial delivery through `Scheduler.Defer`; if disconnected before delivery, skip.
- If `Immediate = false`, no initial delivery.
- Future notifications occur during flush with `(newValue, oldValue)`.
- Listener errors route through ErrorHandler phase `"Subscribe"`.

## `store:Changed()`

Returns signal of store changes.

Payload:

```luau
{
    New: T,
    Old: T,
}
```

### Behavior

- Lazily create signal.
- Fires after subscribers during notification flush.
- Does not fire for initial Subscribe delivery.
- Destroying store destroys changed signal.

## `store:Map(picker, equals?)`

Instance shorthand for `Store.Select(store, picker, equals)`.

## `store:Equals(equals)`

Creates derived readable store mirroring value with different equality.

Equivalent:

```luau
Store.Derive(function()
    return store:Get()
end, { store }, { Equals = equals })
```

## `store:Name()`

Returns store name or nil.

Destroyed stores return nil.

## `store:Deps()`

Returns clone of dependency array.

- Value/const stores return `{}`.
- Derived stores return deps clone.
- Destroyed stores return `{}`.

## `store:Wait()`

Yields until next actual changed notification.

### Behavior

- Does not return initial value.
- Returns `(newValue, oldValue)`.
- Must be called from yieldable coroutine.
- If store destroyed while waiting, raises:

```text
Store.Wait: store destroyed
```

## `store:DisconnectAll()`

Disconnects store subscribers.

### Behavior

- Store remains live.
- Changed signal listeners are not disconnected.
- To disconnect changed signal listeners:

```luau
store:Changed():DisconnectAll()
```

## `store:Destroy()`

Destroys store.

### Behavior

1. If already destroyed, return.
2. Mark destroyed.
3. Recursively destroy derived consumers.
4. Disconnect subscribers.
5. Destroy changed signal if created.
6. Remove named registry entry if this store owns it.
7. Unlink from dependencies.
8. Release references.

## Flush semantics

Normal Set schedules deferred flush.

Batch flushes synchronously at outermost exit.

Transaction defers until outermost exit and then schedules flush.

Reentrant subscriber mutations must be drained until no dirty stores remain during `Batch` flush.

## `Store.Batch(block)`

### Validation

`block` function.

### Behavior

- Increment batch depth.
- Run block.
- Restore depth even if block errors.
- No rollback on error.
- If outermost batch exits successfully, flush synchronously.
- If block errors, rethrow after restoring depth; writes remain applied.

## `Store.Transaction(block)`

Same as Batch except outermost successful exit schedules deferred flush instead of synchronous flush.

## `Store.Snapshot(...stores)`

Snapshots only provided stores.

### Validation

Every argument live Store.

### Behavior

- Named stores use their names as keys.
- Unnamed stores use internal inspection keys not restorable.
- Values are shallow references.
- Snapshot includes enough metadata to restore named writable stores.

## `Store.Restore(snapshot, opts?)`

Restores named writable stores from snapshot.

### Options

```luau
{ Strict: boolean? }
```

Default `Strict = false`.

### Behavior

- Runs inside Transaction.
- Strict false ignores unknown/non-writable/destroyed/malformed entries.
- Strict true errors on those cases.
- Only named writable stores are restored.

## `Store.History(store, limit?)`

Creates undo/redo manager.

### Validation

- store writable live
- limit positive integer or nil
- default limit 100

### Returned API

```luau
{
    Undo: () -> boolean,
    Redo: () -> boolean,
    Clear: () -> (),
    Destroy: () -> (),
    CanUndo: Store.ReadableStore<boolean>,
    CanRedo: Store.ReadableStore<boolean>,
}
```

### Behavior

- Tracks actual changes, not initial subscription.
- Supports nil values with presence tracking.
- Undo sets previous value and returns true if possible.
- Redo sets next value and returns true if possible.
- Clear empties stacks and updates flags.
- Destroy disconnects subscription and destroys CanUndo/CanRedo.
