# Store API Reference

`Store` is the reactive state primitive for CoreAPI.

Place this module at:

```text
ReplicatedStorage/Shared/Kernel/Store
```

A store holds exactly one value.

Subscribers are notified whenever that value changes.

Unlike `Signal`, which represents discrete events, a `Store` represents persistent state.

`Store` is designed for:

- reactive application state;
- derived state composition;
- batched updates;
- deterministic state propagation;
- transactional mutation;
- undo/redo history;
- state snapshots;
- UI binding;
- declarative dataflow.

It depends on:

```text
ReplicatedStorage/Shared/Kernel/Connection
ReplicatedStorage/Shared/Kernel/ErrorHandler
ReplicatedStorage/Shared/Kernel/Scheduler
ReplicatedStorage/Shared/Kernel/Signal
```

---

# Design Goals

`Store` exists to solve five major architectural problems.

## Persistent Reactive State

Signals model events.

Stores model state.

A store always has a current value.

```luau
local score = Store.Value(0)

print(score:Get()) -- always valid
```

---

## Declarative Derived State

Derived stores automatically recompute from dependencies.

```luau
local fullName = Store.Derive(function()
    return firstName:Get() .. " " .. lastName:Get()
end, { firstName, lastName })
```

No manual synchronization is required.

---

## Batched Notifications

Multiple synchronous mutations coalesce automatically.

Subscribers are notified once per flush wave rather than once per mutation.

This avoids:

- redundant UI work;
- recomputation storms;
- inconsistent intermediate states.

---

## Deterministic Runtime Behavior

Subscriber callbacks route through `ErrorHandler`.

Timing behavior routes through `Scheduler`.

Subscription lifecycle routes through `Connection`.

This keeps Store behavior consistent with the rest of the Kernel.

---

## Composable State Infrastructure

Stores compose into:

- derived stores;
- selectors;
- combined stores;
- history systems;
- transactional updates;
- snapshots;
- readonly projections.

without requiring bespoke glue code.

---

# Core Mental Model

A store has three responsibilities:

```text
current value
    ↓
subscriptions
    ↓
derived recomputation
```

A writable store owns mutable state.

A derived store computes state from dependencies.

Subscribers observe state transitions.

---

# Importing

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Store = require(ReplicatedStorage.Shared.Kernel.Store)
```

---

# Relationship to Other Kernel Modules

## Relationship to `Signal`

`Store:Changed()` exposes store transitions as a `Signal`.

Signals represent events.

Stores represent state.

A signal may fire zero or many times.

A store always has a current value.

---

## Relationship to `Connection`

`Store:Subscribe()` returns `Connection.Connection`.

This makes subscriber lifecycle consistent across the Kernel.

---

## Relationship to `Scheduler`

Store notifications flush through `Scheduler.Defer`.

`Transaction` also uses deferred flush behavior.

This allows deterministic scheduler mocking in tests.

---

## Relationship to `ErrorHandler`

Subscriber callbacks, equality callbacks, updater callbacks, and derived compute functions are runtime callbacks.

Failures route through `ErrorHandler`.

This ensures:

- one subscriber failure does not stop others;
- runtime behavior follows global policy;
- failures remain observable.

---

# Exported Types

## `Store.ReadableStore<T>`

```luau
type ReadableStore<T> = opaque
```

A readonly reactive state cell.

Readable stores support:

- observation;
- derivation;
- subscription;
- lookup.

Readable stores do not support mutation.

---

## `Store.WritableStore<T>`

```luau
type WritableStore<T> = opaque
```

A mutable reactive state cell.

Writable stores additionally support:

- `Set`;
- `Update`.

---

## `Store.Listener<T>`

```luau
type Listener<T> = (newValue: T, oldValue: T?) -> ()
```

A callback invoked whenever the store changes.

`oldValue` is `nil` during immediate subscription delivery.

---

## `Store.ValueOptions<T>`

```luau
type ValueOptions<T> = {
    Name: string?,
    Equals: ((T, T) -> boolean)?,
    ReplaceName: boolean?,
}
```

Options for writable and derived stores.

---

## `Store.SubscribeOptions`

```luau
type SubscribeOptions = {
    Immediate: boolean?,
    Deferred: boolean?,
}
```

Controls subscription initialization behavior.

Defaults:

```luau
Immediate = true
Deferred = false
```

---

# Constructors

# `Store.Value`

```luau
Store.Value<T>(
    initial: T,
    opts: Store.ValueOptions<T>?
): Store.WritableStore<T>
```

Creates a writable store.

## Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `initial` | `T` | Yes | Initial store value. |
| `opts` | `Store.ValueOptions<T>?` | No | Optional configuration. |

## Returns

| Type | Description |
|---|---|
| `Store.WritableStore<T>` | Writable store. |

## Options

| Field | Type | Default | Description |
|---|---|---|---|
| `Name` | `string?` | `nil` | Global registry name. |
| `Equals` | `((T, T) -> boolean)?` | `==` | Equality comparator. |
| `ReplaceName` | `boolean?` | `false` | Replace existing named store. |

## Possible Usage Errors

```text
Store.Value: opts must be a table or nil
Store.Value: Name must be a non-empty string or nil
Store.Value: Equals must be a function or nil
Store.Value: ReplaceName must be a boolean or nil
Store.Value: duplicate store name '{name}'
```

## Example

```luau
local score = Store.Value(0)

