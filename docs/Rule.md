# Rule

## Purpose

`Rule` connects a signal source to a guarded, policy-controlled effect. It handles debounce, throttle, cooldown, concurrency admission, scheduling, retry, and metrics in a single composable unit.

## Import

```luau
local Rule = require(path.to.Rule)
```

## Public API reference

```luau
Rule.New(name: string): Rule.Rule<any, any>
Rule.IsRule(value: unknown): boolean
Rule.DefaultPolicy(): Policy
Rule.ValidatePolicy(policy: PartialPolicy): (boolean, string?)
Rule.SetTracer(fn: ((TraceEvent) -> ())?): ()
```

## Instance methods

```luau
rule:On(signal: Signal.Signal<any>): Rule.Rule<Ctx, Payload>
rule:When(guard: Guard<Ctx, Payload>): Rule.Rule<Ctx, Payload>
rule:Run(effect: Effect<Ctx, Payload>): Rule.Rule<Ctx, Payload>
rule:Policy(policy: PartialPolicy): Rule.Rule<Ctx, Payload>
rule:WithContext(ctx: Context.Context<any>): Rule.Rule<Ctx, Payload>
rule:Attach(scope: any): Rule.Rule<Ctx, Payload>
rule:Enable(ctx: Context.Context<any>?): Rule.Rule<Ctx, Payload>
rule:Disable(): ()
rule:Destroy(): ()
rule:IsEnabled(): boolean
rule:IsDestroyed(): boolean
rule:Name(): string
rule:Metrics(): Metrics
rule:ResetMetrics(): ()
```

## Types

