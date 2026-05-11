# 08 — Rule Specification

`Rule` connects signal events to guarded effects with policy.

Conceptual pipeline:

```text
Signal payload -> debounce/throttle -> cooldown -> guard -> concurrency admission -> scheduling -> effect -> return handling
```

## Public API

```luau
Rule.New<Ctx, Payload>(name: string): Rule.Rule<Ctx, Payload>
Rule.IsRule(value: unknown): boolean
Rule.DefaultPolicy(): Policy
Rule.ValidatePolicy(policy: PartialPolicy): (boolean, string?)
Rule.SetTracer(fn: ((TraceEvent) -> ())?): ()
```

## Methods

```luau
rule:On(signal: Signal.Signal<Payload>): Rule.Rule<Ctx, Payload>
rule:When(guard: Guard<Ctx, Payload>): Rule.Rule<Ctx, Payload>
rule:Run(effect: Effect<Ctx, Payload>): Rule.Rule<Ctx, Payload>
rule:Policy(policy: PartialPolicy): Rule.Rule<Ctx, Payload>
rule:WithContext(ctx: Context.Context<Ctx>): Rule.Rule<Ctx, Payload>
rule:Attach(scope: any): Rule.Rule<Ctx, Payload>
rule:Enable(ctx: Context.Context<Ctx>?): Rule.Rule<Ctx, Payload>
rule:Disable(): Rule.Rule<Ctx, Payload>
rule:Destroy(): ()
rule:IsEnabled(): boolean
rule:IsDestroyed(): boolean
rule:Name(): string
rule:Metrics(): Metrics
rule:ResetMetrics(): ()
```

## Not implemented

Do not implement:

```luau
Rule.SetScheduler
Rule.SetTools
Rule.ResetTools
```

Use `Scheduler.SetDriver`.

Use Context and frame for shared utilities.

## Callback shape

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

`Token` is present only when an effect is running inside a Task-managed path that supplies one. Rule itself does not invent cancellation tokens for synchronous effects.

## Guard type

```luau
type Guard<Ctx, Payload> =
    Store.ReadableStore<boolean>
    | ((ctx: Ctx, payload: Payload, frame: RuleFrame) -> boolean)
```

Guard passes only when result is exactly `true`.

Truthy non-true values fail.

## Effect type

```luau
type Effect<Ctx, Payload> =
    (ctx: Ctx, payload: Payload, frame: RuleFrame) -> (
        nil | (() -> ()) | Task.Task<any>
    )
```

Return handling:

