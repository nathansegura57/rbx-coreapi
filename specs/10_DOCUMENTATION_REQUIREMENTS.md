# 10 — Documentation Requirements

Write public API docs for each kernel module:

```text
docs/Connection.md
docs/Scheduler.md
docs/ErrorHandler.md
docs/Context.md
docs/Signal.md
docs/Store.md
docs/Task.md
docs/Rule.md
docs/FSM.md
```

Each public doc must match the implementation and this spec exactly.

## Required sections per doc

1. Purpose
2. Import
3. Public API reference
4. Types
5. Each public function/method/property individually
6. Exact behavior
7. Error behavior
8. Lifecycle behavior
9. Nil behavior where relevant
10. Scheduler behavior where relevant
11. Cancellation behavior where relevant
12. Not implemented / intentionally omitted

## Do not include

- migration notes
- lowercase aliases
- claims about exploit-proofing
- aspirational roadmap language

## Language

Use direct implementation language.

Avoid ambiguous words when specifying behavior:

```text
could
might
maybe
probably
```

## Example style

```luau
local Signal = require(path.to.Signal)

local Hit: Signal.Signal<{ Damage: number }> = Signal.New()

Hit:Connect(function(payload)
    print(payload.Damage)
end)

Hit:Fire({ Damage = 10 })
```

## Public docs vs internal specs

Public docs are user-facing.

The spec is implementation-facing.

Public docs may be shorter, but they must not contradict or omit behavior that users can observe.
