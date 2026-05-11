# Store

## Purpose

`Store` is reactive state. Stores hold values, derive computed values, notify subscribers, and expose snapshot and history utilities.

## Import

```luau
local Store = require(path.to.Store)
```

## Public API reference

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

export type ValueOptions<T> = {
    Name: string?,
    Equals: ((oldValue: T, newValue: T) -> boolean)?,
    ReplaceName: boolean?,
}

export type DeriveOptions<T> = ValueOptions<T>

export type SubscribeOptions = {
    Immediate: boolean?,
    Deferred: boolean?,
}

export type Snapshot = any
export type RestoreOptions = { Strict: boolean? }
export type History<T> = {
    Undo: () -> boolean,
    Redo: () -> boolean,
    Clear: () -> (),
    Destroy: () -> (),
    CanUndo: ReadableStore<boolean>,
    CanRedo: ReadableStore<boolean>,
}
```

## `Store.Value(initial, opts?)`

Creates a writable store with an initial value.

**Options**

- `Name` — string name for snapshot/restore registry.
- `Equals` — custom equality function. Default is `==`.
- `ReplaceName` — if `true`, allow re-registering an existing name. Default `false`.

**Error behavior**

```text
Store.Value: opts must be a table or nil
Store.Value: Name must be a non-empty string
Store.Value: Equals must be a function
Store.Value: ReplaceName must be a boolean
Store.Value: duplicate store name '<name>'
```

**Nil behavior**

Nil as initial value is stored with presence tracking.

## `Store.Const(value)`

Creates a read-only store whose value never changes.

**Behavior**

- `Get` always returns `value`.
- `Changed` returns a signal that never fires while alive.
- `Set` and `Update` error dynamically.

## `Store.Derive(compute, deps, opts?)`

Creates a readable store whose value is computed from its dependencies.

**Error behavior**

```text
Store.Derive: compute must be a function
Store.Derive: deps must be a non-empty dense array
Store.Derive: dep at index <n> is not a live Store
Store.Derive: initial compute failed: <message>
```

**Behavior**

- Runs `compute()` immediately on creation.
- Recomputes eagerly when any dep changes.
- If compute errors after init: routes through `ErrorHandler` phase `"Derive"`. If policy is not `"Throw"`, keeps previous value.
- If new value equals old value, no notification is issued.
- Destroying any dep destroys this store.

## `Store.Select(source, picker, equals?)`

Shorthand for `Store.Derive(() -> picker(source:Get()), { source }, { Equals = equals })`.

## `Store.Combine(values)`

Combines an array or object of stores into a derived store of the same shape.

**Behavior**

- Array input: result is an array of current store values.
- Object input: result is an object with the same keys.

**Error behavior**

```text
Store.Combine: input must be a non-empty table
Store.Combine: value at index/key <k> is not a live Store
```

## `Store.AllTruthy(stores)`

Returns `true` when all store values are Luau-truthy.

## `Store.AnyTruthy(stores)`

Returns `true` when any store value is Luau-truthy.

## `Store.Match(source, cases)`

Selects a case store based on the current value of `source`.

**Behavior**

- Reads `source:Get()` as a key into `cases`.
- Falls back to `cases["_"]` if the key is absent.
- Missing case during recompute routes through `ErrorHandler` phase `"Match"`.

## `Store.Readonly(store)`

Returns a read-only view of a writable store.

**Behavior**

- Readable methods delegate to source.
- `Set`/`Update` are unavailable in the type and error dynamically.
- Destroying the view disconnects view subscribers but does not destroy the source.
- Destroying the source destroys the view.

## `Store.IsStore(value)`

Returns `true` for any store handle, including destroyed stores.

## `Store.Batch(block)`

Runs `block` and then flushes all pending notifications synchronously.

**Behavior**

- Reentrant mutations inside a flush are drained until no dirty stores remain.
- If `block` errors, dirty writes remain applied; the error is re-thrown.

## `Store.Transaction(block)`

Same as `Batch` but defers the flush instead of running it synchronously.

## `store:Get()`

Returns current value.

**Error behavior**

```text
Store.Get: store is destroyed
```

## `store:Peek()`

Currently identical to `Get`. Reserved for future untracked-read semantics.

## `store:Set(value)`

Sets the store value immediately. Schedules a deferred notification flush unless inside a `Batch` or `Transaction`.

**Error behavior**

```text
Store.Set: store is destroyed
Store.Set: store is read-only
Store.Set: only writable stores support Set
```

**Behavior**

- If the new value equals the old value (by the store's equality function), no notification is issued.

## `store:Update(updater)`

Calls `updater(currentValue)` and sets the returned value.

**Error behavior**

```text
Store.Update: updater must be a function
```

**Behavior**

- If `updater` errors, the store is not mutated.

## `store:Subscribe(listener, opts?)`

Registers a change listener.

**Options** (defaults: `Immediate = true`, `Deferred = false`)

- `Immediate = true, Deferred = false` — calls listener synchronously with `(currentValue, nil)` immediately.
- `Immediate = true, Deferred = true` — schedules initial delivery through `Scheduler.Defer`.
- `Immediate = false` — no initial delivery.

**Behavior**

- Future notifications deliver `(newValue, oldValue)`.
- Listener errors route through `ErrorHandler` phase `"Subscribe"`.

## `store:Changed()`

Returns a lazily-created `Signal` that fires `{ New = T, Old = T }` after subscribers during each notification flush. Does not fire for initial Subscribe delivery.

## `store:Map(picker, equals?)`

Shorthand for `Store.Select(store, picker, equals)`.

## `store:Equals(equals)`

Returns a derived store mirroring the value but using a different equality function.

## `store:Name()`

Returns the store name or `nil`. Destroyed stores return `nil`.

## `store:Deps()`

Returns a clone of the dependency array. Value and const stores return `{}`. Destroyed stores return `{}`.

## `store:Wait()`

Yields until the next actual changed notification.

**Behavior**

- Returns `(newValue, oldValue)`.
- Does not return the current value immediately.
- Must be called from a yieldable coroutine.
- If the store is destroyed while waiting, errors:

```text
Store.Wait: store destroyed
```

## `store:DisconnectAll()`

Disconnects all subscribers. The store remains live. Changed signal listeners are not disconnected.

## `store:Destroy()`

Destroys the store.

**Behavior** (in order)

1. No-op if already destroyed.
2. Mark destroyed.
3. Recursively destroy derived consumers.
4. Disconnect subscribers.
5. Destroy changed signal if created.
6. Remove named registry entry if owned by this store.
7. Unlink from dependencies.

## `Store.Snapshot(...stores)`

Captures current values of named stores.

**Behavior**

- Named stores use their names as keys.
- Unnamed stores use internal keys not suitable for restore.
- Values are shallow references.

## `Store.Restore(snapshot, opts?)`

Restores named writable stores from a snapshot inside a `Transaction`.

**Options**

- `Strict = false` (default) — ignores unknown, non-writable, destroyed, or malformed entries.
- `Strict = true` — errors on those cases.

## `Store.History(store, limit?)`

Creates an undo/redo manager.

**Parameters**

- `store` — a live writable store.
- `limit` — max history length. Default `100`.

**Behavior**

- Tracks actual value changes (not the initial value).
- `Undo()` sets the previous value, returns `true` if possible.
- `Redo()` sets the next value, returns `true` if possible.
- `Clear()` empties both stacks.
- `Destroy()` disconnects the subscription and destroys `CanUndo`/`CanRedo`.
- `CanUndo` and `CanRedo` are readable stores reflecting availability.

## Flush semantics

| Context | Flush behavior |
|---|---|
| Normal `Set` | Deferred via `Scheduler.Defer` |
| Inside `Batch` | Synchronous at outermost exit |
| Inside `Transaction` | Deferred at outermost exit |

## Lifecycle behavior

Destroying a derived store does not destroy its deps. Destroying a dep destroys all derived consumers recursively. Readonly views are destroyed when their source is destroyed.

## Nil behavior

Nil values are supported everywhere. Presence is tracked with a boolean flag, not by checking `value ~= nil`.

## Scheduler behavior

Subscriber notifications are delivered through `Scheduler.Defer`. The `Changed` signal fires after subscribers in the same flush.

## Not implemented

Automatic dependency tracking is not implemented. All deps must be supplied explicitly to `Store.Derive`. Collection helpers and animation helpers are not part of this module.
