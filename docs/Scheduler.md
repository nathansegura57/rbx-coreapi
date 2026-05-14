# Scheduler API Reference

`Scheduler` is the centralized asynchronous execution and timing abstraction for CoreAPI systems.

Place this module at:

```text
ReplicatedStorage/Shared/Kernel/Scheduler
```

Every CoreAPI module that performs:

- deferred execution;
- delayed execution;
- frame stepping;
- elapsed-time measurement;
- async cleanup;
- deterministic scheduling;

should depend on `Scheduler` instead of Roblox primitives directly.

CoreAPI modules should never call:

```luau
task.defer
task.delay
task.cancel
RunService.Heartbeat
time
```

directly.

Instead, all scheduling flows through `Scheduler`.

This guarantees:

- deterministic testing;
- centralized runtime error routing;
- virtualization support;
- mockable time;
- consistent async behavior;
- implementation independence.

---

# Design Goals

`Scheduler` exists to solve four major architectural problems.

## Deterministic Testing

Roblox scheduling primitives depend on real runtime execution.

Without abstraction:

- delays depend on wall-clock time;
- deferred execution cannot be flushed manually;
- frame callbacks require real frame stepping;
- tests become flaky and nondeterministic.

`Scheduler` allows tests to replace the active runtime driver with a deterministic mock implementation.

---

## Centralized Runtime Error Routing

All scheduled callbacks route failures through `ErrorHandler`.

This means:

- async failures respect the active error policy;
- reporters observe scheduled failures consistently;
- runtime behavior remains predictable.

---

## Driver Virtualization

`Scheduler` separates:

- scheduling intent;
- scheduling implementation.

This allows runtime behavior to be swapped without changing gameplay code.

Examples:

- deterministic tests;
- replay systems;
- instrumentation;
- simulation environments;
- standalone Luau runtimes.

---

## Declarative Intent

This:

```luau
Scheduler.Delay(2, callback)
```

communicates intent directly.

Code does not need to know:

- which runtime primitive is used;
- whether execution is mocked;
- whether scheduling is virtualized;
- whether instrumentation exists.

---

# Importing

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Scheduler = require(ReplicatedStorage.Shared.Kernel.Scheduler)
```

---

# Exported Types

## `Scheduler.ScheduledCallback`

```luau
type ScheduledCallback = () -> ()
```

A callback executed asynchronously through the scheduler.

Scheduled callbacks are automatically protected through `ErrorHandler.Protect`.

---

## `Scheduler.StepCallback`

```luau
type StepCallback = (deltaTime: number) -> ()
```

A callback executed once per frame step.

| Parameter | Type | Description |
|---|---|---|
| `deltaTime` | `number` | Seconds elapsed since the previous frame. |

---

## `Scheduler.ScheduledHandle`

```luau
type ScheduledHandle = unknown
```

An opaque handle representing scheduled work.

Handles should only be:

- stored;
- passed into `Scheduler.Cancel`.

Their internal structure is driver-defined.

---

## `Scheduler.Driver`

```luau
export type Driver = {
    Defer: ((Scheduler.ScheduledCallback) -> Scheduler.ScheduledHandle?)?,
    Delay: ((number, Scheduler.ScheduledCallback) -> Scheduler.ScheduledHandle?)?,
    Cancel: ((Scheduler.ScheduledHandle?) -> ())?,
    Now: (() -> number)?,
    OnStep: ((Scheduler.StepCallback) -> Connection.Connection)?,
}
```

A partial scheduler backend implementation.

Missing fields fall back to the default Roblox-backed driver.

---

# Public Functions

# `Scheduler.Defer`

```luau
Scheduler.Defer(
    callback: Scheduler.ScheduledCallback
): Scheduler.ScheduledHandle?
```

Schedules a callback to execute after the current execution cycle.

Under the default driver, this maps to:

```luau
task.defer
```

## Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `callback` | `Scheduler.ScheduledCallback` | Yes | Callback to execute asynchronously. |

## Returns

| Type | Description |
|---|---|
| `Scheduler.ScheduledHandle?` | Optional opaque cancellation handle. |

## Runtime Error Behavior

If the callback throws:

1. the failure is captured;
2. the failure routes through `ErrorHandler`;
3. the active policy is applied.

The error does not propagate from the original `Defer` call site.

## Possible Usage Errors

```text
Scheduler.Defer: callback must be a function
```

## Example

```luau
Scheduler.Defer(function()
    print("Runs later")
end)
```

---

# `Scheduler.Delay`

```luau
Scheduler.Delay(
    seconds: number,
    callback: Scheduler.ScheduledCallback
): Scheduler.ScheduledHandle?
```

Schedules a callback to execute after a delay.

Under the default driver, this maps to:

```luau
task.delay
```

## Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `seconds` | `number` | Yes | Delay duration in seconds. Must be non-negative. |
| `callback` | `Scheduler.ScheduledCallback` | Yes | Callback executed after the delay. |

## Returns

| Type | Description |
|---|---|
| `Scheduler.ScheduledHandle?` | Optional opaque cancellation handle. |

## Possible Usage Errors

```text
Scheduler.Delay: seconds must be non-negative
Scheduler.Delay: callback must be a function
```

## Example

```luau
local timeoutHandle = Scheduler.Delay(5, function()
    print("Timed out")
end)
```

## Example: Debounce Pattern

```luau
local pendingSaveHandle = nil

