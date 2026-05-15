# Context API Reference

`Context` is the hierarchical dependency-injection and scoped-lifetime system for CoreAPI.

Place this module at:

```text
ReplicatedStorage/Shared/Kernel/Context
```

`Context` exists to solve three major architectural problems:

- hierarchical dependency resolution;
- scoped resource ownership;
- deterministic subsystem composition.

A `Context` stores key→value pairs and allows child scopes to inherit values from ancestor scopes without explicitly wiring every dependency manually.

This allows systems to express:

> “I need access to this capability.”

instead of:

> “I need this exact object passed through five layers of constructors.”

---

# Design Goals

`Context` is intentionally:

- hierarchical;
- declarative;
- immutable-by-boundary;
- scope-oriented;
- infrastructure-focused.

The module is designed around these principles:

- **Hierarchical inheritance**: child contexts automatically inherit ancestor values.
- **Scoped ownership**: destroying a context destroys all child scopes and cleanup callbacks.
- **Typed dependency access**: `Context.Key` enables type-safe dependency retrieval.
- **Lazy dependency creation**: values may be created only when first requested.
- **View-based capability restriction**: readonly views expose only specific keys.
- **Deterministic destruction**: cleanup order and callback behavior are explicit and stable.
- **Infrastructure composability**: systems share capabilities through context instead of direct coupling.

---

# Importing

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Context = require(ReplicatedStorage.Shared.Kernel.Context)
```

---

# Core Mental Model

A `Context` forms a tree.

```text
Root Context
├─ Gameplay Layer
│  ├─ Round Layer
│  └─ Spectator View
└─ UI Layer
```

Each child:

- inherits ancestor values;
- may provide additional values;
- may shadow ancestor values;
- may own cleanup logic;
- is destroyed with its parent.

Contexts are not services.

Contexts are scoped capability containers.

---

# Exported Types

## `Context.ContextKey<T>`

```luau
type ContextKey<T> = opaque
```

An opaque typed dependency key.

Keys provide:

- collision-free lookup;
- type-safe retrieval;
- semantic identity.

Prefer keys over strings whenever possible.

---

## `Context.BaseContext<T>`

Internal recursive base type used to satisfy Luau's recursive generic limitations.

This type exists because Luau recursive generic self-references require exact generic parameter preservation.

The implementation intentionally avoids invalid recursive widening patterns such as:

```luau
Context<T> -> Context<U>
```

inside recursive definitions.

---

## `Context.Context<T>`

The public context handle type.

Represents:

- root contexts;
- layers;
- readonly views.

All context handles are opaque.

---

# Public Constructors

# `Context.Root`

```luau
Context.Root(
    values: { [any]: any }?
): Context.Context<any>
```

Creates a new root context.

This is the top-most ancestor in a context tree.

## Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `values` | `{ [any]: any }?` | No | Initial key→value pairs. |

## Returns

| Type | Description |
|---|---|
| `Context.Context<any>` | New root context. |

## Possible Usage Errors

```text
Context.Root: values must be a table
Context.Root: key must be a ContextKey or non-empty string
```

## Example

```luau
local gameContext = Context.Root({
    Player = player,
})
```

## Example: Typed Keys

```luau
local ScoreKey = Context.Key("Score")