score:Set(100)
```

---

# `Store.Const`

```luau
Store.Const<T>(
    value: T
): Store.ReadableStore<T>
```

Creates an immutable store.

## Behavior

Const stores cannot be written to.

Calling `Set` raises immediately.

Useful for:

- stable dependencies;
- placeholders;
- readonly defaults;
- capability injection.

## Example

```luau
local config = Store.Const({
    Version = 1,
})
```

---

# `Store.Derive`

```luau
Store.Derive<T>(
    compute: () -> T,
    deps: { Store.ReadableStore<any> },
    opts: Store.ValueOptions<T>?
): Store.ReadableStore<T>
```

Creates a derived store.

The store recomputes whenever dependencies change.

## Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `compute` | `() -> T` | Yes | Pure derivation function. |
| `deps` | `{ Store.ReadableStore<any> }` | Yes | Dependency stores. |
| `opts` | `Store.ValueOptions<T>?` | No | Optional configuration. |

## Behavior

Derived stores:

- recompute automatically;
- cache current value;
- propagate changes reactively;
- cannot be written to directly.

## Runtime Error Behavior

If `compute` throws during recomputation:

1. the failure routes through `ErrorHandler`;
2. the recomputation is skipped;
3. the previous value remains active.

If the initial synchronous compute fails during construction:

```text
Store.Derive: initial compute failed: {error}
```

is raised.

## Possible Usage Errors

```text
Store.Derive: compute must be a function
Store.Derive: deps must be a non-empty dense array
Store.Derive: dep at index {i} is not a live Store
```

## Example

```luau
local a = Store.Value(3)
local b = Store.Value(4)

