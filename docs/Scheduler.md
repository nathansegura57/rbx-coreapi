# Scheduler

## Purpose

`Scheduler` is the only kernel module that directly accesses Roblox scheduling, timing, and frame primitives. All other kernel modules use `Scheduler` for deferred execution, delays, cancellation, and time queries.

## Import

```luau
local Scheduler = require(path.to.Scheduler)
```

## Public API reference

```luau
Scheduler.Defer(fn: () -> ()): any?
Scheduler.Delay(seconds: number, fn: () -> ()): any?
Scheduler.Cancel(handle: any?): ()
Scheduler.Now(): number
Scheduler.OnStep(fn: (dt: number) -> ()): Connection.Connection
Scheduler.SetDriver(driver: Driver): ()
Scheduler.ResetDriver(): ()
```

## Types

```luau
export type Driver = {
    Defer: ((() -> ()) -> any)?,
    Delay: ((number, () -> ()) -> any)?,
    Cancel: ((any) -> ())?,
    Now: (() -> number)?,
    OnStep: (((number) -> ()) -> Connection.Connection)?,
}
```

## Default driver

| Function | Default implementation |
|---|---|
| `Defer` | `task.defer` |
| `Delay` | `task.delay` |
| `Cancel` | `task.cancel` |
| `Now` | `time()` |
| `OnStep` | `RunService.Heartbeat` |

## `Scheduler.Defer(fn)`

Schedules `fn` to run after the current call stack.

**Error behavior**

```text
Scheduler.Defer: fn must be a function
```

**Behavior**

- Wraps `fn` so errors are routed through `ErrorHandler` with phase `"Defer"`.
- Returns the driver handle or `nil`.
- Preserves the ordering guarantees of the active driver.

## `Scheduler.Delay(seconds, fn)`

Schedules `fn` to run after `seconds` have elapsed.

**Error behavior**

```text
Scheduler.Delay: seconds must be non-negative
Scheduler.Delay: fn must be a function
```

**Behavior**

- `seconds = 0` is valid; the callback is deferred per driver semantics, not run synchronously.
- Wraps `fn` so errors are routed through `ErrorHandler` with phase `"Delay"`.

## `Scheduler.Cancel(handle)`

Cancels a scheduled handle.

**Behavior**

- If `handle == nil`, returns immediately.
- Calls the driver's `Cancel` if available.
- Cancellation errors are routed through `ErrorHandler` with phase `"Cancel"`.

## `Scheduler.Now()`

Returns the current scheduler time in seconds.

**Behavior**

- Calls the driver's `Now`.
- Returns a `number`.
- If the driver returns a non-number, errors:

```text
Scheduler.Now: driver returned non-number
```

**Scheduler behavior**

`Now()` defaults to `time()`. Do not use `os.clock()`, `os.time()`, or `tick()` in other kernel modules.

## `Scheduler.OnStep(fn)`

Registers a per-frame callback receiving `dt`.

**Error behavior**

```text
Scheduler.OnStep: fn must be a function
Scheduler.OnStep: no step driver available
Scheduler.OnStep: driver must return Connection
```

**Behavior**

- Callback errors route through `ErrorHandler` with phase `"OnStep"`.
- Returns a `Connection`; disconnecting stops future callbacks.

## `Scheduler.SetDriver(driver)`

Installs partial overrides. Omitted fields keep defaults.

**Error behavior**

```text
Scheduler.SetDriver: driver must be a table
Scheduler.SetDriver: Defer must be a function or nil
Scheduler.SetDriver: Delay must be a function or nil
Scheduler.SetDriver: Cancel must be a function or nil
Scheduler.SetDriver: Now must be a function or nil
Scheduler.SetDriver: OnStep must be a function or nil
```

**Behavior**

- Existing scheduled callbacks are not migrated or cancelled.
- Future calls use the new driver.

## `Scheduler.ResetDriver()`

Restores the default driver captured at module load.

**Behavior**

- Does not cancel existing handles.
- Does not clear collected errors.

## Callback error handling

All scheduled callbacks are protected. Errors call `ErrorHandler.Report`. If `ErrorHandler.Report` re-throws (`"Throw"` policy), the throw propagates from the scheduled callback. `Scheduler` never reports errors thrown by `ErrorHandler.Report`.

## Not implemented

`Scheduler.SetDriver` and `Scheduler.ResetDriver` replace `FSM.SetScheduler` from prior versions. Use those instead.