local gameContext = Context.Root({
    [ScoreKey] = 100,
})
```

---

# `Context.Key`

```luau
Context.Key(
    name: string
): Context.ContextKey<T>
```

Creates a typed opaque dependency key.

## Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `name` | `string` | Yes | Human-readable key label. Must be non-empty. |

## Returns

| Type | Description |
|---|---|
| `Context.ContextKey<T>` | Typed dependency key. |

## Possible Usage Errors

```text
Context.Key: name must be a non-empty string
```

## Example

```luau
local InventoryStoreKey = Context.Key("InventoryStore")
```

## Why Keys Exist

String keys are vulnerable to accidental collisions.

Bad:

```luau
ctx:Set("Store", playerStore)
ctx:Set("Store", inventoryStore)
```

Typed keys solve this:

```luau
local PlayerStoreKey = Context.Key("PlayerStore")
local InventoryStoreKey = Context.Key("InventoryStore")
```

---

# `Context.IsContext`

```luau
Context.IsContext(
    value: unknown
): boolean
```

Returns whether `value` is a live context handle.

## Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `value` | `unknown` | Yes | Value to inspect. |

## Returns

| Type | Description |
|---|---|
| `boolean` | Whether the value is a live context handle. |

## Example

```luau
print(Context.IsContext(ctx))
```

---

# Lookup APIs

# `handle:Require`

```luau
context:Require(
    key: Context.ContextKey<V> | string
): V
```

Resolves a dependency from the current context or any ancestor.

Throws if the key cannot be resolved.

## Lookup Order

Resolution walks upward through ancestor contexts until:

- a concrete value is found;
- a lazy provider is resolved;
- the root is reached.

## Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `key` | `Context.ContextKey<V> | string` | Yes | Dependency key. |

## Returns

| Type | Description |
|---|---|
| `V` | Resolved dependency value. |

## Possible Usage Errors

```text
Context.Require: context is destroyed
Context.Require: source context is destroyed
Context.Require: key must be a ContextKey or non-empty string
Context.Require: missing key 'X'
Context.Require: key 'X' is not visible in this view
Context.Require: lazy provider cycle for key 'X'
Context.Require: lazy provider failed for key 'X'
```

## Example

```luau
local player = ctx:Require("Player")
```

## Example: Typed Retrieval

```luau
local StoreKey = Context.Key("Store")

local store = ctx:Require(StoreKey)
```

## Lazy Resolution Behavior

If the key maps to a lazy provider:

1. the provider executes;
2. the value is cached;
3. the provider is discarded;
4. future lookups return the cached value.

---

# `handle:Maybe`

```luau
context:Maybe(
    key: Context.ContextKey<V> | string
): V?
```

Like `Require`, but returns `nil` instead of throwing when the key is missing.

## Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `key` | `Context.ContextKey<V> | string` | Yes | Dependency key. |

## Returns

| Type | Description |
|---|---|
| `V?` | Resolved value or `nil`. |

## Possible Usage Errors

```text
Context.Maybe: context is destroyed
Context.Maybe: source context is destroyed
```

## Example

```luau
local optionalStore = ctx:Maybe("Store")

if optionalStore ~= nil then
    optionalStore:Flush()
end
```

---

# `handle:Has`

```luau
context:Has(
    key: Context.ContextKey<any> | string
): boolean
```

Returns whether the key exists anywhere in the context chain.

Unlike `Require`, this does not resolve lazy providers.

## Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `key` | `Context.ContextKey<any> | string` | Yes | Dependency key. |

## Returns

| Type | Description |
|---|---|
| `boolean` | Whether the key exists. |

## Example

```luau
if ctx:Has("Config") then
    initialize()
