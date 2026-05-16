# Luau Type System Rules

Use modern Luau deliberately.

Official resources:

- https://luau.org/types/
- https://luau.org/types/basic-types/
- https://luau.org/types/table-types/
- https://luau.org/types/type-refinements/
- https://luau.org/types/generics/
- https://luau.org/syntax/
- https://luau.org/library/

## Strict mode

Every production file must begin with:

```luau
--!strict
```

Do not use `--!nocheck` in Kernel source.

## `unknown` over `any`

Use `unknown` at trust boundaries.

Good:

```luau
function Signal.IsSignal(value: unknown): boolean
    return Records.valueIsLiveSignal(value)
end
```

Bad:

```luau
function Signal.IsSignal(value: any): boolean
    return value ~= nil
end
```

`any` opts out of type checking.

`unknown` forces validation before use.

## Exported type imports

Exported types must be referenced through a required module alias.

Good:

```luau
local Types = require(script._Types)

export type Signal<T> = Types.Signal<T>
```

Good in child module:

```luau
local Types = require(script.Parent._Types)

local function createRecord(): Types.SignalRecord
    ...
end
```

Bad:

```luau
export type Signal<T> = require(script._Types).Signal<T>
```

Do not inline `require(...)` in type expressions.

## Recursive generic limitation

Luau recursive generic table types must preserve exact generic arguments inside the recursive self shape.

If defining:

```luau
type MyType<A> = {
    ...
}
```

then recursive self references inside that shape must be exactly:

```luau
MyType<A>
```

not:

```luau
MyType<any>
MyType<B>
MyType<{ A }>
MyType<A & B>
MyType<A | B>
```

Even if the new type contains `A`, it is not exactly `A`.

Invalid:

```luau
type Fail<A> = {
    Map: <B>(self: Fail<A>, mapper: (A) -> B) -> Fail<B>,
    Wrap: (self: Fail<A>) -> Fail<{ A }>,
    Merge: <B>(self: Fail<A>, other: Fail<B>) -> Fail<A & B>,
}
```

For multiple parameters, all parameters must match exactly.

## Workaround: base type plus full type

Separate stable methods from generic-changing methods.

Good:

```luau
export type BasePipeline<Value> = {
    Destroy: (self: BasePipeline<Value>) -> (),
    IsDestroyed: (self: BasePipeline<Value>) -> boolean,
    Tap: (self: BasePipeline<Value>, callback: (Value) -> ()) -> BasePipeline<Value>,
}

export type Pipeline<Value> = BasePipeline<Value> & {
    Map: <NewValue>(
        self: Pipeline<Value>,
        mapper: (Value) -> NewValue
    ) -> BasePipeline<NewValue>,

    Wrap: (
        self: Pipeline<Value>
    ) -> BasePipeline<{ Value }>,
}
```

Use this pattern for handles with both:

- stable self-preserving methods;
- methods that transform the generic parameter.

Common examples:

- `Signal<T>` operators;
- `Store<T>` projections;
- task/result transformations;
- typed context views;
- any pipeline-like handle.

Do not cast around this limitation.

Do not use `<any>` as fake universal recursion.

## Enum tables

Luau can be annoying with enum-like frozen tables.

Prefer:

1. explicit literal union type;
2. explicit enum table shape;
3. explicit singleton local constants;
4. public parameters typed as the union alias;
5. validation through equality checks.

Good:

```luau
export type Concurrency = "Exhaust" | "Merge" | "Concat" | "Switch"

export type ConcurrencySet = {
    Exhaust: "Exhaust",
    Merge: "Merge",
    Concat: "Concat",
    Switch: "Switch",
}

local Exhaust: "Exhaust" = "Exhaust"
local Merge: "Merge" = "Merge"
local Concat: "Concat" = "Concat"
local Switch: "Switch" = "Switch"

local Concurrency: ConcurrencySet = table.freeze({
    Exhaust = Exhaust,
    Merge = Merge,
    Concat = Concat,
    Switch = Switch,
})
```

If Luau widens fields to `string | string | ...`, keep the explicit union alias and validation helpers rather than accepting plain `string`.

## Type refinements

Prefer clear refinements:

```luau
if typeof(value) == "string" then
    return value
end
```

and singleton equality refinements:

```luau
if policy == Policy.Throw then
    return Policy.Throw
end
```

Avoid lookup-table cleverness when it fights inference.

## Type casts

Casts should be rare.

Acceptable casts:

- after runtime validation;
- for opaque handle boundaries;
- for documented Luau limitations.

Bad:

```luau
return value :: any :: DesiredType
```

without validation.

## Preserving input types

Avoid unnecessary `<any>` when input shape can be preserved.

Prefer:

```luau
function Context.Root<Values>(values: Values): Context<Values>
    ...
end
```

over:

```luau
function Context.Root(values: { [any]: any }): Context<any>
    ...
end
```

But be honest about inference.

For dependency lookup, typed keys usually preserve value types better than arbitrary string/table shape.

Good:

```luau
local PlayerKey: Context.ContextKey<Player> = Context.Key("Player")
local ScoreKey: Context.ContextKey<number> = Context.Key("Score")

local player = context:Require(PlayerKey) -- Player
local score = context:Require(ScoreKey) -- number
```

Design around `ContextKey<Value>` for high-quality inference rather than pretending arbitrary runtime keys can always be statically known.