local hypotenuse = Store.Derive(function()
    return math.sqrt(a:Get() ^ 2 + b:Get() ^ 2)
end, { a, b })
```

---

# `Store.Select`

```luau
Store.Select<T, U>(
    source: Store.ReadableStore<T>,
    picker: (T) -> U,
    equals: ((U, U) -> boolean)?
): Store.ReadableStore<U>
```

Creates a derived projection from a single source.

Equivalent to:

```luau
Store.Derive(function()
    return picker(source:Get())
end, { source })
```

## Example

```luau
local playerName = Store.Select(playerStore, function(player)
    return player.Name
end)
```

---

# `Store.Combine`

```luau
Store.Combine(
    values: { Store.ReadableStore<any> }
        | { [any]: Store.ReadableStore<any> }
): Store.ReadableStore<{ any }>
```

Combines multiple stores into one derived aggregate store.

Supports:

- dense arrays;
- keyed maps.

## Example: Array Form

```luau
local stats = Store.Combine({
    scoreStore,
    healthStore,
})
```

## Example: Map Form

```luau
local stats = Store.Combine({
    Score = scoreStore,
    Health = healthStore,
})
```

---

# `Store.AllTruthy`

```luau
Store.AllTruthy(
    stores: { Store.ReadableStore<any> }
): Store.ReadableStore<boolean>
```

Returns `true` only when every store holds a truthy value.

---

# `Store.AnyTruthy`

```luau
Store.AnyTruthy(
    stores: { Store.ReadableStore<any> }
): Store.ReadableStore<boolean>
```

Returns `true` when at least one store holds a truthy value.

---

# `Store.Match`

```luau
Store.Match(
    source: Store.ReadableStore<any>,
    cases: { [any]: Store.ReadableStore<any> }
): Store.ReadableStore<any>
```

Selects stores dynamically based on another store's value.

## Example

```luau
local activeText = Store.Match(mode, {
    idle = idleDisplay,
    playing = playDisplay,
    _ = Store.Const("Unknown"),
})
```

`"_"` acts as the default case.

---

# `Store.Readonly`

```luau
Store.Readonly<T>(
    store: Store.ReadableStore<T>
): Store.ReadableStore<T>
```

Creates a readonly mirror of another store.

---

# `Store.IsStore`

```luau
Store.IsStore(value: unknown): boolean
```

Returns whether a value is a live store handle.

---

# Instance Methods

# `store:Get`

```luau
store:Get(): T
```

Returns the current value.

## Possible Usage Errors

```text
Store.Get: store is destroyed
```

---

# `store:Set`

```luau
store:Set(value: T): ()
```

Updates the store value.

## Behavior

If the configured equality comparator returns `true`, no notification occurs.

Notifications are deferred and batched automatically.

## Runtime Error Behavior

If the equality comparator throws:

1. the failure routes through `ErrorHandler`;
2. the comparison fails closed;
3. the update proceeds.

## Possible Usage Errors

```text
Store.Set: store is destroyed
Store.Set: store is read-only
Store.Set: only writable stores support Set
```

## Example

```luau
score:Set(100)
```

---

# `store:Update`

```luau
store:Update(
    updater: (T) -> T
): ()
```

Transforms the current value.

Equivalent to:

```luau
store:Set(updater(store:Get()))
```

## Runtime Error Behavior

If `updater` throws:

1. the failure routes through `ErrorHandler`;
2. the store value remains unchanged.

## Example

```luau
score:Update(function(value)
    return value + 1
end)
```

---

# `store:Subscribe`

```luau
store:Subscribe(
    listener: Store.Listener<T>,
    opts: Store.SubscribeOptions?
): Connection.Connection
```

Subscribes to store changes.

## Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `listener` | `Store.Listener<T>` | Yes | Subscriber callback. |
| `opts` | `Store.SubscribeOptions?` | No | Subscription behavior. |

## Behavior

By default:

```luau
listener(currentValue, nil)
```

fires immediately during subscription.

Later changes receive:

```luau
listener(newValue, oldValue)
```

## Deferred Immediate Delivery

If:

```luau
Deferred = true
```

the initial delivery occurs through `Scheduler.Defer`.

## Runtime Error Behavior

Subscriber failures route through `ErrorHandler`.

One failing subscriber does not stop others.

## Returns

| Type | Description |
|---|---|
| `Connection.Connection` | Subscription handle. |

## Example

```luau
local connection = score:Subscribe(function(newValue, oldValue)
    print(oldValue, "→", newValue)
end)
```

---

# `store:Changed`

```luau
store:Changed(): Signal.Signal<{ New: T, Old: T }>
```

Returns a shared lazily-created signal of store transitions.

## Example

```luau
store:Changed():Connect(function(event)
    print(event.Old, event.New)
end)
```

---

# `store:Map`

```luau
store:Map<U>(
    picker: (T) -> U,
    equals: ((U, U) -> boolean)?
): Store.ReadableStore<U>
```

Shorthand for `Store.Select(self, picker, equals)`.

---

# `store:Equals`

```luau
store:Equals(
    eq: (T, T) -> boolean
): Store.ReadableStore<T>
```

Creates a readonly derived store using a different equality comparator.

Useful for deep equality.

---

# `store:Name`

```luau
store:Name(): string?
```

Returns the registered store name.

---

# `store:Deps`

```luau
store:Deps(): { Store.ReadableStore<any> }
```

Returns a cloned dependency array.

Non-derived stores return `{}`.

---

# `store:Wait`

```luau
store:Wait(): (T, T)
```

Yields until the next change.

Returns:

```luau
(newValue, oldValue)
```

## Possible Usage Errors

```text
Store.Wait: must be called from a yieldable coroutine
Store.Wait: store destroyed
```

---

# `store:DisconnectAll`

```luau
store:DisconnectAll(): ()
```

Disconnects all subscribers without destroying the store.

---

# `store:IsDestroyed`

```luau
store:IsDestroyed(): boolean
```

Returns whether the store has been destroyed.

---

# `store:Destroy`

```luau
store:Destroy(): ()
```

Destroys the store.

## Behavior

Destroying a store:

1. disconnects subscribers;
2. destroys downstream derived stores;
3. resumes active waits with errors;
4. clears reactive relationships;
5. unregisters named stores.

Destruction is idempotent.

---

# Batch APIs

# `Store.Batch`

```luau
Store.Batch(
    block: () -> ()
): ()
```

Suppresses notifications during execution.

All pending notifications flush synchronously afterward.

## Runtime Error Behavior

If `block` throws:

1. batching state restores correctly;
2. pending notifications still flush;
3. the failure routes through `ErrorHandler`.

## Example

```luau
Store.Batch(function()
    score:Set(100)
    health:Set(50)
end)
```

Subscribers receive one consolidated flush wave.

---

# `Store.Transaction`

```luau
Store.Transaction(
    block: () -> ()
): ()
```

Like `Batch`, but flushes next frame through `Scheduler.Defer`.

Useful when synchronous call chains should coalesce into one async update wave.

## Runtime Error Behavior

If `block` throws:

1. transaction state restores correctly;
2. pending updates still flush;
3. the failure routes through `ErrorHandler`.

---

# Snapshot APIs

# `Store.Snapshot`

```luau
Store.Snapshot(
    ...: Store.ReadableStore<any>
): { [any]: any }
```

Captures current store values.

Named stores use their names as snapshot keys.

Unnamed stores use their handles.

---

# `Store.Restore`

```luau
Store.Restore(
    snapshot: { [any]: any },
    opts: { Strict: boolean? }?
): ()
```

Restores named writable stores inside a transaction.

## Strict Mode

When:

```luau
Strict = true
```

missing, destroyed, or readonly stores raise usage errors.

Otherwise they are skipped silently.

---

# History APIs

# `Store.History`

```luau
Store.History<T>(
    store: Store.WritableStore<T>,
    limit: number?
): History<T>
```

Attaches undo/redo history.

## Returns

| Member | Description |
|---|---|
| `CanUndo` | Boolean store tracking undo availability. |
| `CanRedo` | Boolean store tracking redo availability. |
| `Undo()` | Applies previous value. |
| `Redo()` | Reapplies undone value. |
| `Clear()` | Clears history stacks. |
| `Destroy()` | Stops tracking history. |

## Behavior

Undo/redo internally suppress their own writes so history operations do not recursively record themselves.

## Example

```luau
local history = Store.History(textStore)

