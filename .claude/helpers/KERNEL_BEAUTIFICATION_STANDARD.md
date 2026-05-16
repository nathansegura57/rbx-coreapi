# Kernel Beautification Standard

## Definition

Beautification means maximizing:

- semantic clarity;
- architectural inevitability;
- cognitive compression;
- type-system honesty;
- runtime predictability;
- visual skimmability.

It does not mean:

- shorter code;
- clever code;
- hiding logic in helper files;
- blindly splitting modules;
- blindly preserving current structure;
- generic abstraction for its own sake.

A beautified module should feel obvious after reading it.

The code should communicate:

- what the module owns;
- what it depends on;
- what the public API promises;
- what the high-level algorithm is;
- what state exists;
- what invariants are protected;
- what errors mean;
- how lifecycle works.

## Public APIs dominate

Use explicit public methods for public APIs.

```luau
function Signal.New<T>(): Signal<T>
    ...
end

function Signal.IsSignal(value: unknown): boolean
    ...
end
```

Avoid hiding public APIs behind local assignment patterns unless there is a specific reason.

## High-level algorithm must remain visible

Helper modules and helper functions are allowed only when they make the parent algorithm easier to understand.

Good:

```luau
function Context.Root<Values>(values: Values?): Types.Context<Values>
    Validation.ensureRootValuesAreNilOrTable(values, "Context.Root")

    local rootContextRecord = Records.createRootContextRecord()

    if values ~= nil then
        ValuesProvider.provideInitialValues(rootContextRecord, values)
    end

    return Records.createContextHandle(rootContextRecord)
end
```

Bad:

```luau
function Context.Root(values)
    return Runtime.Root(values)
end
```

The parent should not become an empty forwarding facade.

## Helpers encode invariants

Good helper names:

```luau
ensureRuleCanBeConfigured
ensureSignalCanBeFired
resolveVisibleValueFromContextChain
scheduleReplayValuesForNewListener
cancelModeTasksBecauseModeExited
```

Bad helper names:

```luau
doStuff
process
handle
check
run
helper
```

A helper should usually do one of:

- validate an invariant;
- normalize trusted input;
- perform one domain operation;
- isolate a tricky runtime boundary;
- make public API code read declaratively.

## Naming

Prefer long, specific, semantic names.

Use short names only when strongly conventional and local.

Acceptable short names:

- `i` for simple loop indices;
- `dt` for delta time;
- `x`, `y`, `z` for coordinates;
- `ok` only for a tightly scoped protected-call result.

Prefer:

```luau
local listenerConnection = signal:Connect(listener)
local contextRecord = Records.getContextRecordOrRaiseUsageError(context, "Context.Require")
```

over:

```luau
local c = signal:Connect(fn)
local rec = get(ctx)
```

## Whitespace

Whitespace is semantic hierarchy.

Separate conceptual steps with blank lines.

Dense code is not beautiful.

## Comments

Prefer self-documenting names over comments.

Use comments for:

- architectural notes;
- non-obvious Luau limitations;
- why a surprising boundary exists;
- why a cast is safe.

Do not use comments to explain unclear names.
