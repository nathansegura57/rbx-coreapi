# Store

A reactive state cell. A `Store` holds a single value; subscribers are notified whenever it changes. Derived stores and combinators let you compose reactive data pipelines without manual glue code.

Changes are batched automatically — subscribers receive one notification per frame, not one per `Set` call. Use `Store.Batch` or `Store.Transaction` to coalesce multiple stores.

---

## API Reference

### Constructors

#### `Store.Value(initial, opts?)`

Creates a new writable store.

| Parameter | Type | Description |
|-----------|------|-------------|
| `initial` | `T` | Initial value |
| `opts` | `ValueOptions<T>?` | Optional configuration |

**`ValueOptions<T>` fields:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `Name` | `string?` | `nil` | Global registry name; must be non-empty |
| `Equals` | `((T, T) -> boolean)?` | `==` | Custom equality; prevents notification when `true` |
| `ReplaceName` | `boolean?` | `false` | If `true`, overwrites an existing named store |

**Returns:** `WritableStore<T>`

**Errors:**
- `Store.Value: opts must be a table or nil`
- `Store.Value: Name must be a non-empty string or nil`
- `Store.Value: Equals must be a function or nil`
- `Store.Value: ReplaceName must be a boolean or nil`
- `Store.Value: duplicate store name '{name}'`

```luau
local score = Store.Value(0)
local name  = Store.Value("Player", { Name = "PlayerName" })
local vec2  = Store.Value(Vector2.zero, {
    Equals = function(a, b) return a == b end,
})
```

---

#### `Store.Const(value)`

Creates an immutable store. Attempting to call `Set` on it throws. Useful as a stable dependency or placeholder.

| Parameter | Type | Description |
|-----------|------|-------------|
| `value` | `T` | The fixed value |

**Returns:** `ReadableStore<T>`

---

#### `Store.Derive(compute, deps, opts?)`

Creates a derived store whose value is the result of `compute()`. Recomputed automatically whenever any `deps` store changes.

| Parameter | Type | Description |
|-----------|------|-------------|
| `compute` | `() -> T` | Pure function; **must not have side effects** |
| `deps` | `{ ReadableStore<any> }` | Non-empty array of stores this computation reads |
| `opts` | `DeriveOptions<T>?` | Same fields as `ValueOptions` |

**Returns:** `ReadableStore<T>`

**Errors:**
- `Store.Derive: compute must be a function`
- `Store.Derive: deps must be a non-empty dense array`
- `Store.Derive: dep at index {i} is not a live Store`
- `Store.Derive: initial compute failed: {error}` — `compute()` threw during construction
- `Store.Derive: Name must be a non-empty string or nil`
- `Store.Derive: duplicate store name '{name}'`

```luau
local a = Store.Value(3)
local b = Store.Value(4)
local hypotenuse = Store.Derive(function()
    return math.sqrt(a:Get() ^ 2 + b:Get() ^ 2)
end, { a, b })

a:Set(5)
-- hypotenuse recomputes automatically
```

---

#### `Store.Select(source, picker, equals?)`

Shorthand for a derived store that maps a single source. Equivalent to `Store.Derive(function() return picker(source:Get()) end, { source }, { Equals = equals })`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `source` | `ReadableStore<T>` | The store to project from |
| `picker` | `(T) -> U` | Extracts a sub-value |
| `equals` | `((U, U) -> boolean)?` | Optional equality override |

**Returns:** `ReadableStore<U>`

**Errors:**
- `Store.Select: source must be a live Store`
- `Store.Select: picker must be a function`
- `Store.Select: equals must be a function or nil`

```luau
local player = Store.Value({ Name = "Alice", Score = 0 })
local playerName = Store.Select(player, function(p) return p.Name end)
```

---

#### `Store.Combine(values)`

Creates a derived store from multiple sources combined into a single table. Accepts either an array of stores (produces an ordered array result) or a map of `{ [key] = store }` (produces a map result).

| Parameter | Type | Description |
|-----------|------|-------------|
| `values` | `{ ReadableStore<any> } \| { [any]: ReadableStore<any> }` | Array or map of stores |

**Returns:** `ReadableStore<{ any }>`

