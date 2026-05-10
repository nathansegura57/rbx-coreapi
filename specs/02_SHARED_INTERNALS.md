# 02 — Shared Internals

These modules support the rest of the kernel.

---

# Connection

A connection represents a disposable subscription or hook.

## Public type

```luau
export type Connection = {
    Connected: boolean,
    Disconnect: (self: Connection) -> (),
}
```

## `Connection.New(disconnectFn?)`

Creates a connection.

### Parameters

```luau
disconnectFn: (() -> ())?
```

### Behavior

- New connection starts connected.
- `Connected` is true while connected.
- `Disconnect()` is idempotent.
- `disconnectFn` runs at most once.
- If `disconnectFn` errors, route error through `ErrorHandler`.
- After disconnect, `Connected` is false.
- Assigning fields to the connection errors.
- `getmetatable(connection)` returns protected string `"Connection"`.

### Required internals

Connection must be lightweight. It may use a private weak-key record table.

### Error messages

Invalid self:

```text
Connection.Disconnect: invalid connection
```

---

# Scheduler

The scheduler is the only kernel module allowed to directly use Roblox scheduling/time primitives.

## Public API

```luau
Scheduler.Defer(fn) -> handle?
Scheduler.Delay(seconds, fn) -> handle?
Scheduler.Cancel(handle) -> ()
Scheduler.Now() -> number
Scheduler.SetDriver(driver) -> ()
Scheduler.ResetDriver() -> ()
```

## Driver type

```luau
export type Driver = {
    Defer: ((() -> ()) -> any)?,
    Delay: ((number, () -> ()) -> any)?,
    Cancel: ((any) -> ())?,
    Now: (() -> number)?,
}
```

## Default behavior

- `Defer(fn)` uses Roblox `task.defer(fn)` if available.
- `Delay(seconds, fn)` uses Roblox `task.delay(seconds, fn)` if available.
- `Cancel(handle)` uses Roblox `task.cancel(handle)` if available and handle is not nil.
- `Now()` uses one chosen monotonic-ish time source consistently.

Prefer one time source for all kernel timing. Do not mix `time()` and `os.clock()` across modules.

## Validation

- `Defer` requires function.
- `Delay` requires non-negative seconds and function.
- `SetDriver` accepts partial driver overrides.
- `ResetDriver` restores defaults.

## Error behavior

Scheduler callback errors are routed through `ErrorHandler`.

---

# ErrorHandler

Centralized error policy for callback/reporting failures.

## Public API

```luau
ErrorHandler.SetPolicy(policy)
ErrorHandler.GetPolicy()
ErrorHandler.Report(info)
ErrorHandler.SetReporter(fn?)
```

## Policy type

```luau
export type Policy = "Throw" | "Warn" | "Swallow" | "Collect"
```

Default:

```luau
"Throw"
```

## Error info type

```luau
export type ErrorInfo = {
    Phase: string,
    Module: string,
    Name: string?,
    Message: string?,
    Error: unknown,
}
```

## `Report(info)`

Behavior by policy:

- `"Throw"`: raises error with clear message.
- `"Warn"`: calls `warn(...)`.
- `"Swallow"`: does nothing.
- `"Collect"`: stores error info in an internal array retrievable by debug/internal API if you decide to expose one.

If a reporter is installed, call it with the info. Reporter errors must not recurse infinitely. If reporter errors, fall back to `warn` or throw based on current policy.

Do not expose a large testing API here. Keep it minimal.