local function scheduleSave()
    Scheduler.Cancel(pendingSaveHandle)

    pendingSaveHandle = Scheduler.Delay(5, function()
        saveProfile()
    end)
end
```

---

# `Scheduler.Cancel`

```luau
Scheduler.Cancel(
    handle: Scheduler.ScheduledHandle?
): ()
```

Cancels scheduled work.

Cancellation is intentionally forgiving.

## Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `handle` | `Scheduler.ScheduledHandle?` | No | Previously returned handle. |

## Behavior

Safe to call with:

- `nil`;
- expired handles;
- already-fired handles;
- already-cancelled handles.

## Example

```luau
local handle = Scheduler.Delay(10, cleanup)

Scheduler.Cancel(handle)
```

---

# `Scheduler.Now`

```luau
Scheduler.Now(): number
```

Returns the current elapsed time from the active driver.

Under the default Roblox driver, this maps to:

```luau
time()
```

## Returns

| Type | Description |
|---|---|
| `number` | Current elapsed runtime in seconds. |

## Possible Usage Errors

```text
Scheduler.Now: driver returned non-number
```

## Driver Failure Behavior

If the active driver throws:

- the failure routes through `ErrorHandler`;
- `Scheduler.Now()` returns `0` when policy allows execution to continue.

## Example

```luau
local startedAt = Scheduler.Now()

performWork()

local elapsed = Scheduler.Now() - startedAt
```

---

# `Scheduler.OnStep`

```luau
Scheduler.OnStep(
    callback: Scheduler.StepCallback
): Connection.Connection
```

Subscribes to frame-step execution.

Under the default Roblox driver, this maps to:

```luau
RunService.Heartbeat
```

## Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `callback` | `Scheduler.StepCallback` | Yes | Function executed once per frame. |

## Returns

| Type | Description |
|---|---|
| `Connection.Connection` | Disconnectable frame subscription. |

## Possible Usage Errors

```text
Scheduler.OnStep: callback must be a function
Scheduler.OnStep: no step driver available
Scheduler.OnStep: driver must return Connection
```

## Example

```luau
local connection = Scheduler.OnStep(function(deltaTime)
    print(deltaTime)
end)

connection:Disconnect()
```

## Example: Fixed-Step Simulation

```luau
local accumulatedTime = 0

Scheduler.OnStep(function(deltaTime)
    accumulatedTime += deltaTime

    while accumulatedTime >= FIXED_STEP do
        accumulatedTime -= FIXED_STEP
        simulate(FIXED_STEP)
    end
end)
```

---

# `Scheduler.SetDriver`

```luau
Scheduler.SetDriver(
    driver: Scheduler.Driver
): ()
```

Installs a custom scheduler backend.

Every field is optional.

Missing fields fall back to Roblox defaults.

## Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `driver` | `Scheduler.Driver` | Yes | Partial scheduler implementation. |

## Possible Usage Errors

```text
Scheduler.SetDriver: driver must be a table
Scheduler.SetDriver: <field> must be a function or nil
```

## Example: Partial Override

```luau
Scheduler.SetDriver({
    Now = function()
        return fakeTime
    end,
})
```

## Example: Deterministic Driver

```luau
local queuedCallbacks = {}
local currentTime = 0

