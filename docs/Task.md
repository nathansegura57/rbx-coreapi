# Task

## Purpose

`Task` wraps cancellable async work. A task is a handle around a Luau coroutine with cooperative cancellation, status tracking, finally handlers, combinators, retries, timeouts, and groups.

## Import

```luau
local Task = require(path.to.Task)
```

## Public API reference

```luau
Task.Start<T>(fn: (token: Task.Token) -> T, opts: TaskOptions?): Task.Task<T>
Task.Defer<T>(fn: (token: Task.Token) -> T, opts: TaskOptions?): Task.Task<T>
Task.Delay<T>(seconds: number, fn: (() -> T)?): Task.Task<T?>
Task.Sleep(seconds: number, token: Task.Token?): (boolean, string?)
Task.Resolved<T>(value: T): Task.Task<T>
Task.Rejected(errorValue: unknown): Task.Task<never>
Task.Cancelled(reason: string?): Task.Task<never>
Task.Timeout<T>(inner: Task.Task<T> | (() -> Task.Task<T>), seconds: number, reason: string?): Task.Task<T>
Task.Retry<T>(makeTask: (token: Task.Token) -> T | Task.Task<T>, opts: RetryOptions): Task.Task<T>
Task.All(tasks: { Task.Task<any> }): Task.Task<{ any }>
Task.Race(tasks: { Task.Task<any> }): Task.Task<any>
Task.Any(tasks: { Task.Task<any> }): Task.Task<any>
Task.AllSettled(tasks: { Task.Task<any> }): Task.Task<{ SettledResult }>
Task.FromRoblox(rbxSignal: RBXScriptSignal, untilSignal: RBXScriptSignal?): Task.Task<{ any }?>
Task.Group(opts: GroupOptions?): Task.TaskGroup
Task.IsTask(value: unknown): boolean
Task.IsToken(value: unknown): boolean
Task.IsGroup(value: unknown): boolean
Task.SetTracer(fn: ((TraceEvent) -> ())?): ()
Task.Reason: { [string]: string }
```

## Types

```luau
export type Status = "Pending" | "Fulfilled" | "Cancelled" | "Errored"

export type Task<T> = {
    Token: (self: Task<T>) -> Token,
    Cancel: (self: Task<T>, reason: string?) -> (),
    Status: (self: Task<T>) -> Status,
    IsPending: (self: Task<T>) -> boolean,
    IsFulfilled: (self: Task<T>) -> boolean,
    IsCancelled: (self: Task<T>) -> boolean,
    IsErrored: (self: Task<T>) -> boolean,
    IsDone: (self: Task<T>) -> boolean,
    Finally: (self: Task<T>, fn: (status: Status, value: unknown?) -> ()) -> Task<T>,
    Await: (self: Task<T>, token: Token?) -> (boolean, T | unknown),
    Unwrap: (self: Task<T>, token: Token?) -> T,
    Result: (self: Task<T>) -> (boolean, T?),
    Error: (self: Task<T>) -> (boolean, unknown?),
    Name: (self: Task<T>) -> string?,
}

export type Token = {
    Cancelled: (self: Token) -> boolean,
    Reason: (self: Token) -> string?,
    OnCancel: (self: Token, fn: (reason: string?) -> ()) -> Connection.Connection,
}

export type TaskGroup = {
    Add: (self: TaskGroup, task: Task<any>) -> TaskGroup,
    Start: (self: TaskGroup, fn: (token: Token) -> any, opts: TaskOptions?) -> Task<any>,
    CancelAll: (self: TaskGroup, reason: string?) -> (),
    JoinAll: (self: TaskGroup) -> Task<nil>,
    Race: (self: TaskGroup) -> Task<any>,
    Destroy: (self: TaskGroup, reason: string?) -> (),
    Size: (self: TaskGroup) -> number,
    Name: (self: TaskGroup) -> string?,
}

export type TaskOptions = { Name: string? }

export type RetryOptions = {
    Count: number,
    Backoff: "Fixed" | "Expo",
    Base: number,
    Jitter: number?,
}

export type SettledResult = {
    Status: Status,
    Value: unknown?,
    Error: unknown?,
    Reason: string?,
}

export type TraceEvent = {
    Event: string,
    Name: string?,
    Status: Status?,
}
```

## `Task.Reason`

Frozen table of standard cancellation reason strings:

