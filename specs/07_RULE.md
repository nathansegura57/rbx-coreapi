# 07 — Rule

Rule connects signal events to guarded effects with policy.

## Public API

```luau
Rule.New(name: string): Rule<Ctx, Payload>
Rule.IsRule(value: unknown): boolean
Rule.DefaultPolicy(): Policy
Rule.ValidatePolicy(policy): (boolean, string?)
Rule.SetTracer(fn?): ()
Rule.SetScheduler(driver): ()
Rule.SetTools(tools): ()
Rule.ResetTools(): ()
```

Methods:

```luau
rule:On(signal: Signal<Payload>): Rule<Ctx, Payload>
rule:When(guard: Guard<Ctx, Payload>): Rule<Ctx, Payload>
rule:Run(effect: Effect<Ctx, Payload>): Rule<Ctx, Payload>
rule:Policy(policy: PartialPolicy): Rule<Ctx, Payload>
rule:WithContext(ctx: Context.Context<Ctx>): Rule<Ctx, Payload>
rule:Attach(scope): Rule<Ctx, Payload>
rule:Enable(ctx?): Rule<Ctx, Payload>
rule:Disable(): Rule<Ctx, Payload>
rule:Destroy(): ()
rule:IsEnabled(): boolean
rule:IsDestroyed(): boolean
rule:Name(): string
rule:Metrics(): Metrics
rule:ResetMetrics(): ()
```

## Callback shape

Rule callbacks use:

```luau
(ctx, payload, frame)
```

Frame:

```luau
{
    RuleName: string,
    Now: () -> number,
    Token: Task.Token?,
}
```

Do not pass a separate `tools` argument. Shared tools belong in context or frame.

## Guard type

```luau
type Guard<Ctx, Payload> =
    Store.Readable<boolean>
    | ((ctx: Ctx, payload: Payload, frame: RuleFrame) -> boolean)
```

Guard passes only on exactly true.

## Effect type

```luau
type Effect<Ctx, Payload> =
    (ctx: Ctx, payload: Payload, frame: RuleFrame) -> (
        nil | (() -> ()) | Task.Task<any>
    )
```

Effect return behavior:

- nil: synchronous success
- function: replaces current disposer
- Task: tracked async effect
- any other value: ignored as synchronous success

Only real Task handles count as async tasks. Use `Task.IsTask`.

## Policy

```luau
{
    Concurrency: "Exhaust" | "Merge" | "Concat" | "Switch",
    Capacity: number?,
    Overflow: "Drop" | "Latest" | "Fifo"?,

    Cooldown: number?,
    Debounce: number?,
    Throttle: number?,

    Schedule: "Immediate" | "Deferred",
    RecheckGuardBeforeRun: boolean?,
    CancelTasksWhenGuardFalse: boolean?,
    Once: boolean?,

    ErrorPolicy: "Throw" | "Warn" | "Swallow" | "Collect"?,
    Retry: RetryPolicy?,

    Trace: boolean?,
    Tag: string?,
}
```

Defaults:

```luau
Concurrency = "Exhaust"
Capacity = math.huge
Overflow = "Drop"
Schedule = "Deferred"
RecheckGuardBeforeRun = false
CancelTasksWhenGuardFalse = false
Once = false
Trace = false
```

Validate all enum strings and numbers. Unknown policy keys error.

## Lifecycle

A rule starts disabled.

Configuration methods `On`, `When`, `Run`, `Policy`, `WithContext` are only allowed while disabled and not destroyed.

`Enable(ctx?)`:

- increments enable count
- if transition from 0 to 1:
  - connects signal
  - starts guard watcher if needed
  - marks enabled
- optional ctx overrides inherited context for this rule

`Disable()`:

- decrements enable count
- if reaches 0:
  - disconnects signal
  - disconnects guard watcher
  - cancels tracked tasks with ModeExit
  - runs disposer
  - cancels timers
  - clears queues
  - marks disabled

`Destroy()`:

- idempotent
- disables completely regardless of enable count
- resets enable count to 0
- releases all references
- marks destroyed

## `On`

Requires live Signal.

Errors if missing/invalid.

## `When`

If guard is Store, must be Store.IsStore and readable boolean.

If guard is function, use it.

No duck typing.

Guard errors route through ErrorHandler and count as errors. The event is skipped unless policy throws.

## `Run`

Requires function.

## `Policy`

Validates and freezes/copies policy.

Cannot be called while enabled.

## `Attach`

Attach to scope that supports rule attachment.

Supported scopes:

- FSM mode
- FSM itself if it supports root scoped rules
- Context/Scope if implemented

If invalid scope, error. Do not silently no-op.

## Admission order

When signal fires:

1. if disabled/destroyed, ignore
2. debounce if configured
3. throttle if configured
4. cooldown check
5. guard check
6. concurrency admission
7. schedule effect according to policy
8. optional recheck before run
9. run effect
10. interpret return
11. once cleanup if configured

## Debounce

Seconds >= 0.

Every payload resets timer. Latest payload, including nil, is retained with presence flag.

Guard evaluated when timer fires.

## Throttle

Seconds > 0.

Leading/trailing behavior:

- leading payload runs immediately when window closed
- while window open, latest payload stored
- trailing emits latest payload when window closes
- nil payload supported

## Cooldown

Seconds >= 0.

Cooldown is time between admissions, not completions.

Use Scheduler.Now.

## Concurrency

### Exhaust

If any tracked Task in flight, skip new event.

### Merge

Allow up to Capacity tracked Tasks.

If capacity exceeded, apply Overflow. Preferred: Overflow for Merge only supports Drop. If you support Latest/Fifo, implement real pending queue.

### Concat

Run one effect at a time. Queue admitted payloads.

Capacity limits queued payloads.

Overflow:

- Drop: drop incoming
- Latest: replace newest queued with incoming
- Fifo: remove oldest queued, append incoming

### Switch

Cancel tracked tasks with Superseded, then run new effect.

## Error handling

- Guard errors: ErrorHandler + metrics errors + skip event.
- Sync effect errors: follow policy ErrorPolicy.
- Async Task failures: observed in Finally, metrics errors, trace.
- Disposer errors: ErrorHandler.
- Tracer errors: ErrorHandler.

## Once

After first effect successfully starts:

- fully disable rule
- reset enable count to 0
- disconnect signal/timers
- do not leave ref-count inconsistent

## Metrics

```luau
{
    Runs: number,
    Skipped: number,
    Errors: number,
    AvgMs: number,
}
```

Runs increments when effect actually starts.

Skipped increments when event admitted to rule but not run due guard/cooldown/concurrency/recheck.

Errors increments for guard/effect/task/disposer failures.

ResetMetrics sets all counters to zero.
