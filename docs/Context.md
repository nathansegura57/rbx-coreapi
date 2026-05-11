# Context

A hierarchical dependency-injection container. A `Context` holds key→value pairs that can be looked up by child scopes without the child needing to know where the value came from. FSM modes receive a context layer scoped to their lifetime; rules and tasks read from it without owning it.

---

## API Reference

### `Context.Root(values)`

Creates a new root context pre-populated with the given key→value pairs. This is the top of a context tree.

| Parameter | Type | Description |
|-----------|------|-------------|
| `values` | `{ [any]: any }` | Initial values; keys may be strings or `ContextKey` handles |

**Returns:** `Context`

**Errors:**
- `Context.Root: values must be a table`

```luau
local ctx = Context.Root({
    Score = Store.Value(0),
    Player = playerInstance,
})
```

---

### `Context.Key(name)`

Creates a typed, opaque key handle. Prefer keys over plain strings when you want type-checker support or want to avoid collisions with unrelated string keys.

| Parameter | Type | Description |
|-----------|------|-------------|
| `name` | `string` | Human-readable label (shown in error messages); must be non-empty |

**Returns:** `ContextKey<T>`

**Errors:**
- `Context.Key: name must be a non-empty string`

```luau
local ScoreKey = Context.Key("Score")

local ctx = Context.Root({ [ScoreKey] = Store.Value(0) })
local score = ctx:Require(ScoreKey)  -- typed as the value you set
```

---

### `Context.IsContext(value)`

Returns `true` if `value` is any live Context handle (root, layer, or view).

| Parameter | Type | Description |
|-----------|------|-------------|
| `value` | `unknown` | Any value |

**Returns:** `boolean`

---

### `handle:Require(key)`

Looks up `key` in this context or any ancestor. Throws if not found.

| Parameter | Type | Description |
|-----------|------|-------------|
| `key` | `ContextKey<V> \| string` | The key to look up |

**Returns:** `V` — the stored value

**Errors:**
- `Context.Require: context is destroyed`
- `Context.Require: source context is destroyed` (view whose source was destroyed)
- `Context.Require: key must be a ContextKey or non-empty string`
- `Context.Require: key 'X' is not visible in this view`
- `Context.Require: missing key 'X'`
- `Context.Require: lazy provider cycle for key 'X'` — provider called `Require` on the same key
- `Context.Require: lazy provider failed for key 'X'` — provider threw under a non-Throw policy

```luau
local player = ctx:Require("Player")
local score  = ctx:Require(ScoreKey)
```

---

### `handle:Maybe(key)`

Like `Require`, but returns `nil` instead of throwing when the key is missing.

| Parameter | Type | Description |
|-----------|------|-------------|
| `key` | `ContextKey<V> \| string` | The key to look up |

**Returns:** `V?`

**Errors:**
- `Context.Maybe: context is destroyed`
- `Context.Maybe: source context is destroyed`

```luau
local score = ctx:Maybe("Score")
if score ~= nil then
    print(score:Get())
end
```

---

### `handle:Has(key)`

Returns `true` if `key` is present anywhere in the context chain. Does **not** resolve lazy providers.

| Parameter | Type | Description |
|-----------|------|-------------|
| `key` | `ContextKey<any> \| string` | The key to check |

**Returns:** `boolean`

**Errors:**
- `Context.Has: context is destroyed`
- `Context.Has: source context is destroyed`

---

### `handle:Set(key, value)`

Sets `key` to `value` in this context (not in ancestors). Overwrites any existing value or lazy provider for the same key.

| Parameter | Type | Description |
|-----------|------|-------------|
| `key` | `ContextKey<V> \| string` | The key |
| `value` | `V` | The value to store |

**Errors:**
- `Context.Set: context is destroyed`
- `Context.Set: context is read-only`
- `Context.Set: key must be a ContextKey or non-empty string`

---

### `handle:Provide(values)`

Bulk-sets key→value pairs. Equivalent to calling `Set` for each entry, but validates all keys before applying any.

| Parameter | Type | Description |
|-----------|------|-------------|
| `values` | `{ [any]: any }` | Map of keys to values |

**Errors:**
- `Context.Provide: context is destroyed`
- `Context.Provide: context is read-only`
- `Context.Provide: values must be a table`
- `Context.Provide: key must be a ContextKey or non-empty string`

---

### `handle:ProvideLazy(key, provider)`

Registers a lazy provider for `key`. The provider is called at most once on the first `Require` or `Maybe` for that key, then the result is cached and the provider is discarded.

| Parameter | Type | Description |
|-----------|------|-------------|
| `key` | `ContextKey<V> \| string` | The key |
| `provider` | `(Context<any>) -> V` | Called with the context on which `Require` was invoked |

**Errors:**
- `Context.ProvideLazy: context is destroyed`
- `Context.ProvideLazy: context is read-only`
- `Context.ProvideLazy: key must be a ContextKey or non-empty string`
- `Context.ProvideLazy: provider must be a function`

```luau
ctx:ProvideLazy("ExpensiveService", function(c)
    return MyService.New(c:Require("Config"))
end)

-- Later, on first use:
local svc = ctx:Require("ExpensiveService")  -- provider runs once here
local svc2 = ctx:Require("ExpensiveService") -- cached, provider not called again
```

---

### `handle:Layer(values, cleanup?)`

