# 03 — Context

Context is a scoped capability view.

It must not be a random mutable bag.

Context exists so Rule and FSM callbacks can receive only the capabilities they need.

## Core model

There are three public concepts:

```text
Context Root  = long-lived capability container
Context Scope = child layer with optional cleanup
Context Key<T> = typed dynamic access key
```

Callback temporary data must be passed as `frame`, not written into context.

## Public API

```luau
Context.Root(values: T): Context<T>
Context.Key(name: string): ContextKey<T>
Context.IsContext(value: unknown): boolean
```

Context methods:

```luau
ctx:Require(key: ContextKey<T> | string): T
ctx:Maybe(key: ContextKey<T> | string): T?
ctx:Has(key: ContextKey<any> | string): boolean
ctx:Set(key: ContextKey<T> | string, value: T): ()
ctx:Provide(values: { [any]: any }): ()
ctx:ProvideLazy(key: ContextKey<T> | string, provider: (ctx: Context<any>) -> T): ()
ctx:Layer(values: T, cleanup: (() -> ())?): Context<T>
ctx:Pick(keys: { any }): Context<any>
ctx:Readonly(): Context<T>
ctx:Destroy(): ()
ctx:IsDestroyed(): boolean
ctx:OnDestroy(fn: () -> ()): Connection.Connection
```

## Root creation

`Context.Root(values)` creates a live root context.

Behavior:

- Values are copied shallowly into internal storage.
- Do not deep clone values.
- Do not freeze user-provided values recursively.
- Context handle may be frozen.
- Destroying the root destroys all child layers/scopes.
- Destroying runs cleanup callbacks.
- Destroy is idempotent.

## Keys

`Context.Key(name) annotated as ContextKey<T>` creates a typed key object.

Behavior:

- Key identity is object identity, not only name.
- Key name is for debugging/error messages.
- Keys are valid table keys.
- Keys should be frozen.

Usage:

```luau
local PlayerKey: Context.ContextKey<Player> = Context.Key("Player")
ctx:Set(PlayerKey, player)
local player = ctx:Require(PlayerKey)
```

## String keys

String keys are allowed for app-level record convenience:

```luau
ctx:Require("Inventory")
```

But typed keys are preferred for reusable libraries.

## Lookup

Lookup order:

1. current context layer
2. parent context
3. repeat until root
4. if missing, `Maybe` returns nil and `Require` errors

`Require` error:

```text
Context.Require: missing key '<name>'
```

If context is destroyed:

```text
Context.Require: context is destroyed
```

## `Set`

Sets value in the current layer only.

If context is readonly, error:

```text
Context.Set: context is read-only
```

If context is destroyed, error.

## `Provide`

Adds multiple values to current layer.

String-keyed table:

```luau
ctx:Provide({
    Inventory = inventory,
    Wallet = wallet,
})
```

Typed-keyed table is allowed:

```luau
ctx:Provide({
    [PlayerKey] = player,
})
```

If readonly or destroyed, error.

## `ProvideLazy`

Registers a lazy provider in the current layer.

Behavior:

- Provider runs on first `Require`/`Maybe` for that key.
- Result is cached in the same layer.
- If provider errors, route through `ErrorHandler` and do not cache.
- If provider requires itself recursively, error clearly:

```text
Context.Require: lazy provider cycle for key '<name>'
```

## `Layer`

Creates a child context whose parent is the current context.

Behavior:

- Child can read parent values.
- Child writes do not affect parent.
- Child destruction runs its cleanup and child cleanups.
- Parent destruction destroys child.
- Cleanup errors route through `ErrorHandler`.

`Layer(values, cleanup)` is the basis for FSM mode-local context.

## `Pick`

Returns a readonly view exposing only selected keys.

Behavior:

- `Require`/`Maybe`/`Has` only see picked keys.
- Values are resolved from the source context.
- Set/Provide/ProvideLazy error.
- Destroying a view does not destroy the source context.
- If source context is destroyed, view reads error.

This is architectural access control, not security.

## `Readonly`

Returns a readonly view of the same visible keys.

## `OnDestroy`

Registers a callback that runs when this context/layer is destroyed.

Returns Connection.

If context is already destroyed, callback is scheduled through Scheduler.Defer and returned connection is disconnected.

## What context must not do

Context must not own:

- reactive state behavior: use Store
- events: use Signal
- cancellation: use Task tokens
- lifecycle mode behavior: use FSM/Scope
- event payloads: pass payload
- transition data: pass frame

## Callback convention

Rule callbacks:

```luau
(ctx, payload, frame)
```

FSM lifecycle callbacks:

```luau
(ctx, frame)
```

Update callbacks:

```luau
(ctx, dt, frame)
```

Frame is not context.