Scheduler.SetDriver({
    Defer = function(callback)
        table.insert(queuedCallbacks, callback)
    end,

    Delay = function(_seconds, callback)
        table.insert(queuedCallbacks, callback)
    end,

    Cancel = function(_handle)
    end,

    Now = function()
        return currentTime
    end,
})
```

---

# `Scheduler.ResetDriver`

```luau
Scheduler.ResetDriver(): ()
```

Restores the default Roblox-backed scheduler implementation.

## Default Driver Mapping

| Scheduler API | Roblox Primitive |
|---|---|
| `Scheduler.Defer` | `task.defer` |
| `Scheduler.Delay` | `task.delay` |
| `Scheduler.Cancel` | `task.cancel` |
| `Scheduler.Now` | `time()` |
| `Scheduler.OnStep` | `RunService.Heartbeat` |

## Example

```luau
Scheduler.ResetDriver()
```

---

# Runtime Error Routing

All runtime callback failures route through `ErrorHandler`.

This applies to:

- deferred callbacks;
- delayed callbacks;
- step callbacks;
- driver failures.

Example:

```luau
ErrorHandler.SetPolicy(ErrorHandler.Policy.Warn)

Scheduler.Defer(function()
    error("Deferred failure")
end)
```

Under `Warn`, execution continues after the warning.

Under `Throw`, the report raises.

---

# Driver Behavior in Complex Cases

## Partial Drivers Inherit Missing Behavior

Drivers are behaviorally merged.

This:

```luau
Scheduler.SetDriver({
    Now = customNow,
})
```

only replaces `Now`.

All other behavior remains unchanged.

---

## `OnStep` May Not Exist Outside Roblox

Standalone Luau runtimes may not provide frame stepping.

In those environments:

```text
Scheduler.OnStep: no step driver available
```

is raised unless a custom step driver is installed.

---

## Callback Failures Are Asynchronous

This does NOT catch delayed callback failures:

```luau
pcall(function()
    Scheduler.Delay(1, function()
        error("Failure")
    end)
end)
```

because the callback executes later.

The failure routes through `ErrorHandler`, not through the original scheduling stack.

---

# Testing With MockScheduler

The recommended testing environment installs a deterministic scheduler driver.

## Example: Deferred Execution Testing

```luau
local fired = false

Scheduler.Defer(function()
    fired = true
end)

ctx.Mock:Flush()

assert(fired == true)
```

## Example: Delay Testing

```luau
local fired = false

Scheduler.Delay(3, function()
    fired = true
end)

ctx.Mock:Advance(2)
assert(fired == false)

ctx.Mock:Advance(1)
assert(fired == true)
```

---

# Gotchas

## Never Use Roblox Scheduling Primitives Directly

Bad:

```luau
task.defer(callback)
```

Good:

```luau
Scheduler.Defer(callback)
```

Direct primitive usage bypasses:

- deterministic testing;
- virtualization;
- centralized error handling;
- instrumentation.

---

## Scheduled Failures Are Not Synchronous

Errors inside scheduled callbacks happen later.

They do not propagate from the original scheduling call.

Observe failures through `ErrorHandler`.

---

## Drivers Are Global State

Installing a custom driver affects the entire runtime.

Tests should restore the previous driver after completion.

---

# Best Practices

## Treat Scheduler As Infrastructure

Gameplay systems should express scheduling intent only.

They should not know:

- whether execution is mocked;
- whether scheduling is virtualized;
- whether instrumentation exists.

---

## Prefer `OnStep` Over Direct Heartbeat Access

Good:

```luau
Scheduler.OnStep(update)
```

Avoid:

```luau
RunService.Heartbeat:Connect(update)
```

---

## Prefer Cancellation-Safe Cleanup

Good:

```luau
Scheduler.Cancel(activeTimeout)
activeTimeout = nil
```

---

# Summary

Use `Scheduler` whenever code interacts with:

- deferred execution;
- delayed execution;
- frame stepping;
- elapsed time;
- deterministic scheduling.

Use:

- `Defer` for next-cycle execution;
- `Delay` for timed execution;
- `Cancel` for cleanup-safe cancellation;
- `Now` for elapsed runtime time;
- `OnStep` for frame updates;
- `SetDriver` for virtualization and testing;
- `ResetDriver` to restore Roblox defaults.

The result is a centralized, deterministic, virtualizable scheduling layer with consistent runtime error behavior across the entire CoreAPI kernel.