```luau
export type RuleFrame = {
    RuleName: string,
    Now: () -> number,
    Token: Task.Token?,
}

export type Metrics = {
    Runs: number,
    Skipped: number,
    Errors: number,
    AvgMs: number,
}

export type Policy = {
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

## `Rule.New(name)`

Creates a disabled rule with default policy.

**Error behavior**

```text
Rule.New: name must be a non-empty string
```

## `Rule.IsRule(value)`

Returns `true` for any rule handle, including destroyed rules.

## `Rule.DefaultPolicy()`

Returns a clone of the default policy. Mutating the returned table does not affect the internal defaults.

**Defaults**

| Field | Default |
|---|---|
| `Concurrency` | `"Exhaust"` |
| `Capacity` | `math.huge` |
| `Overflow` | `"Drop"` |
| `Schedule` | `"Deferred"` |
| `Leading` | `true` |
| `Trailing` | `true` |
| `Once` | `false` |
| `RecheckGuardBeforeRun` | `false` |
| `CancelTasksWhenGuardFalse` | `false` |
| `Trace` | `false` |

## `Rule.ValidatePolicy(policy)`

Returns `(true, nil)` or `(false, message)`. Does not throw for invalid policy fields (only throws if `policy` is not a table).

## `Rule.SetTracer(fn?)`

Installs a global tracer. Events:

```text
Rule.Enable, Rule.Disable, Rule.Destroy
Rule.Admit, Rule.Start, Rule.Done, Rule.Error
Rule.Skip, Rule.Cancel, Rule.Once
```

Tracer errors route through `ErrorHandler` phase `"Trace"`.

## `rule:On(signal)`

Sets the source signal. Signal must be live.

**Error behavior**

```text
Rule.On: rule is destroyed
Rule.On: cannot configure while enabled
Rule.On: signal must be a live Signal
```

**Behavior**

- Does not connect the signal until `Enable`.

## `rule:When(guard)`

Sets the guard. Guard is a `Store.ReadableStore<boolean>` or a function `(ctx, payload, frame) -> boolean`.

**Behavior**

- Store guard: reads `store:Get()`. Passes only when result is exactly `true`.
- Function guard: passes only when result is exactly `true`.
- Guard errors route through `ErrorHandler` and increment `Errors`. The event is skipped unless `ErrorPolicy` is `"Throw"`.

## `rule:Run(effect)`

Sets the effect function.

**Effect signature:** `(ctx, payload, frame) -> nil | (() -> ()) | Task.Task<any>`

**Return handling**

- `nil` — synchronous success.
- function — replaces the current active disposer (previous disposer is called through `ErrorHandler`).
- `Task` — tracked async effect.
- other values — ignored as success.

## `rule:Policy(policy)`

Validates and applies a partial policy (merged with defaults, not current policy).

**Error behavior**

Errors with the message from `ValidatePolicy` if invalid. Cannot be called while enabled.

## `rule:WithContext(ctx)`

Sets an explicit context that overrides all other context sources.

**Error behavior**

```text
Rule.WithContext: ctx must be a Context
```

## `rule:Attach(scope)`

Attaches the rule to an FSM or FSM Mode. The scope enables/disables the rule at appropriate lifecycle points.

**Error behavior**

```text
Rule.Attach: scope must be an FSM or FSM Mode
```

## `rule:Enable(ctx?)`

Enables the rule. Enable is ref-counted.

**Error behavior**

```text
Rule.Enable: rule is destroyed
Rule.Enable: signal is not configured
Rule.Enable: effect is not configured
Rule.Enable: ctx must be Context
```

**Behavior**

- If `ctx` is supplied, it overrides the runtime context for this activation.
- The first call (count 0→1): connects the signal, optionally connects a guard store watcher (if `CancelTasksWhenGuardFalse`), and emits trace `Rule.Enable`.
- Subsequent calls increment the count without reconnecting.

## `rule:Disable()`

Decrements the enable ref-count. When count reaches 0:

1. Disconnects the signal.
2. Disconnects the guard watcher.
3. Cancels tracked tasks with `Task.Reason.ModeExit`.
4. Runs the active disposer through `ErrorHandler`.
5. Cancels debounce/throttle timers.
6. Clears pending payloads and concat queue.
7. Marks disabled and emits trace `Rule.Disable`.

## `rule:Destroy()`

Idempotent. Forces full disable regardless of ref-count, releases all references, and emits trace `Rule.Destroy`.

## `rule:IsEnabled()` / `rule:IsDestroyed()`

Return current lifecycle state.

## `rule:Name()`

Returns `policy.Tag` if set, otherwise the constructor name.

## `rule:Metrics()`

Returns `{ Runs, Skipped, Errors, AvgMs }`.

- `Runs` — number of times the effect started.
- `Skipped` — events that entered the rule but were not admitted.
- `Errors` — guard/effect/disposer/tracer errors.
- `AvgMs` — average effect duration in milliseconds.

## `rule:ResetMetrics()`

Zeros all counters.

## Event pipeline

When the source signal fires, the event passes through this pipeline in order:

1. Rule enabled/not-destroyed check.
2. Debounce (if configured) — resets timer; latest payload retained with presence.
3. Throttle (if configured) — leading/trailing fire rate limiting.
4. Cooldown check — skips if too soon since last admission.
5. Guard evaluation.
6. Concurrency admission.
7. Record admission time.
8. Schedule or run effect.
9. Optionally recheck guard before run (if `RecheckGuardBeforeRun`).
10. Run effect.
11. Interpret return value.
12. Once cleanup if configured.

## Concurrency modes

| Mode | Behavior |
|---|---|
| `Exhaust` | Skip if any Task in flight. |
| `Merge` | Allow up to `Capacity` parallel Tasks. Overflow must be `"Drop"`. |
| `Concat` | Queue admitted payloads; run one at a time. `Capacity` limits queue size. |
| `Switch` | Cancel all in-flight tasks with `Superseded`, then run new effect. |

## Once behavior

After the first effect starts: fully disables the rule (ref-count reset to 0), disconnects signal and timers, emits trace `Rule.Once`.

## Context resolution order

1. Explicit `WithContext` handle.
2. Most recent `Enable(ctx)` handle.
3. Default: empty `Context.Root({})`.

## Lifecycle behavior

Rules start disabled. Configuration methods (`On`, `When`, `Run`, `Policy`, `WithContext`) error if called while enabled or destroyed. `Destroy` is permanent.

## Nil behavior

Debounce and throttle retain nil payloads with presence tracking. Guard Store comparisons use exact `== true`.

## Scheduler behavior

Deferred effects use `Scheduler.Defer`. Debounce and throttle use `Scheduler.Delay`.

## Cancellation behavior

`CancelTasksWhenGuardFalse`: when a guard Store value changes to not-`true`, all in-flight tasks are cancelled with `Task.Reason.GuardFalse`.

## Not implemented

`Rule.SetScheduler`, `Rule.SetTools`, and `Rule.ResetTools` are not implemented. Use `Scheduler.SetDriver` for scheduling overrides and `Context` for shared utilities.
