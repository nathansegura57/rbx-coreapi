# 00 — Kernel Scope

This rewrite is for the kernel only.

## Kernel modules

Implement only:

```text
Connection
Scheduler
ErrorHandler
Context
Signal
Store
Task
Rule
FSM
```

## Dependencies between kernel modules

Allowed dependencies:

```text
Connection -> none
Scheduler -> none
ErrorHandler -> Scheduler optional only for deferred reporting
Context -> Connection, ErrorHandler
Signal -> Connection, Scheduler, ErrorHandler
Store -> Connection, Signal, Scheduler, ErrorHandler
Task -> Connection, Scheduler, ErrorHandler
Rule -> Signal, Store, Task, Scheduler, ErrorHandler, Context
FSM -> Store, Signal, Rule, Task, Scheduler, ErrorHandler, Context
```

Avoid cyclic `require`s. If a cycle appears, extract shared types/helpers into a small internal module.

## Public API convention

Use PascalCase only.

Examples:

```luau
Signal.New()
signal:Connect()
connection:Disconnect()

Store.Value()
store:Get()
store:Set()

Task.Start()
task:Await()

Rule.New()
rule:When()

FSM.New()
fsm:Start()
mode:OnEnter()
```

No lowercase aliases.

## Error philosophy

Invalid API usage should fail fast with clear errors.

Runtime callback errors should follow `ErrorHandler` policy.

Do not silently swallow errors unless a module explicitly says that behavior is required.

## Security philosophy

The kernel may use private state, protected metatables, or frozen tables to prevent accidental mutation. None of this is security. Do not document or implement it as anti-exploit protection.

## Compatibility

No migration. No old API compatibility. No aliases for removed names.