history:Undo()
history:Redo()
```

---

# Notification Semantics

This is one of the most important Store behaviors.

# Notifications Are Deferred

Calling:

```luau
store:Set(value)
```

does not immediately call subscribers.

Instead:

1. the store is marked dirty;
2. a flush is scheduled;
3. subscribers run during the flush wave.

This prevents:

- redundant recomputation;
- cascading sync updates;
- inconsistent intermediate state.

---

# Flush Waves

Subscriber callbacks may call `Set`.

This schedules another flush wave.

Flushes continue until no dirty stores remain.

This guarantees eventual consistency.

---

# Equality Semantics

Equality comparators determine whether changes propagate.

Default equality uses:

```luau
==
```

Custom comparators may implement:

- deep equality;
- epsilon equality;
- structural comparison;
- normalized comparison.

---

# Runtime Error Routing

Runtime callbacks route through `ErrorHandler`.

This includes:

- subscriber callbacks;
- updater callbacks;
- equality callbacks;
- derive compute callbacks.

Usage errors still raise immediately.

---

# Derived Store Ownership

Derived stores belong to their dependency graph.

Destroying a dependency destroys downstream derived stores automatically.

This prevents leaked reactive graphs.

---

# Gotchas

# Notifications Are Not Immediate

This is valid:

```luau
store:Set(100)