Creates a child context that inherits all keys from this context and additionally provides its own `values`. `cleanup` is called when the layer is destroyed.

| Parameter | Type | Description |
|-----------|------|-------------|
| `values` | `{ [any]: any }` | Keys scoped to this layer |
| `cleanup` | `(() -> ())?` | Called on destroy; errors route through `ErrorHandler` |

**Returns:** `Context` — the new child layer

**Errors:**
- `Context.Layer: context is destroyed`
- `Context.Layer: values must be a table`
- `Context.Layer: cleanup must be a function or nil`

```luau
local modeCtx = parentCtx:Layer({
    RoundScore = Store.Value(0),
}, function()
    print("mode context cleaned up")
end)

-- modeCtx:Require("Player") still works — falls through to parentCtx
-- parentCtx:Require("RoundScore") → not found, "RoundScore" is only in modeCtx
```

---

### `handle:View(keys)`

Creates a read-only child that exposes only the listed keys. Useful for sandboxing access to a subset of the context.

| Parameter | Type | Description |
|-----------|------|-------------|
| `keys` | `{ ContextKey<any> \| string }` | The keys to expose |

**Returns:** `Context` — read-only view

**Errors:**
- `Context.View: context is destroyed`
- `Context.View: keys must be an array`
- `Context.View: key must be a ContextKey or non-empty string`

```luau
local limited = ctx:View({ "Score", ScoreKey })
limited:Require("Score")   -- works
limited:Require("Player")  -- throws: not visible in this view
limited:Set("Score", ...)  -- throws: context is read-only
```

---

### `handle:Readonly()`

Creates a read-only view of this context that exposes all keys (no key restriction).

**Returns:** `Context`

**Errors:**
- `Context.Readonly: context is destroyed`

```luau
local ro = ctx:Readonly()
ro:Require("Score")  -- works
ro:Set("X", 1)       -- throws: context is read-only
```

---

### `handle:Destroy()`

Destroys this context and all child contexts (layers and views). Runs cleanup functions and `OnDestroy` callbacks in registration order. Errors from cleanup/callbacks are routed through `ErrorHandler`.

Idempotent — safe to call multiple times.

```luau
ctx:Destroy()
ctx:IsDestroyed()  -- true
```

---

### `handle:IsDestroyed()`

Returns `true` if this context has been destroyed.

**Returns:** `boolean`

---

### `handle:OnDestroy(fn)`

Registers a callback to run when this context is destroyed. If the context is already destroyed, `fn` is called on the next `Scheduler.Defer`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `fn` | `() -> ()` | Callback; errors route through `ErrorHandler` |

**Returns:** `Connection.Connection` — disconnect to unregister before destruction

**Errors:**
- `Context.OnDestroy: fn must be a function`

```luau
local conn = ctx:OnDestroy(function()
    print("context was destroyed!")
end)

-- Unregister if we no longer care:
conn:Disconnect()
```

---

## Gotchas

- **Layers shadow, not replace, parent values.** A child `Layer` with key `"X"` does not modify the parent; `parentCtx:Require("X")` still returns the parent's original value.
- **Views are read-only.** `Set`, `Provide`, and `ProvideLazy` throw on views regardless of what the source allows.
- **Lazy providers are per-context, not per-tree.** The provider is called once per context in which it is registered. A sibling layer that doesn't register the lazy provider will not see the cached value — it will walk up to the ancestor that has it.
- **Lazy provider cycles throw immediately.** If provider A calls `Require("A")` on the same context, the error `Context.Require: lazy provider cycle for key 'A'` is thrown regardless of the error policy.
- **Destroying a parent destroys all children.** Child layers and views are tracked in a `Children` list. Calling `ctx:Destroy()` recursively destroys the entire subtree.
- **`OnDestroy` on an already-destroyed context fires deferred.** The callback is scheduled via `Scheduler.Defer`, so it runs asynchronously, not inside `OnDestroy` itself.
- **Context handles are weakly stored.** The internal `contextRecords` table uses weak keys. A context handle that has been garbage-collected is treated as invalid by `IsContext`. Hold strong references to any context whose lifetime you need to control.

---

## Complete Example

```luau
local Context = require(path.to.Context)
local Store   = require(path.to.Store)

-- Typed keys for safety.
local PlayerKey = Context.Key("Player")
local ScoreKey  = Context.Key("Score")

-- Root context — shared across the whole game.
local gameCtx = Context.Root({
    [PlayerKey] = playerInstance,
})

-- Lazy-provide the score store so it is only created if actually used.
gameCtx:ProvideLazy(ScoreKey, function(_ctx)
    return Store.Value(0)
end)

-- Per-round context layer, scoped to one match.
local roundCtx = gameCtx:Layer({
    RoundId = os.time(),
}, function()
    print("Round context destroyed — cleaning up round resources.")
end)

-- A subsystem that only needs read-only access to the score.
local readCtx = roundCtx:View({ ScoreKey })

local score = readCtx:Require(ScoreKey) -- resolves from gameCtx lazy provider
score:Set(score:Get() + 10)

-- When the round ends, destroy the layer.
roundCtx:Destroy()
-- readCtx is also destroyed (it is a child of roundCtx).

-- The root context and its lazy-provided score store are still alive.
print(gameCtx:Require(ScoreKey):Get())  -- 10 — still the same store instance

gameCtx:Destroy()
```