**Errors:**
- `Store.Combine: input must be a table`
- `Store.Combine: input must not be empty`
- `Store.Combine: entry at index {i} is not a live Store`
- `Store.Combine: value for key '{k}' is not a live Store`

```luau
-- Array form: result is { score, health }
local stats = Store.Combine({ scoreStore, healthStore })

-- Map form: result is { Score = ..., Health = ... }
local statsMap = Store.Combine({ Score = scoreStore, Health = healthStore })
```

---

#### `Store.AllTruthy(stores)`

A derived boolean store that is `true` when every store in `stores` holds a truthy value.

| Parameter | Type | Description |
|-----------|------|-------------|
| `stores` | `{ ReadableStore<any> }` | Non-empty array of live stores |

**Returns:** `ReadableStore<boolean>`

**Errors:**
- `Store.AllTruthy: stores must be a non-empty dense array of live Stores`
- `Store.AllTruthy: entry at index {i} is not a live Store`

---

#### `Store.AnyTruthy(stores)`

A derived boolean store that is `true` when at least one store in `stores` holds a truthy value.

| Parameter | Type | Description |
|-----------|------|-------------|
| `stores` | `{ ReadableStore<any> }` | Non-empty array of live stores |

**Returns:** `ReadableStore<boolean>`

**Errors:**
- `Store.AnyTruthy: stores must be a non-empty dense array of live Stores`

---

#### `Store.Match(source, cases)`

A derived store whose value tracks a `cases` map indexed by `source:Get()`. The `"_"` key is the default case.

| Parameter | Type | Description |
|-----------|------|-------------|
| `source` | `ReadableStore<any>` | The key store |
| `cases` | `{ [any]: ReadableStore<any> }` | Map of key → store; may include `"_"` default |

**Returns:** `ReadableStore<any>`

**Errors:**
- `Store.Match: source must be a live Store`
- `Store.Match: cases must be a table`
- `Store.Match: case '{k}' is not a live Store`
- `Store.Match: initial case not found and no default '_' case`
- Route error (`ErrorHandler.Report`) when a key changes to a value with no case and no default

```luau
local mode = Store.Value("idle")
local idleDisplay  = Store.Value("Waiting...")
local playDisplay  = Store.Value("Playing!")
local activeText = Store.Match(mode, {
    idle    = idleDisplay,
    playing = playDisplay,
    _       = Store.Const("Unknown"),
})
```

---

#### `Store.Readonly(store)`

Creates a derived store that mirrors `store` but cannot be written to via `Set`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `store` | `ReadableStore<T>` | Must be a live Store |

**Returns:** `ReadableStore<T>`

**Errors:**
- `Store.Readonly: store must be a live Store`

---

#### `Store.IsStore(value)`

Returns `true` if `value` is a live Store handle.

**Returns:** `boolean`

---

### Instance Methods

#### `handle:Get()`

Returns the current value.

**Errors:**
- `Store.Get: store is destroyed`

---

#### `handle:Set(value)`

Updates the value and schedules subscribers for notification. No-op if `value` equals the current value (by the configured `Equals` function).

| Parameter | Type | Description |
|-----------|------|-------------|
| `value` | `T` | New value |

**Errors:**
- `Store.Set: store is destroyed`
- `Store.Set: store is read-only`
- `Store.Set: only writable stores support Set`

---

#### `handle:Update(updater)`

Calls `updater(currentValue)` and passes the result to `Set`. If `updater` throws, the error is re-thrown from `Update` without changing the store.

| Parameter | Type | Description |
|-----------|------|-------------|
| `updater` | `(T) -> T` | Pure transform function |

**Errors:**
- `Store.Update: store is destroyed`
- `Store.Update: updater must be a function`
- Re-throws any error thrown by `updater`

```luau
count:Update(function(n) return n + 1 end)
```

---

#### `handle:Subscribe(listener, opts?)`

Subscribes `listener` to value changes. By default, calls `listener(currentValue, nil)` immediately (synchronously), then `listener(newValue, oldValue)` on every subsequent change.

| Parameter | Type | Description |
|-----------|------|-------------|
| `listener` | `(T, T?) -> ()` | Receives `(newValue, oldValue)`. `oldValue` is `nil` on immediate call. |
| `opts` | `SubscribeOptions?` | Optional configuration |

