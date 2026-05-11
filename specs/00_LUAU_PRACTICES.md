# 00 — Luau Baseline

All kernel source files use:

```luau
--!strict
```

## Type modes

Strict mode is required for kernel implementation files.

Use exported structural types for public module types.

```luau
export type Connection = {
    Connected: boolean,
    Disconnect: (self: Connection) -> (),
}
```

Use `any` only when a value is intentionally opaque or passed through without inspection.

Use `unknown` for external values that must be refined before use.

## Generic usage

Luau does not use TypeScript-style call-site generic syntax.

Do not write:

```luau
local Hit = Signal.New<{ Damage: number }>()
```

Write:

```luau
local Hit: Signal.Signal<{ Damage: number }> = Signal.New()
```

Annotate locals, function parameters, return values, and exported types when inference is not enough.

## Type construction

Use structural table types.

Use union types for optional values:

```luau
number?
number | nil
```

Use intersections only when representing an overloaded or combined structural API.

Use `typeof(expr)` in type aliases when a runtime value's type should be reused without evaluating it at runtime.

## Type refinements

Runtime validation narrows `unknown` values before use.

```luau
if type(value) == "function" then
    value()
end
```

Use `typeof` for Roblox datatypes and host objects.

```luau
if typeof(signal) == "RBXScriptSignal" then
    ...
end
```

## If-expressions

Use Luau if-expressions for value selection.

```luau
local label = if tag ~= nil then tag else fallback
```

Do not use `a and b or c` to simulate ternary behavior.

## Iteration

Use generalized iteration for maps when order is irrelevant.

```luau
for key, value in object do
    ...
end
```

Use numeric loops for arrays when:

- order matters
- nil slots may exist
- an explicit `n` field must be honored
- dense-array validation is required
- hot-path allocation/performance matters

```luau
for index = 1, count do
    local value = values[index]
end
```

Do not use `ipairs` when holes or explicit `n` must be preserved.

## Table library

Use `table.clone` for shallow copies.

Use `table.clear` to reuse internal tables.

Use `table.create` for preallocating array storage.

Use `table.move` for queue/window shifts.

Use `table.freeze` only for immutable public records or opaque handles where accidental mutation should error.

`table.freeze` freezes the table in place. It does not copy the table and does not freeze nested keys or values.

`table.clone` returns a shallow copy and the copy is not frozen even if the source was frozen.

`table.unpack` does not automatically honor `table.pack(...).n`; pass explicit bounds:

```luau
table.unpack(args, 1, args.n)
```

## Time functions

Default runtime elapsed-time source:

```luau
time()
```

Use `time()` for scheduler/runtime/gameplay elapsed time.

Use `os.clock()` only for benchmarking and performance measurement drivers.

Use `os.time()` only for Unix timestamps.

`Scheduler.Now()` defaults to `time()` and all kernel modules use `Scheduler.Now()` instead of calling time functions directly.

## Debug library

Use `debug.traceback` only when constructing error diagnostics.

Use `debug.info` only for diagnostics and tests. Do not put it on hot paths unless explicitly measured.

## Opaque handles

Opaque handles are permitted when they simplify invariants.

A handle may be:

- a frozen table
- backed by weak-key private records
- protected by a metatable string
- read-only through `__newindex`

Opaque handles are not a security boundary.

## Runtime callback errors

Runtime callback errors are reported through `ErrorHandler.Report`.

Callback categories include:

- signal listeners
- store subscribers
- derived store compute functions
- task finally handlers
- token cancellation handlers
- rule guards
- rule effects
- rule disposers
- mode lifecycle callbacks
- mode providers
- scheduler callbacks
- tracer callbacks
- context lazy providers
- context cleanup callbacks

## Invalid API usage

Invalid API usage throws directly.

Examples:

```luau
Signal.After(-1)
Store.Derive(nil, {})
Task.Sleep(-1)
Rule.New("")
FSM.New(nil)
```

## Nil support

If the API says a nil value is supported, presence is tracked separately.

Do not use `value ~= nil` as presence.

Use internal records such as:

```luau
{
    HasValue = true,
    Value = nil,
}
```