end
```

---

# Mutation APIs

# `handle:Set`

```luau
context:Set(
    key: Context.ContextKey<V> | string,
    value: V
): ()
```

Sets a value on the current context only.

Does not modify ancestors.

Overwrites:

- existing concrete values;
- existing lazy providers.

## Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `key` | `Context.ContextKey<V> | string` | Yes | Dependency key. |
| `value` | `V` | Yes | Value to store. |

## Possible Usage Errors

```text
Context.Set: context is destroyed
Context.Set: context is read-only
Context.Set: key must be a ContextKey or non-empty string
```

## Example

```luau
ctx:Set("RoundState", state)
```

---

# `handle:Provide`

```luau
context:Provide(
    values: { [any]: any }
): ()
```

Bulk-provides multiple values.

Validation occurs before any mutation is applied.

This guarantees partial updates cannot occur.

## Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `values` | `{ [any]: any }` | Yes | Key→value pairs. |

## Possible Usage Errors

```text
Context.Provide: context is destroyed
Context.Provide: context is read-only
Context.Provide: values must be a table
Context.Provide: key must be a ContextKey or non-empty string
```

## Example

```luau
ctx:Provide({
    Player = player,
    Round = round,
})
```

---

# `handle:ProvideLazy`

```luau
context:ProvideLazy(
    key: Context.ContextKey<V> | string,
    provider: (Context.Context<any>) -> V
): ()
```

Registers a lazy dependency provider.

The provider executes only on first lookup.

## Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `key` | `Context.ContextKey<V> | string` | Yes | Dependency key. |
| `provider` | `(Context.Context<any>) -> V` | Yes | Lazy value creator. |

## Possible Usage Errors

```text
Context.ProvideLazy: context is destroyed
Context.ProvideLazy: context is read-only
Context.ProvideLazy: key must be a ContextKey or non-empty string
Context.ProvideLazy: provider must be a function
```

## Example

```luau
ctx:ProvideLazy("ExpensiveService", function(context)
    return Service.new(context:Require("Config"))
end)
```

## Lazy Provider Semantics

Providers:

- execute at most once;
- cache results;
- are discarded after successful resolution;
- receive the requesting context.

---

# Scope APIs

# `handle:Layer`

```luau
context:Layer(
    values: { [any]: any }?,
    cleanup: (() -> ())?
): Context.Context<any>
```

Creates a child scope inheriting all ancestor values.

Layers may:

- add values;
- shadow ancestor values;
- register cleanup behavior.

## Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `values` | `{ [any]: any }?` | No | Values scoped to the child layer. |
| `cleanup` | `(() -> ())?` | No | Cleanup callback executed during destruction. |

## Returns

| Type | Description |
|---|---|
| `Context.Context<any>` | Child layer context. |

## Possible Usage Errors

```text
Context.Layer: context is destroyed
Context.Layer: values must be a table
Context.Layer: cleanup must be a function or nil
```

## Example

```luau
local roundContext = gameContext:Layer({
    RoundId = 15,
})
```

## Shadowing Behavior

Layers shadow ancestor values without mutating them.

```luau
parent:Set("Score", 10)

local child = parent:Layer({
    Score = 20,
})

print(parent:Require("Score")) -- 10
print(child:Require("Score")) -- 20
```

---

# `handle:View`

```luau
context:View(
    keys: { Context.ContextKey<any> | string }
): Context.Context<any>
```

Creates a readonly restricted child view.

Views expose only the specified keys.

## Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `keys` | `{ Context.ContextKey<any> | string }` | Yes | Visible keys. |

## Returns

| Type | Description |
|---|---|
| `Context.Context<any>` | Readonly restricted child view. |

## Possible Usage Errors

```text
Context.View: context is destroyed
Context.View: keys must be an array
Context.View: key must be a ContextKey or non-empty string
```

## Example

```luau
local readOnlyView = ctx:View({
    PlayerKey,
    ScoreKey,
})
```

## Why Views Exist

Views allow systems to expose capabilities selectively.

A subsystem may receive:

- score access;
- config access;

without receiving:

- networking access;
- admin services;
- destructive mutation APIs.

Views are capability boundaries.

---

# `handle:Readonly`

```luau
context:Readonly(): Context.Context<any>
```

Creates a readonly view exposing all keys.

## Returns

| Type | Description |
|---|---|
| `Context.Context<any>` | Readonly child view. |

## Possible Usage Errors

```text
Context.Readonly: context is destroyed
```

## Example

```luau
local readonlyContext = ctx:Readonly()
```

---

# Lifecycle APIs

# `handle:Destroy`

```luau
context:Destroy(): ()
```

Destroys the context and all descendants.

Destruction is recursive.

## Destruction Behavior

Destroying a context:

1. marks it destroyed;
2. destroys all child contexts;
3. runs cleanup callbacks;
4. runs `OnDestroy` callbacks;
5. disconnects destroy listeners.

Errors route through `ErrorHandler`.

## Idempotency

Safe to call multiple times.

Repeated calls do nothing.

## Example

```luau
ctx:Destroy()
```

## Recursive Destruction

Destroying a parent destroys:

- child layers;
- readonly views;
- all descendants recursively.

---

# `handle:IsDestroyed`

```luau
context:IsDestroyed(): boolean
```

Returns whether the context has been destroyed.

## Returns

| Type | Description |
|---|---|
| `boolean` | Whether destruction already occurred. |

## Example

```luau
if ctx:IsDestroyed() then
    return
