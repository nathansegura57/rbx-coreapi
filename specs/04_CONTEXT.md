# 04 — Context Specification

`Context` is a scoped capability view.

It exists so Rule and FSM callbacks receive only the capabilities they need, for only the lifetime where those capabilities are valid.

Context is not a random mutable bag.

## Public API

```luau
Context.Root<T>(values: T): Context.Context<T>
Context.Key<T>(name: string): Context.ContextKey<T>
Context.IsContext(value: unknown): boolean
```

## Public types

```luau
export type Context<T> = {
    Require: <V>(self: Context<T>, key: ContextKey<V> | string) -> V,
    Maybe: <V>(self: Context<T>, key: ContextKey<V> | string) -> V?,
    Has: (self: Context<T>, key: ContextKey<any> | string) -> boolean,
    Set: <V>(self: Context<T>, key: ContextKey<V> | string, value: V) -> (),
    Provide: (self: Context<T>, values: { [any]: any }) -> (),
    ProvideLazy: <V>(self: Context<T>, key: ContextKey<V> | string, provider: (Context<any>) -> V) -> (),
    Layer: <L>(self: Context<T>, values: L, cleanup: (() -> ())?) -> Context<L>,
    Pick: (self: Context<T>, keys: { any }) -> Context<any>,
    View: (self: Context<T>, keys: { any }) -> Context<any>,
    Readonly: (self: Context<T>) -> Context<T>,
    Destroy: (self: Context<T>) -> (),
    IsDestroyed: (self: Context<T>) -> boolean,
    OnDestroy: (self: Context<T>, fn: () -> ()) -> Connection.Connection,
}

export type ContextKey<T> = {}
```

## Core concepts

### Root

A root context owns long-lived capabilities.

Examples:

```luau
local Root = Context.Root({
    Player = player,
    Inventory = inventory,
    Stores = {
        MenuOpen = Store.Value(false),
    },
})
```

### Layer

A layer is a child context with a parent and optional cleanup.

Layers are used for FSM mode-local capabilities.

### View / Pick

A view is read-only and exposes only selected keys from another context.

### Frame

Temporary invocation data is not stored in context. It is passed separately as `frame`.

## Handle model

Context and ContextKey handles may be opaque frozen tables.

If opaque handles are used:

- `getmetatable(ctx)` returns protected string `"Context"`
- `getmetatable(key)` returns protected string `"ContextKey"`
- assigning fields errors clearly

This is for accidental mutation prevention only.

## `Context.Root(values)`

Creates a live root context.

### Parameters

```luau
values: T
```

### Validation

`values` must be a table.

Error:

```text
Context.Root: values must be a table
```

### Behavior

1. Create a context record with:
   - no parent
   - mutable
   - not destroyed
   - empty child list
   - no cleanup
2. Shallow-copy `values` into the current layer storage.
3. Track presence separately from value so `nil` can be stored.
4. Return a context handle.

### Copy semantics

- Copy only the top-level key/value pairs.
- Do not deep clone.
- Do not recursively freeze user values.
- Preserve string keys and typed key object keys.

## `Context.Key(name)`

Creates a typed dynamic access key.

### Parameters

```luau
name: string
```

### Validation

`name` must be a non-empty string.

Error:

```text
Context.Key: name must be a non-empty string
```

### Behavior

- Create a new unique key object.
- Key identity is object identity, not `name`.
- `name` is used only for debugging and error messages.
- Keys are valid table keys.
- Keys may be frozen.

### Type usage

```luau
local PlayerKey: Context.ContextKey<Player> = Context.Key("Player")
ctx:Set(PlayerKey, player)
local player = ctx:Require(PlayerKey)
```

The type parameter is compile-time only.

## `Context.IsContext(value)`

Returns whether `value` is a context handle created by this module.

### Behavior

- Return `true` for roots, layers, and views.
- Return `false` otherwise.
- Destroyed contexts still return `true`.

## `ctx:Require(key)`

Reads a required capability.

### Parameters

```luau
key: ContextKey<T> | string
```

### Validation

- Context must not be destroyed.
- If view source is destroyed, error.
- Key must be a ContextKey or non-empty string.
- If key is not visible through this context/view, error.
- If key is missing, error.

Errors:

```text
Context.Require: context is destroyed
Context.Require: source context is destroyed
Context.Require: key must be a ContextKey or non-empty string
Context.Require: missing key '<name>'
Context.Require: key '<name>' is not visible in this view
Context.Require: lazy provider cycle for key '<name>'
```

### Lookup order

For non-view contexts:

1. current layer
2. parent layer
3. repeat until root

For views:

1. verify key is in view's visible-key set
2. resolve key from source context using normal lookup

### Nil behavior

If key is present with value `nil`, `Require` returns `nil`.

Presence and value are separate.

### Lazy behavior

If key has an unresolved lazy provider:

1. mark provider as resolving
2. call provider with current context
3. if provider returns, cache returned value even if nil
4. mark as resolved/present
5. return value

If provider errors:

- route through `ErrorHandler.Report` with:
  - `Module = "Context"`
  - `Phase = "LazyProvider"`
  - `Name = key name`
- do not cache the result
- if policy is `"Throw"`, the report throws
- if policy is not `"Throw"`, `Require` then errors:

```text
Context.Require: lazy provider failed for key '<name>'
```

## `ctx:Maybe(key)`

Reads an optional capability.

### Behavior

Same lookup as `Require`, except:

- missing key returns `nil`
- key not visible in a view returns `nil`
- present nil also returns `nil`

Use `Has` to distinguish missing from present nil.

Destroyed context and source-destroyed errors still throw.

Lazy provider behavior is the same as `Require`.

## `ctx:Has(key)`

Returns whether a key is present and visible.

