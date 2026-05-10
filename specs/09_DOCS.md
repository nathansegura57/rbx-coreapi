# 09 — Documentation Requirements

Write concise but precise API docs for each kernel module.

Required docs:

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

Do not include:

- gameplay examples
- UI examples
- combat/inventory/economy examples
- migration notes
- old lowercase aliases
- test instructions
- claims about exploit-proofing

Each doc must include:

1. Purpose
2. Import
3. Public API reference
4. Exact behavior
5. Error behavior
6. Lifecycle behavior
7. Nil behavior where relevant
8. Scheduler behavior where relevant
9. Cancellation behavior where relevant
10. Not implemented / intentionally omitted

Use small snippets only.

Example style:

```luau
local Signal = require(path.to.Signal)

local Hit: Signal.Signal<{ Damage: number }> = Signal.New()

Hit:Connect(function(payload)
    print(payload.Damage)
end)

Hit:Fire({ Damage = 10 })
```

Avoid aspirational phrasing like:

- “could”
- “might”
- “north star”
- “eventually”
- “maybe”
- “future test”

If behavior is not implemented, say it is not implemented.

If behavior must be implemented, use MUST-level wording in docs only where useful.