end
```

---

# `handle:OnDestroy`

```luau
context:OnDestroy(
    callback: () -> ()
): Connection.Connection
```

Registers a destruction callback.

If already destroyed, the callback executes on the next `Scheduler.Defer`.

## Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `callback` | `() -> ()` | Yes | Destruction callback. |

## Returns

| Type | Description |
|---|---|
| `Connection.Connection` | Disconnectable callback registration. |

## Possible Usage Errors

```text
Context.OnDestroy: callback must be a function
```

## Example

```luau
local connection = ctx:OnDestroy(function()
    cleanup()
end)
```

## Deferred Already-Destroyed Behavior

Callbacks registered after destruction do not run synchronously.

They are deferred through `Scheduler.Defer`.

This avoids reentrancy hazards during destruction flows.

---

# Runtime Error Routing

Cleanup and destruction callback failures route through `ErrorHandler`.

This includes:

- layer cleanup callbacks;
- `OnDestroy` callbacks;
- deferred destruction callbacks.

This guarantees destruction behavior remains consistent with the rest of the Kernel.

---

# Complex Behavior

# Lazy Provider Cycles

This is invalid:

```luau
ctx:ProvideLazy("A", function(context)
    return context:Require("A")
end)
```

The provider recursively requests itself.

This throws immediately:

```text
Context.Require: lazy provider cycle for key 'A'
```

regardless of active error policy.

---

# Views Are Readonly

Views cannot mutate state.

These throw:

```luau
view:Set(...)
view:Provide(...)
view:ProvideLazy(...)
```

Views intentionally separate:

- observation;
- mutation.

---

# Views Restrict Visibility

Views hide inaccessible keys completely.

```luau
local restricted = ctx:View({
    "Score",
})

restricted:Require("Player")
```

throws:

```text
Context.Require: key 'Player' is not visible in this view
```

---

# Lazy Providers Are Per-Context

Providers belong to the context where they are registered.

Sibling layers do not share provider caches unless the provider exists on a shared ancestor.

---

# Context Handles Are Weakly Stored

Internal handle storage uses weak keys.

Garbage-collected handles are treated as invalid.

Hold strong references to contexts whose lifecycle must remain externally controllable.

---

# Testing Patterns

# Scoped Test Contexts

```luau
local testContext = Context.Root({
    MockStore = store,
})
```

---

# Layered Test Isolation

```luau
local isolated = sharedContext:Layer({
    TemporaryState = {},
})
```

Destroy the layer after the test completes.

---

# Restricted Capability Testing

```luau
local restricted = ctx:View({
    ScoreKey,
})
```

Useful for validating subsystem dependency boundaries.

---

# Best Practices

# Prefer Typed Keys

Good:

```luau
local InventoryStoreKey = Context.Key("InventoryStore")
```

Avoid:

```luau
"InventoryStore"
```

for infrastructure-level dependencies.

---

# Treat Contexts As Scope Boundaries

Contexts represent ownership and lifetime.

They are not global service locators.

---

# Prefer Layers Over Mutation

Good:

```luau
local roundContext = gameContext:Layer({
    RoundId = roundId,
})
```

Avoid mutating shared parent contexts for temporary state.

---

# Use Views For Capability Restriction

Views communicate:

> this subsystem may observe only these capabilities.

This is stronger and clearer than convention-based discipline.

---

# Keep Cleanup Local To Ownership

The creator of a layer should usually own its cleanup.

Good:

```luau
local layer = ctx:Layer(values, function()
    cleanupResources()
end)
```

---

# Summary

Use `Context` whenever systems need:

- scoped dependency injection;
- hierarchical capability inheritance;
- deterministic cleanup ownership;
- capability restriction;
- lazy dependency creation;
- runtime composition without direct coupling.

Use:

- `Root` to create trees;
- `Key` for typed dependencies;
- `Require` for required dependencies;
- `Maybe` for optional dependencies;
- `Layer` for scoped ownership;
- `View` for restricted readonly access;
- `ProvideLazy` for deferred creation;
- `Destroy` for deterministic recursive cleanup.

The result is a declarative, hierarchical infrastructure system that enables large CoreAPI subsystems to compose cleanly without tight coupling.
