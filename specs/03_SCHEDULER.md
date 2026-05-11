# 03 — Scheduler Specification

`Scheduler` is the only kernel module allowed to directly use Roblox scheduling, timing, cancellation, or frame/update primitives.

Every other kernel module must use `Scheduler`.

## Public API

```luau
Scheduler.Defer(fn: () -> ()): any?
Scheduler.Delay(seconds: number, fn: () -> ()): any?
Scheduler.Cancel(handle: any?): ()
Scheduler.Now(): number
Scheduler.OnStep(fn: (dt: number) -> ()): Connection.Connection
Scheduler.SetDriver(driver: Driver): ()
Scheduler.ResetDriver(): ()
```

## Driver type

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

Default implementations are captured once when the module loads.

Default behavior:

- `Defer(fn)` uses Roblox `task.defer(fn)` when available.
- `Delay(seconds, fn)` uses Roblox `task.delay(seconds, fn)` when available.
- `Cancel(handle)` uses Roblox `task.cancel(handle)` when available and `handle ~= nil`.
- `Now()` uses Roblox `time()` by default.
- `OnStep(fn)` uses `RunService.Heartbeat` when available.

The chosen default time source is Roblox `time()`. Do not mix `time()`, `os.clock()`, `os.time()`, or `tick()` across modules.

Default:

```luau
time
```

If the implementation chooses a different default, every module must still call only `Scheduler.Now()`.

## Callback error handling

Every callback invoked by Scheduler must be protected.

If a scheduled callback errors, call:

```luau
ErrorHandler.Report({
    Module = "Scheduler",
    Phase = "Defer" | "Delay" | "OnStep",
    Error = err,
})
```

If `ErrorHandler.Report` throws under `"Throw"`, that throw may propagate from the scheduled callback.

Scheduler must not report errors thrown by `ErrorHandler.Report`; this prevents recursion.

## `Scheduler.Defer(fn)`

Schedules `fn` to run later.

### Validation

`fn` must be a function.

Error:

```text
Scheduler.Defer: fn must be a function
```

### Behavior

- Delegate to current driver `Defer`.
- Wrap `fn` so callback errors route through `ErrorHandler`.
- Return the driver handle, if any.
- If the driver returns no handle, return `nil`.

### Ordering

`Defer` must preserve the ordering guarantees of the active driver.

The kernel assumes only:

- deferred callbacks run after the current call stack
- callbacks scheduled earlier usually run before callbacks scheduled later under the same driver

No stronger cross-driver guarantee is required.

## `Scheduler.Delay(seconds, fn)`

Schedules `fn` after `seconds`.

### Validation

`seconds` must be a number greater than or equal to `0`.

`fn` must be a function.

Errors:

```text
Scheduler.Delay: seconds must be non-negative
Scheduler.Delay: fn must be a function
```

### Behavior

- Delegate to current driver `Delay`.
- Wrap `fn` so callback errors route through `ErrorHandler`.
- Return the driver handle, if any.
- `seconds = 0` is allowed and means delayed/deferred according to driver semantics, not synchronous execution.

## `Scheduler.Cancel(handle)`

Cancels a scheduled handle if possible.

### Parameters

```luau
handle: any?
```

### Behavior

- If `handle == nil`, return immediately.
- If current driver has `Cancel`, call it with `handle`.
- If driver cancellation errors, route through `ErrorHandler.Report` with phase `"Cancel"`.
- If driver has no `Cancel`, return with no error.

## `Scheduler.Now()`

Returns current scheduler time.

### Returns

```luau
number
```

### Behavior

- Calls current driver `Now`.
- If `Now` errors, route through `ErrorHandler.Report` and rethrow if policy throws.
- Must return a number.
- If driver `Now` returns non-number, error directly:

```text
Scheduler.Now: driver returned non-number
```

### Time semantics

`Now()` returns seconds from Roblox `time()` by default.

`os.clock()` is not the default because it is for high-precision benchmarking rather than general runtime/gameplay elapsed time.

`os.time()` is not the default because it is a Unix timestamp with one-second resolution.

`tick()` is not used.

`Now()` must be used for elapsed durations in:

- Signal replay time
- Signal sequence timing
- Store scheduler-linked timing, if any
- Task retry/backoff diagnostics
- Rule cooldown/throttle/debounce metrics
- FSM transition frames

## `Scheduler.OnStep(fn)`

Registers a per-frame/per-step callback.

### Validation

`fn` must be a function.

Error:

```text
Scheduler.OnStep: fn must be a function
```

If no step driver exists, error:

```text
Scheduler.OnStep: no step driver available
```

### Behavior

- Call current driver `OnStep`.
- The callback receives `dt`.
- Callback errors route through `ErrorHandler.Report`.
- Return a `Connection`.
- Disconnecting the connection stops future callbacks.
- If driver returns an invalid connection, error:

```text
Scheduler.OnStep: driver must return Connection
```

## `Scheduler.SetDriver(driver)`

Installs partial scheduler overrides.

### Validation

`driver` must be a table.

Fields, if supplied, must have correct types:

```luau
Defer: function?
Delay: function?
Cancel: function?
Now: function?
OnStep: function?
```

Errors:

```text
Scheduler.SetDriver: driver must be a table
Scheduler.SetDriver: Defer must be a function or nil
Scheduler.SetDriver: Delay must be a function or nil
Scheduler.SetDriver: Cancel must be a function or nil
Scheduler.SetDriver: Now must be a function or nil
Scheduler.SetDriver: OnStep must be a function or nil
```

### Behavior

- Store an active driver made from defaults plus overrides.
- Omitted fields keep defaults.
- Existing scheduled callbacks are not migrated or cancelled.
- Future calls use the new driver.

## `Scheduler.ResetDriver()`

Restores the default captured driver.

### Behavior

- Replace active driver with default driver.
- Does not cancel existing handles.
- Does not clear collected errors.
- Does not affect other modules except future Scheduler calls.