print(store:Get()) -- 100
```

but subscribers have not necessarily run yet.

---

# Derived Compute Functions Must Be Pure

Bad:

```luau
Store.Derive(function()
    score:Set(100)
    return 0
end, { score })
```

Derived computes should not mutate stores or cause side effects.

---

# Equality Functions Should Be Cheap

Equality runs during every attempted update.

Expensive equality functions can become a bottleneck.

---

# Batch And Transaction Are Different

`Batch` flushes synchronously.

`Transaction` flushes next frame.

Choose intentionally.

---

# Named Stores Are Global

Two stores cannot share the same name unless replacement is explicitly enabled.

---

# Destroying Parents Destroys Derived Children

Destroying a source store tears down downstream derived stores.

Do not hold stale references to destroyed derived stores.

---

# Best Practices

# Prefer Derived Stores Over Manual Synchronization

Good:

```luau
local fullName = Store.Derive(function()
    return first:Get() .. " " .. last:Get()
end, { first, last })
```

Avoid manually synchronizing dependent state.

---

# Prefer `Update` For Transform Mutations

Good:

```luau
score:Update(function(value)
    return value + 1
end)
```

---

# Prefer Transactions For Large Update Waves

Good:

```luau
Store.Transaction(function()
    score:Set(100)
    health:Set(50)
    mana:Set(20)
end)
```

---

# Use Readonly Views At Boundaries

Expose readonly stores to consumers that should not mutate state.

---

# Use `Changed` When Signal Composition Is Desired

Signals integrate naturally with the reactive operator pipeline.

---

# Full Example: Reactive Character Stats

```luau
local health = Store.Value(100)
local mana = Store.Value(50)

local alive = Store.Select(health, function(value)
    return value > 0
end)

alive:Subscribe(function(value)
    print("alive:", value)
end)

health:Set(0)
```

---

# Full Example: Derived UI State

```luau
local loading = Store.Value(false)
local hasError = Store.Value(false)

local canSubmit = Store.Derive(function()
    return not loading:Get() and not hasError:Get()
end, {
    loading,
    hasError,
})
```

---

# Full Example: Transactional Updates

```luau
Store.Transaction(function()
    coins:Set(coins:Get() - 10)
    inventory:Set(newInventory)
    selectedItem:Set(nil)
end)
```

---

# Full Example: Undo/Redo

```luau
local text = Store.Value("")
local history = Store.History(text)

text:Set("Hello")
text:Set("Hello World")

history:Undo()
history:Redo()
```

---

# Summary

Use `Store` whenever systems need persistent reactive state.

Use:

- `Value` for writable state;
- `Const` for immutable state;
- `Derive` for reactive computation;
- `Select` for projections;
- `Combine` for aggregate state;
- `Batch` and `Transaction` for coordinated updates;
- `History` for undo/redo;
- `Snapshot` and `Restore` for serialization flows.

The result is a deterministic reactive state system integrated with the Kernel lifecycle, timing, and runtime error semantics.