```luau
Task.Reason.ModeExit   -- FSM mode exited
Task.Reason.GuardFalse -- guard became false
Task.Reason.Superseded -- replaced by newer work
Task.Reason.Timeout    -- operation timed out
Task.Reason.User       -- explicit cancel call
Task.Reason.Shutdown   -- system shutdown
Task.Reason.Capacity   -- queue capacity exceeded
```

## `Task.Start(fn, opts?)` / `Task.Defer(fn, opts?)`

Creates and starts a task. `Defer` is an alias for `Start` provided for readability.

**Error behavior**

```text
Task.Start: fn must be a function
Task.Start: opts must be a table or nil
Task.Start: Name must be a string or nil
```

**Behavior**

- Creates a pending task and a cancellation token.
- Schedules the coroutine via `Scheduler.Defer`.
- `fn` receives the token as its first argument.
- Normal return → `Fulfilled` with result (nil preserved).
- Thrown error → `Errored` with error.
- If the task is already terminal before the coroutine completes, later results are ignored.

## `Task.Delay(seconds, fn?)`

Creates a task that fulfills after `seconds`. If `fn` is supplied, calls it and fulfills with the return value. If `fn` errors, the task becomes `Errored`.

**Error behavior**

```text
Task.Delay: seconds must be non-negative
```

**Cancellation behavior**

If the task is cancelled before the timer fires, the timer is cancelled and the task becomes `Cancelled`.

## `Task.Sleep(seconds, token?)`

Yields the calling coroutine for `seconds`.

**Returns** `(true, nil)` after the delay, or `(false, reason)` if the token is cancelled first.

**Error behavior**

```text
Task.Sleep: seconds must be non-negative
Task.Sleep: invalid token
Task.Sleep: must be called from a yieldable coroutine
```

**Scheduler behavior**

Uses `Scheduler.Delay` internally. Does not create a Task handle.

## `Task.Resolved(value)` / `Task.Rejected(errorValue)` / `Task.Cancelled(reason?)`

Create pre-settled tasks.

**Behavior**

- `Finally` handlers registered on pre-settled tasks are scheduled through `Scheduler.Defer`.

## `Task.Timeout(inner, seconds, reason?)`

Wraps `inner` with a time limit.

**Error behavior**

```text
Task.Timeout: seconds must be positive
Task.Timeout: inner must be a Task or function returning a Task
```

**Behavior**

- If the timer fires first: cancels `inner` with `reason` (defaults to `Task.Reason.Timeout`) and the outer task becomes `Cancelled`.
- If `inner` settles first: cancels the timer with `Task.Reason.Superseded` and mirrors inner's status.

## `Task.Retry(makeTask, opts)`

Retries an operation up to `Count` times.

**Options**

```luau
{
    Count: number,         -- positive integer
    Backoff: "Fixed" | "Expo",
    Base: number,          -- >= 0
    Jitter: number?,       -- >= 0, multiplies delay by (1 + random * Jitter)
}
```

**Behavior**

- Each attempt creates a child token linked to the outer token.
- If the outer token is cancelled, the retry task becomes `Cancelled`.
- On failure, sleeps a backoff delay before the next attempt.
- `Fixed` delay = `Base`. `Expo` delay = `Base * 2^(attempt-1)`, capped at 30 seconds.
- After all attempts fail, the task becomes `Errored` with the last error.

## `Task.All(tasks)`

Fulfills when all tasks fulfill. Rejects on first failure.

**Behavior**

- Result is an array of values in input order. Nil results are preserved at their index.
- First errored child → cancel pending siblings with `Superseded`, outer `Errored`.
- First cancelled child (before any error) → cancel pending siblings, outer `Cancelled`.

## `Task.Race(tasks)`

First settled wins. Losers are not cancelled.

## `Task.Any(tasks)`

First fulfilled wins. Pending losers are cancelled with `Superseded`.

If all fail: outer `Errored` with `{ Failures = { SettledResult } }`.

## `Task.AllSettled(tasks)`

Waits for all tasks to settle. Never errors due to child failures.

Each result entry: `{ Status, Value?, Error?, Reason? }`.

## `Task.FromRoblox(rbxSignal, untilSignal?)`

Creates a task that waits for an `RBXScriptSignal` to fire once.

**Behavior**

- Main fires → `Fulfilled` with `{ ..., n = count }`.
- Until signal fires → `Fulfilled` with `nil`.
- Task cancelled → disconnect both, `Cancelled`.

**Error behavior**

```text
Task.FromRoblox: rbxSignal must be an RBXScriptSignal
Task.FromRoblox: untilSignal must be an RBXScriptSignal
```

## `Task.Group(opts?)`

