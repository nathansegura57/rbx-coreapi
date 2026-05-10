# 01 — Modern Luau Practices

Use current Luau style and features throughout the kernel.

Reference sources:

- https://luau.org/
- https://luau.org/syntax/
- https://luau.org/types/
- https://luau.org/library/
- https://luau.org/news/

## Strict mode

Every file starts with:

```luau
--!strict
```

Do not suppress type errors with broad `any` unless there is a specific reason.

## Types

Prefer exported structural types:

```luau
export type Connection = {
    Connected: boolean,
    Disconnect: (self: Connection) -> (),
}
```

Prefer generic handles:

```luau
export type Signal<T> = {
    Connect: (self: Signal<T>, listener: (T) -> ()) -> Connection.Connection,
}
```

Use `unknown` for truly unknown external values and refine before use.

Use `any` only when:
- the API intentionally accepts arbitrary callback values
- the value is passed through without inspection
- Luau cannot express the type practically

## Generic function call syntax

Do not use explicit generic type arguments at call sites.

Never write explicit generic type arguments at Luau call sites. That syntax is invalid in Luau.

Good:

```luau
local Hit: Signal.Signal<{ Damage: number }> = Signal.New()
local Count: Store.WritableStore<number> = Store.Value(0)
```

Luau infers generic function types from expected type annotations and arguments. When inference is not enough, annotate the local, parameter, return value, or exported type. Do not invent TypeScript-style generic calls.

## If-expressions

Use Luau if-expressions instead of Lua `and/or` ternary idioms.

Good:

```luau
local name = if tag ~= nil then tag else fallback
```

Bad:

```luau
local name = tag and tag or fallback
```

Reason: `a and b or c` fails when `b` is false or nil.

## Generalized iteration

Use generalized iteration when clear:

```luau
for key, value in tableValue do
    ...
end
```

Use numeric loops for performance-sensitive arrays where index access matters:

```luau
for i = 1, #array do
    local value = array[i]
end
```

## Standard library usage

Use appropriate built-ins:

### `table.clone`

Use for shallow cloning records/arrays.

```luau
local copy = table.clone(source)
```

Remember: clone is shallow and returns an unfrozen table even if the source is frozen.

### `table.freeze`

Use only for public immutable records or handles where accidental mutation should error.

Do not freeze hot-path temporary tables.

Do not claim freeze is security.

### `table.isfrozen`

Use only if needed before freezing externally supplied tables.

### `table.clear`

Use to reuse internal arrays/maps where appropriate.

```luau
table.clear(queue)
```

### `table.create`

Use for arrays with known approximate size.

```luau
local values = table.create(count)
```

### `table.move`

Use for efficient array window movement when implementing buffers/queues.

### `table.find`

Use for small arrays where clarity matters. For large membership sets, use dictionaries.

### `xpcall`

Use through `ErrorHandler`, not directly scattered across modules.

## Scheduler discipline

Only `Scheduler` directly touches Roblox `task` scheduling or time source.

Other modules call:

```luau
Scheduler.Defer(fn)
Scheduler.Delay(seconds, fn)
Scheduler.Cancel(handle)
Scheduler.Now()
```

Do not call `task.defer`, `task.delay`, `time`, or `os.clock` directly outside `Scheduler`.

## Performance practices

- Keep hot-path allocations low in `Signal:Fire`, `Store:Set`, and FSM transitions.
- Avoid freezing per-event payloads.
- Avoid cloning large arrays unless required by API isolation.
- Use arrays for ordered listener lists.
- Use dictionaries for membership and dedupe.
- Compact disconnected listeners after fire depth returns to zero.
- Do not create coroutines where a direct synchronous callback is specified.
- Do not use metatables for per-event payloads.
- Avoid string parsing on hot paths.
- Validate configuration at boundary time, not every event.

## Metatables and opacity

Opaque handles are allowed.

Preferred pattern:

- handle is a small frozen table
- private record is stored in a weak-key table
- `__index` exposes methods/properties
- `__newindex` errors clearly
- `__metatable` is a protected string

Do not overcomplicate this when a normal typed table is simpler.

## Nil handling

If an API says nil payloads or nil results are supported, track presence separately from value.

Do not use `value ~= nil` as “has value” unless nil is explicitly unsupported.
