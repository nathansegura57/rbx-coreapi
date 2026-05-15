# Rule API Reference

`Rule` is the declarative policy and effect-orchestration primitive for CoreAPI.

Place this module at:

```text
ReplicatedStorage/Shared/Kernel/Rule
```

A rule receives payloads, evaluates admission policy, and executes effects under deterministic concurrency and scheduling semantics.

`Rule` exists to solve architectural problems involving:

- effect orchestration;
- concurrency control;
- backpressure;
- retries;
- debouncing;
- throttling;
- task ownership;
- lifecycle cleanup;
- metrics;
- tracing;
- deterministic execution policy.

It depends on:

```text
ReplicatedStorage/Shared/Kernel/Connection
ReplicatedStorage/Shared/Kernel/ErrorHandler
ReplicatedStorage/Shared/Kernel/Scheduler
ReplicatedStorage/Shared/Kernel/Signal
ReplicatedStorage/Shared/Kernel/Task
```

---

# Design Goals

`Rule` is designed around one central idea:

> effect execution should be declarative infrastructure rather than ad-hoc callback code.

Instead of scattering:

- cooldown logic;
- debounce logic;
- retry logic;
- cancellation logic;
- queue logic;
- overflow logic;
- cleanup logic;
- tracing;
- metrics;

throughout gameplay systems, a rule centralizes those behaviors into one deterministic policy object.

---

# Core Mental Model

A rule behaves like:

```text
payload
    ↓
admission policy
    ↓
scheduling policy
    ↓
concurrency policy
    ↓
effect execution
    ↓
cleanup / tracing / metrics
```

Rules do not merely “run callbacks.”

They own:

- execution semantics;
- lifecycle;
- concurrency;
- retries;
- cancellation;
- queueing;
- tracing;
- cleanup.

---

