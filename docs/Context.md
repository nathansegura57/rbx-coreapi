# Context

## Purpose

`Context` is a scoped capability view. It passes structured, lifetime-scoped dependencies into Rule and FSM callbacks without exposing the full global state.

## Import

```luau
local Context = require(path.to.Context)
```

## Public API reference

```luau
Context.Root<T>(values: T): Context.Context<T>
Context.Key<T>(name: string): Context.ContextKey<T>
Context.IsContext(value: unknown): boolean
```

## Types

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

## `Context.Root(values)`

Creates a root context from a plain table.

**Behavior**

- `values` becomes the initial key-value store.
- Root contexts own long-lived capabilities.
- Destroying the root destroys all child layers.

## `Context.Key(name)`

Creates a typed context key.

**Error behavior**

```text
Context.Key: name must be a non-empty string
```

**Behavior**

- Keys are opaque handles that index values within a context.
- String keys are also accepted by all context methods.

## `Context.IsContext(value)`

Returns `true` for any context handle created by this module, including destroyed contexts.

## `ctx:Require(key)`

Returns the value for `key`.

**Error behavior**

Errors if the key is not present in this context or any ancestor.

## `ctx:Maybe(key)`

Returns the value for `key` or `nil` if absent. Does not error.

## `ctx:Has(key)`

Returns `true` if `key` is present in this context or any ancestor.

## `ctx:Set(key, value)`

Writes a value into this context for `key`.

**Error behavior**

Errors if the context is destroyed or read-only.

## `ctx:Provide(values)`

Writes multiple key-value pairs at once.

## `ctx:ProvideLazy(key, provider)`

Registers a lazy provider for `key`. The provider is called the first time `key` is required.

**Behavior**

- Provider is called with the context as argument.
- Provider result is cached; subsequent requires return the cached value.
- Cycle detection errors if the provider calls `Require` on the same key.

## `ctx:Layer(values, cleanup?)`

Creates a child context with additional values and an optional cleanup function.

**Behavior**

- Child context inherits all values from the parent.
- Values in `values` shadow parent values for the same keys.
- `cleanup` runs when `ctx:Destroy()` is called on the layer.
- Destroying the parent does not automatically destroy child layers. Destroying the child does not destroy the parent.

**Nil behavior**

Nil values in `values` are stored and shadow parent values.

## `ctx:Pick(keys)` / `ctx:View(keys)`

Create read-only restricted views exposing only the specified keys.

**Behavior**

- `Pick` and `View` expose only the listed keys.
- Assignment errors on views.
- Destroying a view does not destroy the source.
- Destroying the source destroys or invalidates the view.

## `ctx:Readonly()`

Returns a read-only view of the context. All keys from the source are visible.

## `ctx:Destroy()`

Destroys the context.

**Behavior**

- Runs the layer cleanup if one was supplied.
- Fires all `OnDestroy` callbacks.
- Marks the context destroyed.
- Idempotent.

## `ctx:IsDestroyed()`

Returns `true` after `Destroy` has been called.

## `ctx:OnDestroy(fn)`

Registers a callback to run when the context is destroyed.

**Behavior**

- Returns a `Connection` that can be used to unregister.
- If the context is already destroyed, the callback is scheduled through `Scheduler.Defer`.

## Lifecycle behavior

Root contexts live until explicitly destroyed. Layers are child resources and should be destroyed when the associated scope (e.g. FSM mode activation) ends.

## Nil behavior

Nil values may be stored and retrieved. Presence is tracked separately from value.

## Lazy provider behavior

Lazy providers may return nil. Returning nil caches nil and subsequent calls return nil without re-invoking the provider. Cycle detection prevents infinite recursion.

## Not implemented

Context does not support two-way binding, reactive updates, or change notifications.