Creates a task group for managing a collection of pending tasks.

## `Task.IsTask(value)` / `Task.IsToken(value)` / `Task.IsGroup(value)`

Return `true` for handles created by this module.

## `Task.SetTracer(fn?)`

Installs a global tracer. Events: `"Start"`, `"Done"`, `"Error"`, `"Cancel"`.

Tracer errors route through `ErrorHandler` phase `"Trace"`.

## `task:Token()`

Returns the task's cancellation token.

## `task:Cancel(reason?)`

Cancels a pending task. No-op if terminal.

**Behavior**

- Default reason: `Task.Reason.User`.
- Marks token cancelled, fires OnCancel hooks (deferred).
- Sets status to `Cancelled`.
- Runs finally handlers.
- Emits trace `"Cancel"`.

## `task:Status()` / `task:IsPending()` / `task:IsFulfilled()` / `task:IsCancelled()` / `task:IsErrored()` / `task:IsDone()`

Return the current status or a boolean predicate. `IsDone` returns `true` for any non-`Pending` status.

## `task:Finally(fn)`

Registers a callback to run when the task settles.

**Callback signature:** `(status: Status, value: unknown?) -> ()`

- `value` is the result for `Fulfilled`, error for `Errored`, reason for `Cancelled`.

**Behavior**

- If the task is already terminal, the callback is scheduled through `Scheduler.Defer`.
- Returns the same task for chaining.
- Errors route through `ErrorHandler` phase `"Finally"`.

## `task:Await(token?)`

Yields the calling coroutine until the task settles.

**Returns** `(true, result)` for `Fulfilled`, `(false, errorOrReason)` otherwise.

**Behavior**

- Returns immediately if the task is already terminal.
- The optional `token` cancels only the await, not the awaited task.
- Resume is scheduled through `Scheduler.Defer`.

**Error behavior**

Must be called from a yieldable coroutine if the task is pending.

## `task:Unwrap(token?)`

Calls `Await`. If `ok` is `false`, errors with the returned value.

## `task:Result()`

Returns `(hasResult: boolean, value: T?)`.

`hasResult` is `true` only when status is `Fulfilled`.

## `task:Error()`

Returns `(hasError: boolean, error: unknown?)`.

`hasError` is `true` only when status is `Errored`.

## `task:Name()`

Returns the task name or `nil`.

## Token methods

### `token:Cancelled()`

Returns whether the token has been cancelled.

### `token:Reason()`

Returns the cancellation reason or `nil`.

### `token:OnCancel(fn)`

Registers a callback to run when the token is cancelled.

**Behavior**

- If the token is already cancelled, the callback is scheduled through `Scheduler.Defer` and a disconnected `Connection` is returned.
- Errors route through `ErrorHandler` phase `"TokenCancel"`.

## Group methods

### `group:Add(task)`

Adds a pending task to the group. Terminal tasks are ignored.

### `group:Start(fn, opts?)`

Starts a task and adds it to the group.

### `group:CancelAll(reason?)`

Cancels all currently tracked pending tasks. Default reason: `Task.Reason.ModeExit`.

### `group:JoinAll()`

Returns a task that fulfills `nil` when all currently tracked tasks settle.

### `group:Race()`

Returns a task that mirrors the first settled task among currently tracked tasks.

### `group:Destroy(reason?)`

Cancels all pending tasks, clears the group, and marks it destroyed. Future `Add`/`Start` calls error.

### `group:Size()`

Returns the count of currently tracked pending tasks.

### `group:Name()`

Returns the group name or `nil`.

## Status reference

| Status | Terminal | Description |
|---|---|---|
| `Pending` | No | Work in progress |
| `Fulfilled` | Yes | Completed with result |
| `Errored` | Yes | Completed with error |
| `Cancelled` | Yes | Cancelled by token |

Once terminal, status never changes.

## Cancellation model

Cancellation is cooperative. `Cancel` marks the token cancelled and fires hooks. It does not force-terminate a coroutine. Task bodies must check the token or call cancellable APIs (`Task.Sleep`, `task:Await`).

## Nil behavior

Nil return values from task functions are stored with presence tracking. `task:Result()` returns `(true, nil)` for a task that fulfilled with nil.

## Scheduler behavior

Coroutines are started via `Scheduler.Defer`. Finally handlers and token OnCancel hooks run via `Scheduler.Defer`. `Task.Await` resumes are scheduled via `Scheduler.Defer`.

## Not implemented

Forcible coroutine termination is not supported. Cancellation is always cooperative.