# Importing

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Rule = require(ReplicatedStorage.Shared.Kernel.Rule)
```

---

# Relationship to Other Kernel Modules

## Relationship to `Task`

Rules internally manage asynchronous execution through `Task`.

Effects may:

- return plain values;
- return `Task.Task`;
- yield;
- be retried;
- be cancelled;
- be grouped.

Rules own the lifecycle of internally created tasks.

---

## Relationship to `Scheduler`

Scheduling semantics route through `Scheduler`.

This includes:

- deferred execution;
- delays;
- cooldown windows;
- throttling;
- retry delays;
- queue flushing.

---

## Relationship to `ErrorHandler`

Effect failures are runtime failures.

They route through `ErrorHandler`.

This ensures:

- global policy consistency;
- centralized reporting;
- deterministic runtime semantics.

Usage errors still raise immediately.

---

## Relationship to `Signal`

Rules expose reactive lifecycle signals such as:

- started;
- succeeded;
- failed;
- cancelled;
- overflowed;
- retried.

These integrate naturally with the rest of the reactive Kernel architecture.

---

# Exported Types

# `Rule.Rule<ContextValue, Payload>`

```luau
type Rule<ContextValue, Payload> = opaque
```

The primary rule handle.

A rule owns:

- configuration;
- lifecycle;
- metrics;
- active tasks;
- queued payloads;
- retry state;
- effect execution.

---

# `Rule.Policy`

```luau
type Policy = {
    Enabled: boolean,
    Concurrency: Rule.Concurrency,
    Overflow: Rule.Overflow,
    Schedule: Rule.Schedule,
    Cooldown: number,
    MaxConcurrent: number,
    MaxQueue: number,
    RetryCount: number,
    RetryDelay: number,
}
```

Defines execution behavior.

Policies are immutable snapshots internally.

---

# `Rule.PartialPolicy`

```luau
type PartialPolicy = {
    Enabled: boolean?,
    Concurrency: Rule.Concurrency?,
    Overflow: Rule.Overflow?,
    Schedule: Rule.Schedule?,
    Cooldown: number?,
    MaxConcurrent: number?,
    MaxQueue: number?,
    RetryCount: number?,
    RetryDelay: number?,
}
```

Used for partial updates.

---

# `Rule.Concurrency`

```luau
Rule.Concurrency.Serial
Rule.Concurrency.Parallel
Rule.Concurrency.Restart
Rule.Concurrency.Drop
```

Controls concurrent execution semantics.

---

# `Rule.Overflow`

```luau
Rule.Overflow.DropNewest
Rule.Overflow.DropOldest
Rule.Overflow.Reject
```

Controls queue overflow behavior.

---

# `Rule.Schedule`

```luau
Rule.Schedule.Immediate
Rule.Schedule.Deferred
Rule.Schedule.Delayed
```

Controls scheduling semantics.

---

# `Rule.RetryOptions`

```luau
type RetryOptions = {
    Count: number,
    Delay: number,
}
```

Retry configuration.

---

# `Rule.RuleFrame`

```luau
type RuleFrame = {
    Payload: any,
    Attempt: number,
    StartedAt: number,
}
```

Represents one active execution frame.

---

# `Rule.Metrics`

```luau
type Metrics = {
    Started: number,
    Succeeded: number,
    Failed: number,
    Cancelled: number,
    Retried: number,
    Overflowed: number,
}
```

Runtime metrics snapshot.

---

# `Rule.TraceEvent`

```luau
type TraceEvent = {
    Rule: string,
    Event: string,
    Payload: any,
    Time: number,
}
```

Tracing payload emitted to the active tracer.

---

# Public Constants

# `Rule.Concurrency`

Controls concurrent execution.

| Value | Meaning |
|---|---|
| `Serial` | Execute one payload at a time in arrival order. |
| `Parallel` | Allow many concurrent executions. |
| `Restart` | Cancel existing execution when a new payload arrives. |
| `Drop` | Ignore new payloads while execution is active. |

---

# `Rule.Overflow`

Controls queue overflow handling.

| Value | Meaning |
|---|---|
| `DropNewest` | Reject newest queued payload. |
| `DropOldest` | Remove oldest queued payload. |
| `Reject` | Reject enqueue entirely. |

---

# `Rule.Schedule`

Controls when effects execute.

| Value | Meaning |
|---|---|
| `Immediate` | Execute synchronously in current turn. |
| `Deferred` | Execute through `Scheduler.Defer`. |
| `Delayed` | Execute after configured delay. |

---

# Constructors

# `Rule.New`

```luau
Rule.New(
    name: string
): Rule.Rule<any, any>
```

Creates a new rule.

## Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `name` | `string` | Yes | Human-readable rule name. |

## Returns

| Type | Description |
|---|---|
| `Rule.Rule<any, any>` | New rule handle. |

## Possible Usage Errors

```text
Rule.New: name must be a non-empty string
```

## Example

```luau
local attackRule = Rule.New("Attack")
```

---

# `Rule.IsRule`

```luau
Rule.IsRule(value: unknown): boolean
```

Returns whether a value is a live rule handle.

---

# `Rule.DefaultPolicy`

```luau
Rule.DefaultPolicy(): Rule.Policy
```

Returns a fresh default policy snapshot.

## Default Values

```luau
{
    Enabled = true,
    Concurrency = Rule.Concurrency.Serial,
    Overflow = Rule.Overflow.Reject,
    Schedule = Rule.Schedule.Immediate,
    Cooldown = 0,
    MaxConcurrent = 1,
    MaxQueue = 0,
    RetryCount = 0,
    RetryDelay = 0,
}
```

---

# `Rule.ValidatePolicy`

```luau
Rule.ValidatePolicy(
    policy: Rule.PartialPolicy
): (boolean, string?)
```

Validates policy structure without mutating a rule.

Returns:

```luau
(valid, message)
```

---

# `Rule.SetTracer`

```luau
Rule.SetTracer(
    tracer: ((Rule.TraceEvent) -> ())?
): ()
```

Sets the global tracing callback.

Passing `nil` disables tracing.

## Runtime Error Behavior

Tracer failures route through `ErrorHandler`.

---

# Rule Configuration APIs

# `rule:SetPolicy`

```luau
rule:SetPolicy(
    policy: Rule.PartialPolicy
): ()
```

Applies policy updates.

## Example

```luau
rule:SetPolicy({
    Concurrency = Rule.Concurrency.Parallel,
    MaxConcurrent = 4,
})
```

---

# `rule:GetPolicy`

```luau
rule:GetPolicy(): Rule.Policy
```

Returns a cloned immutable policy snapshot.

---

# `rule:Enable`

```luau
rule:Enable(): ()
```

Enables the rule.

---

# `rule:Disable`

```luau
rule:Disable(): ()
```

Disables the rule.

Disabled rules reject new payloads.

Active tasks continue unless explicitly cancelled.

---

# `rule:IsEnabled`

```luau
rule:IsEnabled(): boolean
```

Returns whether the rule accepts new payloads.

---

# Effect APIs

# `rule:Use`

```luau
rule:Use(
    effect: (context: ContextValue, payload: Payload) -> any
): ()
```

Registers the effect callback.

## Behavior

Only one effect may be active at a time.

Replacing the effect overwrites the previous callback.

## Runtime Error Behavior

Effect failures route through `ErrorHandler`.

---

# `rule:Dispatch`

```luau
rule:Dispatch(
    context: ContextValue,
    payload: Payload
): ()
```

Submits payload execution.

Admission behavior depends on:

- enabled state;
- concurrency policy;
- queue state;
- cooldown state;
- overflow policy.

---

# `rule:DispatchDeferred`

```luau
rule:DispatchDeferred(
    context: ContextValue,
    payload: Payload
): ()
```

Equivalent to dispatching through `Scheduler.Defer`.

---

# `rule:DispatchDelayed`

```luau
rule:DispatchDelayed(
    seconds: number,
    context: ContextValue,
    payload: Payload
): ()
```

Schedules delayed dispatch.

---

# Concurrency Semantics

# Serial

```luau
Concurrency = Rule.Concurrency.Serial
```

One execution at a time.

Additional payloads queue.

---

# Parallel

```luau
Concurrency = Rule.Concurrency.Parallel
```

Many concurrent executions allowed.

`MaxConcurrent` limits active executions.

---

# Restart

```luau
Concurrency = Rule.Concurrency.Restart
```

Existing active executions are cancelled when new payloads arrive.

Useful for:

- search;
- targeting;
- latest-state workflows.

---

# Drop

```luau
Concurrency = Rule.Concurrency.Drop
```

New payloads are ignored while work is active.

Useful for:

- buttons;
- anti-spam interactions;
- cooldown actions.

---

# Queue Behavior

Rules may internally queue payloads.

Queue handling depends on:

- `MaxQueue`;
- `Overflow`;
- `Concurrency`.

---

# Retry Behavior

Rules may retry failed effects.

Retries preserve:

- payload;
- context;
- tracing;
- metrics.

Retry delays route through `Scheduler`.

---

# Metrics APIs

# `rule:GetMetrics`

```luau
rule:GetMetrics(): Rule.Metrics
```

Returns a cloned metrics snapshot.

---

# `rule:ResetMetrics`

```luau
rule:ResetMetrics(): ()
```

Resets all counters to zero.

---

# Lifecycle APIs

# `rule:Destroy`

```luau
rule:Destroy(): ()
```

Destroys the rule.

## Behavior

Destroying a rule:

1. disables admission;
2. cancels active tasks;
3. clears queues;
4. disconnects signals;
5. destroys internal resources.

Destruction is idempotent.

---

# `rule:IsDestroyed`

```luau
rule:IsDestroyed(): boolean
```

Returns whether the rule has been destroyed.

---

# Signals

Rules expose lifecycle signals.

---

# `rule:Started`

```luau
rule:Started(): Signal.Signal<Rule.RuleFrame>
```

Fires when execution begins.

---

# `rule:Succeeded`

```luau
rule:Succeeded(): Signal.Signal<Rule.RuleFrame>
```

Fires when execution succeeds.

---

# `rule:Failed`

```luau
rule:Failed(): Signal.Signal<Rule.RuleFrame>
```

Fires when execution fails.

---

# `rule:Cancelled`

```luau
rule:Cancelled(): Signal.Signal<Rule.RuleFrame>
```

Fires when execution is cancelled.

---

# `rule:Retried`

```luau
rule:Retried(): Signal.Signal<Rule.RuleFrame>
```

Fires when execution retries.

---

# `rule:Overflowed`

```luau
rule:Overflowed(): Signal.Signal<Rule.RuleFrame>
```

Fires when queue overflow occurs.

---

# Runtime Error Semantics

This is one of the most important Rule behaviors.

# Usage Errors

Usage errors raise immediately.

Examples:

- invalid policy;
- invalid concurrency enum;
- invalid queue size;
- missing effect;
- destroyed rule usage.

---

# Runtime Failures

Runtime failures route through `ErrorHandler`.

Examples:

- effect callback failures;
- tracer failures;
- async execution failures.

This keeps Rule behavior consistent with the rest of the Kernel.

---

# Scheduling Semantics

# Immediate

Runs synchronously.

---

# Deferred

Runs through `Scheduler.Defer`.

---

# Delayed

Runs after delay through `Scheduler.Delay`.

---

# Cleanup Ownership

Rules own:

- active tasks;
- retry timers;
- queued payloads;
- lifecycle signals;
- internal cleanup handlers.

Destroying the rule cleans all owned resources.

---

# Tracing

Tracing is global and optional.

Each trace event includes:

- rule name;
- event name;
- payload;
- timestamp.

Trace events are observational only.

Tracer failures never stop execution.

---

# Gotchas

# Serial Does Not Mean Immediate

Serial controls concurrency.

Scheduling still controls timing.

---

# Restart Cancels Existing Work

Do not use restart semantics for irreversible side effects.

---

# Parallel Can Grow Quickly

Unbounded parallelism can create excessive tasks.

Use `MaxConcurrent`.

---

# Retry Logic Should Be Idempotent

Effects may execute multiple times under retry policy.

---

# Disabled Rules Do Not Cancel Existing Work

Disabling only blocks future admission.

---

# Metrics Are Cumulative

Metrics persist until reset.

---

# Best Practices

# Prefer Declarative Policies

Good:

```luau
rule:SetPolicy({
    Concurrency = Rule.Concurrency.Drop,
    Cooldown = 0.2,
})
```

Avoid hand-written debounce/cooldown state machines.

---

# Use Restart For Latest-State Workflows

Examples:

- targeting;
- search;
- current selection;
- active tool.

---

# Use Drop For Spam Prevention

Examples:

- buttons;
- attack spam;
- rapid interactions.

---

# Use Serial For Ordered Effects

Examples:

- inventory updates;
- save queues;
- transactional pipelines.

---

# Use Parallel Carefully

Parallelism improves throughput but increases coordination complexity.

---

# Full Example: Attack Cooldown

```luau
local attackRule = Rule.New("Attack")