**`SubscribeOptions` fields:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `Immediate` | `boolean?` | `true` | Call `listener` with the current value on subscribe |
| `Deferred` | `boolean?` | `false` | Defer the immediate call via `Scheduler.Defer` |

**Returns:** `Connection.Connection`

**Errors:**
- `Store.Subscribe: store is destroyed`
- `Store.Subscribe: listener must be a function`
- `Store.Subscribe: opts must be a table or nil`
- `Store.Subscribe: Immediate must be a boolean or nil`
- `Store.Subscribe: Deferred must be a boolean or nil`

```luau
-- Immediate (default): listener fires now with current value, then on changes.
local conn = score:Subscribe(function(new, old)
    print("score:", old, "→", new)
end)

-- No immediate call: only fires on actual changes.
local conn2 = score:Subscribe(handler, { Immediate = false })

-- Deferred immediate: current value arrives next frame.
local conn3 = score:Subscribe(handler, { Deferred = true })

conn:Disconnect()
```

---

#### `handle:Changed()`

Returns a `Signal<{ New: T, Old: T }>` that fires whenever the store changes. The signal is created lazily and shared — calling `Changed()` multiple times returns the same signal.

**Returns:** `Signal.Signal<{ New: T, Old: T }>`

```luau
local sig = score:Changed()
sig:Connect(function(evt)
    print("changed from", evt.Old, "to", evt.New)
end)
```

---

#### `handle:Map(picker, equals?)`

Shorthand for `Store.Select(self, picker, equals)`. Returns a new derived store.

---

#### `handle:Equals(eq)`

Returns a new derived store that mirrors this one but uses `eq` as its equality function. Useful for adding deep equality to an existing store without reconstructing it.

| Parameter | Type | Description |
|-----------|------|-------------|
| `eq` | `(T, T) -> boolean` | Equality function |

**Returns:** `ReadableStore<T>`

---

#### `handle:Name()`

Returns the store's registered name, or `nil` if unnamed.

**Returns:** `string?`

---

#### `handle:Deps()`

Returns a clone of this store's dependency list. For non-derived stores, returns `{}`.

**Returns:** `{ ReadableStore<any> }`

---

#### `handle:Wait()`

Yields until the store's value changes, then returns `(newValue, oldValue)`. Throws if the store is destroyed while waiting.

**Returns:** `(T, T)` — `(newValue, oldValue)`

**Errors:**
- `Store.Wait: store destroyed`
- `Store.Wait: must be called from a yieldable coroutine`
- `Store.Wait: store destroyed` — store was destroyed during the wait

```luau
local new, old = score:Wait()
```

---

#### `handle:DisconnectAll()`

Disconnects all subscribers. The store remains alive and can accept new subscribers.

---

#### `handle:IsDestroyed()`

Returns `true` if the store has been destroyed.

**Returns:** `boolean`

---

#### `handle:Destroy()`

Destroys the store and all derived stores that depend on it. All subscriber connections are dropped; any `Wait` calls are unblocked with an error.

Idempotent.

---

### Batch and Transaction

#### `Store.Batch(block)`

Runs `block()` with subscriber notifications suppressed. All pending notifications are flushed synchronously when `block` returns. If `block` throws, the error is re-thrown and a flush still occurs for any changes that were made before the error.

| Parameter | Type | Description |
|-----------|------|-------------|
| `block` | `() -> ()` | Runs multiple `Set` calls as one logical update |

**Errors:**
- `Store.Batch: block must be a function`
- Re-throws any error from `block`

```luau
Store.Batch(function()
    score:Set(100)
    health:Set(50)
    name:Set("Alice")
end)
-- subscribers for score, health, name each receive one notification here
```

---

#### `Store.Transaction(block)`

Like `Batch`, but defers the flush to the next frame via `Scheduler.Defer`. Useful when you want multiple `Set` calls to coalesce even across synchronous call boundaries.

| Parameter | Type | Description |
|-----------|------|-------------|
| `block` | `() -> ()` | Runs multiple `Set` calls |

**Errors:**
- `Store.Transaction: block must be a function`
- Re-throws any error from `block`

---

### Snapshot and Restore

