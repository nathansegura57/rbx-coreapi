# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

CoreAPI is a Luau kernel library for Roblox — a collection of reactive/event-driven primitives. All source files live in `src/`, specs in `specs/`, and tests in `tests/`. There is no build step; files are loaded directly by Roblox's require system.

## Running tests

Tests use `tests/TestKit.luau`, which provides a self-contained suite runner with a mock scheduler, spy utilities, error capture, and trace capture. There is no external test runner — suites are run by requiring the test file in a Roblox environment or a standalone Luau runtime. Each suite returns a `SuiteReport` you can print or assert against.

```luau
local suite = TestKit.Suite("My Tests")
suite:Test("does the thing", function(ctx)
    ctx.Mock:Flush()
    ctx:Expect(value):ToBe(expected)
end)
local report = suite:Run()
```

## Architecture

### Module dependency order

Modules may only depend on modules listed above them; there must be no cyclic requires.

1. `ErrorHandler` — no deps
2. `Connection` — ErrorHandler
3. `Scheduler` — Connection, ErrorHandler
4. `Context` — Connection, Scheduler, ErrorHandler
5. `Signal` — Connection, ErrorHandler, Scheduler
6. `Store` — Connection, Scheduler, Signal, ErrorHandler
7. `Task` — Connection, Scheduler, ErrorHandler
8. `Rule` — Connection, Scheduler, ErrorHandler, Signal, Store, Task
9. `FSM` — Connection, Scheduler, ErrorHandler, Context, Signal, Store, Task, Rule

### Opaque handle pattern

Every module's public objects are opaque frozen tables backed by a weak-key `records` table. The metatable is a protected string (e.g., `"Connection"`, `"Signal"`). `__index` dispatches to methods; `__newindex` errors with `ModuleName: '<field>' is read-only`. `IsXxx(value)` checks whether a private record exists for the value.

### Error routing

- **Runtime callback errors** (listeners, subscribers, guards, effects, etc.) are reported through `ErrorHandler.Report({ Module, Phase, Name?, Error })`.
- **Invalid API usage** throws directly at the call site.
- All callback wrapping uses `ErrorHandler.Protect(fn, module, phase, name?)` — never raw `pcall + ErrorHandler.Report`. Scheduler is the sole exception (it IS the pcall layer).
- Modules expose frozen enum tables for string constants: `ErrorHandler.Policy`, `Signal.ReplayPolicy`, `Task.Status`, `Task.Backoff`, `Task.Reason`, `Rule.Concurrency`, `Rule.Overflow`, `Rule.Schedule`, `FSM.ExitOrdering`, `FSM.Deferral`. Prefer these over raw string literals.
- No aliases: `Context:View(keys)` (not `:Pick`), `Store:Get()` (not `:Peek`), `Task.Start()` (not `Task.Defer`).

### Nil-value presence

When a nil payload is a valid value (e.g., Signal fires nil, Store holds nil), presence is tracked with a record:

```luau
{ HasValue = true, Value = nil }
```

Do not use `value ~= nil` as a presence check when nil is explicitly supported.

### Scheduler isolation

`Scheduler` is the **only** module permitted to touch `task.defer`, `task.delay`, `task.cancel`, `RunService.Heartbeat`, or `time()` directly. Every other module calls `Scheduler.Now()`, `Scheduler.Defer()`, etc. Tests install a `MockScheduler` via `Scheduler.SetDriver(...)` and restore defaults with `Scheduler.ResetDriver()`.

## Luau conventions

All kernel source files start with `--!strict`. Public API uses PascalCase exclusively. No lowercase aliases.

- Annotate locals and parameters when type inference is insufficient.
- Generic type parameters are annotated on the local, not at the call site: `local s: Signal.Signal<T> = Signal.New()`.
- Use `if cond then a else b` expressions, never `a and b or c` ternary.
- Use generalized iteration (`for k, v in t`) for maps; use numeric `for` loops for dense arrays when order, holes, or packed-n fields matter.
- `table.unpack` with explicit bounds: `table.unpack(args, 1, args.n)`.
- `time()` is the default elapsed-time source. Do not use `tick()`. Use `os.clock()` only for benchmarking, `os.time()` only for Unix timestamps.

## Spec files

`specs/` contains authoritative implementation specs. When implementing or modifying any module, the spec for that module is the ground truth for behavior, error messages, and edge cases. `specs/11_IMPLEMENTATION_CHECKLIST.md` tracks what each module must implement.

## Documentation

Public user-facing docs go in `docs/` (one file per module). Docs must match the implementation exactly. Do not include migration notes, security claims, or aspirational language. See `specs/10_DOCUMENTATION_REQUIREMENTS.md` for required sections.