- `nil`: synchronous success
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
    Leading: boolean?,
    Trailing: boolean?,

    Schedule: "Immediate" | "Deferred",
    RecheckGuardBeforeRun: boolean?,
    CancelTasksWhenGuardFalse: boolean?,
    Once: boolean?,

    ErrorPolicy: "Throw" | "Warn" | "Swallow" | "Collect"?,
    Retry: Task.RetryOptions?,

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
Leading = true
Trailing = true
```

Validation:

- unknown keys error
- enum strings exact PascalCase
- Capacity positive number or math.huge
- Cooldown/Debounce >= 0
- Throttle > 0 if supplied
- Leading/Trailing booleans
- Retry validates with Task.Retry rules
- Merge supports only Overflow `"Drop"`; other overflow values with Merge are validation errors

## Lifecycle

A rule starts disabled.

Configuration methods allowed only while disabled and not destroyed:

```luau
On
When
Run
Policy
WithContext
```

`Enable` is ref-counted.

`Destroy` permanently destroys.

## `Rule.New(name)`

### Validation

`name` non-empty string.

Error:

```text
Rule.New: name must be a non-empty string
```

### Behavior

- create disabled rule
- default policy
- no signal/guard/effect/context
- metrics zero

## `Rule.IsRule(value)`

Returns true for rule handles created by this module, including destroyed rules.

## `Rule.DefaultPolicy()`

Returns clone of default policy.

Caller mutation must not affect internal defaults.

## `Rule.ValidatePolicy(policy)`

Returns:

```luau
ok: boolean, message: string?
```

Does not throw for validation failure unless `policy` itself is not a table; preferred still return false for all invalid inputs.

`Policy` method uses this validation and errors with returned message.

## `Rule.SetTracer(fn?)`

Installs global tracer.

Tracer errors route through ErrorHandler phase `"Trace"`.

Trace events include:

```text
Rule.Enable
Rule.Disable
Rule.Destroy
Rule.Admit
Rule.Start
Rule.Done
Rule.Error
Rule.Skip
Rule.Cancel
Rule.Once
```

## `rule:On(signal)`

Sets source signal.

### Validation

- rule live
- rule disabled
- signal live Signal

Errors:

```text
Rule.On: rule is destroyed
Rule.On: cannot configure while enabled
Rule.On: signal must be a live Signal
```

### Behavior

Stores signal. Does not connect until Enable.

## `rule:When(guard)`

Sets guard.

### Validation

- rule live/disabled
- guard live Store or function

No duck typing.

Errors:

```text
Rule.When: guard must be a Store or function
```

### Behavior

- Store guard reads `guard:Get()` and passes only exactly true.
- Function guard called with `(ctx, payload, frame)`.
- Guard errors route through ErrorHandler, increment Errors, and skip event unless ErrorPolicy throws.

## `rule:Run(effect)`

Sets effect.

### Validation

Effect must be function.

## `rule:Policy(policy)`

Validates, merges with defaults/current? Normative: policy replaces previous policy by merging defaults with supplied partial.

Behavior:

- cannot be called while enabled
- unknown keys error
- store frozen copy

## `rule:WithContext(ctx)`

Sets explicit rule context.

### Validation

ctx must be Context.

Cannot be called while enabled.

If absent, rule uses context inherited from attached scope or Enable(ctx).

## `rule:Attach(scope)`

Supported scopes:

- FSM
- FSM Mode

Invalid scope errors.

Attach does not enable immediately unless scope semantics do so. FSM mode enables attached rules on mode enter.

## `rule:Enable(ctx?)`

### Validation

- rule not destroyed
- signal configured
- effect configured
- ctx, if supplied, Context

Errors:

```text
Rule.Enable: rule is destroyed
Rule.Enable: signal is not configured
Rule.Enable: effect is not configured
Rule.Enable: ctx must be Context
```

### Behavior

- increment enable count
- if ctx supplied, set runtime context override
- if count from 0 to 1:
  - connect signal
  - connect guard watcher if CancelTasksWhenGuardFalse and guard is Store
  - mark enabled
  - trace Rule.Enable
- return rule

## `rule:Disable()`

### Behavior

- if enable count 0, no-op
- decrement count
- if still > 0, remain enabled
- if reaches 0:
  - disconnect signal
  - disconnect guard watcher
  - cancel tracked tasks with Task.Reason.ModeExit
  - run disposer through ErrorHandler
  - cancel debounce/throttle timers
  - clear pending payload presence
  - clear concat queue
  - mark disabled
  - trace Rule.Disable

## `rule:Destroy()`

Idempotent.

- fully disable regardless of enable count
- reset enable count 0
- release references
- mark destroyed
- trace Rule.Destroy

## Admission order

When source signal fires:

1. if disabled/destroyed, ignore
2. apply debounce if configured
3. apply throttle if configured
4. check cooldown
5. evaluate guard
6. apply concurrency policy
7. record admission time
8. schedule or run effect according to Schedule
9. optionally recheck guard before run
10. run effect
11. interpret return
12. once cleanup if configured

## Debounce

Seconds >= 0.

Every payload resets timer.

Latest payload including nil retained with presence.

Guard evaluated when timer fires.

## Throttle

Seconds > 0.

Options from policy: Leading/Trailing default true/true.

Nil trailing payloads supported with presence flag.

## Cooldown

Time between admissions, not completions.

Uses `Scheduler.Now()`.

Skipped cooldown increments Skipped.

## Concurrency

### Exhaust

If any tracked Task in flight, skip.

### Merge

Allow up to Capacity tracked Tasks.

Overflow must be Drop.

### Concat

Run one effect at a time.

Queue admitted payloads.

Capacity limits queued payload count.

Overflow:
- Drop incoming
- Latest replaces newest queued
- Fifo removes oldest queued and appends incoming

### Switch

Cancel tracked tasks with `Task.Reason.Superseded`, then run new effect.

Only Task returns are cancellable/tracked.

## Effect execution

Frame created per run:

```luau
{
    RuleName = rule:Name(),
    Now = Scheduler.Now,
    Token = nil,
}
```

Effect errors follow `ErrorPolicy`.

If Retry policy exists, wrap effect execution with `Task.Retry` and track returned retry task.

Runs metric increments when effect actually starts.

## Return handling

Function return:

- call previous disposer through ErrorHandler
- store new disposer
- concat may proceed immediately

Task return:

- track in-flight
- on Finally:
  - remove from in-flight
  - if Errored/Cancelled, metrics errors and trace error
  - concat drains next
- Task failures do not throw through original signal fire.

Other return:

- ignored success

## Once

After first effect successfully starts:

- fully disable rule
- reset enable count to 0
- disconnect signal/timers
- trace Rule.Once

No inconsistent ref count allowed.

## Metrics

```luau
{
    Runs: number,
    Skipped: number,
    Errors: number,
    AvgMs: number,
}
```

- Runs increments when effect starts.
- Skipped increments when event enters rule but does not run due to guard/cooldown/concurrency/recheck.
- Errors increments for guard/effect/task/disposer/tracer-related rule failures.
- AvgMs = total run duration / Runs.
- ResetMetrics zeros all counters.

## `rule:IsEnabled()`

Returns enabled state.

## `rule:IsDestroyed()`

Returns destroyed state.

## `rule:Name()`

Returns policy Tag if present else constructor name.

## Context resolution

At effect time, context priority:

1. explicit `WithContext`
2. most recent `Enable(ctx)`
3. inherited attached scope context

If none exists, use empty Context root or error? Normative: error on Enable if no context can be resolved only when callbacks need ctx is impossible to know. Therefore provide an empty Context.Root({}) by default for unattached/manual rules.