#### `Store.Snapshot(...)`

Captures the current value of each named store into a plain table keyed by store name. Unnamed stores are keyed by their handle (but this key is not restorable).

| Parameter | Type | Description |
|-----------|------|-------------|
| `...` | `ReadableStore<any>` | Varargs; all must be live Stores |

**Returns:** `Snapshot` (`{ [string | any]: any }`)

**Errors:**
- `Store.Snapshot: all arguments must be live Stores`

```luau
local snap = Store.Snapshot(score, health, name)
```

---

#### `Store.Restore(snapshot, opts?)`

Restores named store values from a snapshot inside a `Transaction`. Unnamed or non-writable stores in the snapshot are silently skipped unless `Strict = true`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `snapshot` | `Snapshot` | Previously captured snapshot |
| `opts` | `{ Strict: boolean? }?` | If `Strict = true`, errors on unknown/destroyed/non-writable stores |

**Errors:**
- `Store.Restore: opts must be a table or nil`
- `Store.Restore: Strict must be a boolean or nil`
- *(Strict mode only)* `Store.Restore: unknown store '{k}'`
- *(Strict mode only)* `Store.Restore: store '{k}' is destroyed`
- *(Strict mode only)* `Store.Restore: store '{k}' is not writable`
- *(Strict mode only)* `Store.Restore: snapshot contains unnamed store entry which is not restorable`

---

### History

#### `Store.History(store, limit?)`

Attaches undo/redo history to a writable store. Returns a `History` object.

| Parameter | Type | Description |
|-----------|------|-------------|
| `store` | `WritableStore<T>` | Must be a live, writable Store |
| `limit` | `number?` | Max undo stack depth; defaults to `100` |

**Returns:** `History<T>`

**`History<T>` API:**

| Member | Type | Description |
|--------|------|-------------|
| `CanUndo` | `ReadableStore<boolean>` | `true` when undo is available |
| `CanRedo` | `ReadableStore<boolean>` | `true` when redo is available |
| `Undo()` | `() -> boolean` | Undoes the last change; returns `false` if nothing to undo |
| `Redo()` | `() -> boolean` | Redoes the last undone change; returns `false` if nothing to redo |
| `Clear()` | `() -> ()` | Clears both undo and redo stacks |
| `Destroy()` | `() -> ()` | Stops tracking; destroys `CanUndo`/`CanRedo` stores |

**Errors:**
- `Store.History: store must be a writable live Store`
- `Store.History: limit must be a positive integer or nil`

```luau
local text   = Store.Value("")
local history = Store.History(text, 50)

text:Set("Hello")
text:Set("Hello World")

history:Undo()   -- text is now "Hello"
history:Redo()   -- text is now "Hello World"
history:Destroy()
```

---

## Gotchas

- **Notifications are deferred, not immediate.** When you call `Set`, subscribers are not called right away — they are collected and called on the next `Scheduler.Defer` flush. If you need to observe the new value immediately, call `Get()` directly.
- **`Set` during a subscriber callback is safe.** The flush loop processes stores in waves; a `Set` made inside a subscriber schedules another flush wave, so all downstream updates are eventually consistent. However, infinite loops are possible if a subscriber unconditionally sets the same store.
- **`Batch` flushes synchronously, `Transaction` defers.** Choose based on whether you need all subscribers to run before `Batch` returns (Batch) or whether you want to coalesce further sets that happen in the same frame (Transaction).
- **Derived stores read current values, not old ones.** `compute()` in `Derive` always reads `dep:Get()` at the moment of recomputation, not the "before" value.
- **`Store.Derive` initial compute runs synchronously.** If the initial `compute()` throws, `Store.Derive` throws too. There is no deferred recovery.
- **Destroying a store destroys all derived stores downstream.** The entire consumer chain is torn down. Disconnect downstream subscriptions first if you want finer-grained cleanup.
- **Named stores are global.** Two `Store.Value` calls with the same `Name` throw a duplicate error unless `ReplaceName = true`. Use `ReplaceName` only when you intentionally replace a singleton.
- **`History` suppresses its own `Set` calls.** While `Undo`/`Redo` is applying a value, the subscriber is marked as suppressed so the operation does not push itself onto the undo stack.