### Behavior

- Returns `true` if key exists in current/parent chain or view source and is visible.
- Returns `true` even if stored value is `nil`.
- Returns `false` if missing.
- Does not resolve lazy providers.
- Returns `true` for registered lazy providers, even if unresolved.

Destroyed context errors:

```text
Context.Has: context is destroyed
Context.Has: source context is destroyed
```

## `ctx:Set(key, value)`

Sets a value in the current layer only.

### Validation

- Context must not be destroyed.
- Context must be mutable.
- Key must be valid.

Errors:

```text
Context.Set: context is destroyed
Context.Set: context is read-only
Context.Set: key must be a ContextKey or non-empty string
```

### Behavior

- Store value in current layer.
- Record presence even if value is nil.
- Replaces any lazy provider for that key in the current layer.
- Does not affect parent context.

## `ctx:Provide(values)`

Adds multiple values to the current layer.

### Parameters

```luau
values: { [any]: any }
```

### Validation

- Context must not be destroyed.
- Context must be mutable.
- `values` must be a table.
- Every key must be a ContextKey or non-empty string.

Errors:

```text
Context.Provide: context is destroyed
Context.Provide: context is read-only
Context.Provide: values must be a table
Context.Provide: key must be a ContextKey or non-empty string
```

### Behavior

- For every key/value in `values`, call the equivalent of `Set`.
- Must preserve explicit nil values if representable by the caller.
- Because normal Lua table iteration cannot observe absent keys, callers who need to provide nil through a table should use `Set`.
- Typed-keyed tables are supported:

```luau
ctx:Provide({
    [PlayerKey] = player,
})
```

## `ctx:ProvideLazy(key, provider)`

Registers a lazy provider in the current layer.

### Validation

- Context must not be destroyed.
- Context must be mutable.
- Key must be valid.
- Provider must be a function.

Errors:

```text
Context.ProvideLazy: context is destroyed
Context.ProvideLazy: context is read-only
Context.ProvideLazy: key must be a ContextKey or non-empty string
Context.ProvideLazy: provider must be a function
```

### Behavior

- Store provider in current layer.
- Provider runs on first `Require` or `Maybe`.
- Provider result is cached in the same layer.
- Nil provider results are cached and treated as present.
- Provider cycles are detected per key per context layer.
- Provider errors are handled as specified under `Require`.

## `ctx:Layer(values, cleanup?)`

Creates a child context layer.

### Parameters

```luau
values: table
cleanup: (() -> ())?
```

### Validation

- Parent context must not be destroyed.
- `values` must be a table.
- `cleanup` must be nil or function.

Errors:

```text
Context.Layer: context is destroyed
Context.Layer: values must be a table
Context.Layer: cleanup must be a function or nil
```

### Behavior

- Create mutable child context.
- Parent is current context.
- Shallow-copy values into child layer storage.
- Register child under parent for destruction.
- Store cleanup if supplied.
- Return child context.

### Read behavior

Child can read parent values.

Child writes do not affect parent.

### Destroy behavior

Destroying parent destroys child.

Destroying child does not destroy parent.

## `ctx:Pick(keys)`

Creates a read-only view of selected keys.

### Parameters

```luau
keys: { any }
```

### Validation

- Context must not be destroyed.
- `keys` must be a dense array.
- Every key must be a ContextKey or non-empty string.

Errors:

```text
Context.Pick: context is destroyed
Context.Pick: keys must be an array
Context.Pick: key must be a ContextKey or non-empty string
```

### Behavior

- Return a read-only view.
- View reads resolve values from source context at read time.
- View can only see selected keys.
- View has its own destroyed state.
- Destroying source destroys or invalidates all views.
- Destroying view does not destroy source.
- `Set`, `Provide`, and `ProvideLazy` on view error as read-only.

## `ctx:View(keys)`

Alias of `Pick`.

Exists for readability when the caller casts to a typed view.

Behavior is identical to `Pick`.

## `ctx:Readonly()`

Returns a read-only view of the same visible keys.

### Behavior

- If called on a normal context, all currently visible keys are visible.
- If called on a view, the returned view has the same visible key set.
- Reads resolve from source at read time.
- Writes error.

## `ctx:Destroy()`

Destroys a context/layer/view.

### Behavior for roots/layers

1. If already destroyed, return.
2. Mark destroyed.
3. Destroy child layers/views.
4. Run cleanup, if any.
5. Run destroy callbacks.
6. Clear stored values, lazy providers, and child list.

### Behavior for views

1. If already destroyed, return.
2. Mark view destroyed.
3. Run view destroy callbacks.
4. Do not destroy source context.

### Error handling

Cleanup and destroy callback errors route through `ErrorHandler.Report`:

```luau
Module = "Context"
Phase = "Destroy" | "OnDestroy"
```

If policy is not `"Throw"`, continue running remaining cleanup/callbacks.

If policy is `"Throw"`, error may propagate but context must already be marked destroyed.

## `ctx:IsDestroyed()`

Returns whether this context/view is destroyed.

No errors.

## `ctx:OnDestroy(fn)`

Registers a callback that runs when this context/layer/view is destroyed.

### Validation

`fn` must be a function.

Error:

```text
Context.OnDestroy: fn must be a function
```

### Behavior

- If context is live, store callback and return a connected `Connection`.
- Disconnecting the returned connection removes the callback.
- If context already destroyed, schedule `fn` through `Scheduler.Defer` and return a disconnected connection.
- Callback errors route through `ErrorHandler.Report`.

## What context must not do

Context must not own:

- reactive state behavior
- event streams
- cancellation
- mode lifecycle
- event payloads
- transition temporary data
- security or authority

Use `Store`, `Signal`, `Task.Token`, `FSM`, payload, and frame respectively.