attackRule:SetPolicy({
    Concurrency = Rule.Concurrency.Drop,
    Cooldown = 0.25,
})

attackRule:Use(function(player, payload)
    dealDamage(player, payload.Target)
end)
```

---

# Full Example: Search Restart Semantics

```luau
local searchRule = Rule.New("Search")

searchRule:SetPolicy({
    Concurrency = Rule.Concurrency.Restart,
})

searchRule:Use(function(player, query)
    return performSearch(query)
end)
```

---

# Full Example: Serial Save Queue

```luau
local saveRule = Rule.New("Save")

saveRule:SetPolicy({
    Concurrency = Rule.Concurrency.Serial,
    MaxQueue = 50,
})

saveRule:Use(function(player, data)
    saveProfile(player, data)
end)
```

---

# Full Example: Metrics

```luau
local metrics = rule:GetMetrics()

print(metrics.Started)
print(metrics.Failed)
```

---

# Full Example: Tracing

```luau
Rule.SetTracer(function(event)
    print(event.Rule, event.Event)
end)
```

---

# Summary

Use `Rule` whenever systems need deterministic effect orchestration.

Use:

- policies for concurrency and scheduling;
- retries for resilience;
- queues for backpressure;
- tracing for observability;
- metrics for monitoring;
- lifecycle signals for composition.

The result is a declarative execution-control system integrated with the Kernel lifecycle, scheduling, task, signal, and runtime error semantics.
