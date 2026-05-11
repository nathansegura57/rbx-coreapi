# 07 — Task Specification

`Task` is cancellable async work.

A Task is a handle around a Luau coroutine with cooperative cancellation, status, result/error storage, finally handlers, combinators, delays, retries, timeouts, Roblox signal waiting, and groups.

## Public API

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
```

## Task methods

```luau
task:Token(): Task.Token
task:Cancel(reason: string?): ()
task:Status(): Status
task:IsPending(): boolean
task:IsFulfilled(): boolean
task:IsCancelled(): boolean
task:IsErrored(): boolean
task:IsDone(): boolean
task:Finally(fn: (status: Status, value: unknown?) -> ()): Task.Task<T>
task:Await(token: Task.Token?): (boolean, T | unknown)
task:Unwrap(token: Task.Token?): T
task:Result(): (boolean, T?)
task:Error(): (boolean, unknown?)
task:Name(): string?
```

## Token methods

```luau
token:Cancelled(): boolean
token:Reason(): string?
token:OnCancel(fn: (reason: string?) -> ()): Connection.Connection
```

## Group methods

```luau
group:Add(task: Task.Task<any>): Task.TaskGroup
group:Start(fn: (token: Task.Token) -> any, opts: TaskOptions?): Task.Task<any>
group:CancelAll(reason: string?): ()
group:JoinAll(): Task.Task<nil>
group:Race(): Task.Task<any>
group:Destroy(reason: string?): ()
group:Size(): number
group:Name(): string?
```

## Status

```luau
export type Status = "Pending" | "Fulfilled" | "Cancelled" | "Errored"
```

Terminal statuses:

```text
Fulfilled
Cancelled
Errored
```

Once terminal, status never changes.

## Reason constants

```luau
Task.Reason = table.freeze({
    ModeExit = "ModeExit",
    GuardFalse = "GuardFalse",
    Superseded = "Superseded",
    Timeout = "Timeout",
    User = "User",
    Shutdown = "Shutdown",
    Capacity = "Capacity",
})
```

## Cancellation model

Cancellation is cooperative.

`Cancel` marks the task cancelled and fires hooks. It does not forcibly kill a coroutine.

Task bodies must check token or await cancellable APIs.

If a coroutine returns/errors after task has already become terminal, that later result/error is ignored.

## `Task.Start(fn, opts?)`

Creates and starts a task.

### Validation

- `fn` function.
- `opts` table/nil.
- `opts.Name`, if supplied, string.

Errors:

```text
Task.Start: fn must be a function
Task.Start: opts must be a table or nil
Task.Start: Name must be a string or nil
```

### Behavior

1. Create task record:
   - Status = `"Pending"`
   - Result absent
   - Error absent
   - Reason absent
   - FinallyHandlers = empty
2. Create token record linked to task.
3. Create coroutine wrapping `fn(token)`.
4. Emit trace `"Start"`.
5. Schedule first resume using `Scheduler.Defer`.
6. Return task immediately.

When coroutine completes:

- normal return -> `Fulfilled` with result, including nil with presence
- thrown error -> `Errored` with error, including nil with presence if possible
- if already terminal -> ignore

Callback errors are captured by task wrapper, not reported through ErrorHandler as callback errors; they become task errors.

## `Task.Defer(fn, opts?)`

Alias with same semantics as `Task.Start`.

Exists for readability.

## `Task.Delay(seconds, fn?)`

Creates task that completes after delay.

### Validation

- `seconds >= 0`
- `fn` function/nil

### Behavior

- Starts a task.
- Inside task, schedules timer.
- If timer fires first:
  - if fn exists, call it and fulfill with return
  - else fulfill nil
- If task cancelled before timer:
  - cancel timer
  - task status is Cancelled
- If fn errors, task Errored.

## `Task.Sleep(seconds, token?)`

Yielding helper for inside a coroutine.

### Validation

- `seconds >= 0`
- token nil or valid Token
- must be called from yieldable coroutine

Errors:

```text
Task.Sleep: seconds must be non-negative
Task.Sleep: invalid token
Task.Sleep: must be called from a yieldable coroutine
```

### Returns

```luau
true, nil
false, reason
```

### Behavior

- Schedule timer.
- If timer fires first, resume caller with `true, nil`.
- If token cancels first, cancel timer and resume `false, reason`.
- Does not create a Task handle.

## Pre-settled tasks

### `Task.Resolved(value)`

Creates already Fulfilled task with value.

### `Task.Rejected(errorValue)`

Creates already Errored task with errorValue.

### `Task.Cancelled(reason)`

Creates already Cancelled task.

Later `Finally` handlers are scheduled through `Scheduler.Defer`.

## `Task.Timeout(inner, seconds, reason?)`

Wraps inner task with timeout.

### Validation

- `seconds > 0`
- `inner` Task or function returning Task
- returned thunk value valid Task

### Behavior

- Obtain inner task.
- Start timer task.
- Await whichever matters:
  - if timer completes before inner settles:
    - cancel inner with reason or `Task.Reason.Timeout`
    - outer becomes Cancelled with same reason unless inner settles first with error/result during cancellation handling
  - if inner settles first:
    - cancel timer with `Task.Reason.Superseded`
    - mirror inner status/result/error/reason
- Timeout does not kill ignored coroutines.

## `Task.Retry(makeTask, opts)`

Retries operation.

### Options

```luau
{
    Count: number,
    Backoff: "Fixed" | "Expo",
    Base: number,
    Jitter: number?,
}
```

### Validation

- Count positive integer
- Backoff `"Fixed"` or `"Expo"`
- Base >= 0
- Jitter nil or >= 0

### Behavior

For attempt 1..Count:

1. If outer token cancelled, retry task Cancelled.
2. Create child token linked to outer token.
3. Call `makeTask(childToken)`.
4. If result is Task, await it.
5. If result value, attempt succeeds and retry fulfills.
6. If attempt errors/task errors/task cancels, record failure.
7. If attempts remain, sleep backoff delay unless cancelled.
8. After final failure, retry Errored with last error/reason.

Backoff:

```luau
Fixed = Base
Expo = Base * 2 ^ (attempt - 1)
cap = 30
if Jitter then delay *= 1 + math.random() * Jitter
```

## `Task.All(tasks)`

Waits for all to fulfill.

### Validation

Non-empty dense array of valid Tasks.

### Behavior

- Preserve result order.
- Preserve nil results with packed/sentinel storage.
- First failure wins.
- Errored child -> cancel pending siblings with Superseded, outer Errored.
- Cancelled child before any error -> cancel pending siblings, outer Cancelled.
- Fulfill when all fulfilled.

## `Task.Race(tasks)`

First settled wins.

### Validation

Non-empty dense array of valid Tasks.

### Behavior

- First Fulfilled -> outer Fulfilled with result.
- First Errored -> outer Errored.
- First Cancelled -> outer Cancelled.
- Losers are not cancelled.

## `Task.Any(tasks)`

First fulfilled wins.

### Behavior

- Failed/cancelled tasks collected.
- First fulfilled -> outer Fulfilled and pending losers cancelled with Superseded.
- If all fail/cancel -> outer Errored with:

```luau
{ Failures = { SettledResult } }
```

## `Task.AllSettled(tasks)`

Waits for all terminal statuses.

Never errors because a child failed.

Result entries:

```luau
{
    Status: Status,
    Value: unknown?,
    Error: unknown?,
    Reason: string?,
}
```

## `Task.FromRoblox(rbxSignal, untilSignal?)`

Waits for Roblox signal once.

### Validation

Both supplied signals must be `RBXScriptSignal`.

### Behavior

- Connect main signal.
- Connect until signal if supplied.
- Main fires -> disconnect both -> fulfill with packed args `{ ..., n = count }`.
- Until fires -> disconnect both -> fulfill nil.
- Task cancellation -> disconnect both -> Cancelled.

## `task:Token()`

Returns task token.

Invalid handle error:

```text
Task.Token: invalid task handle
```

## `task:Cancel(reason?)`

Cancels pending task.

### Behavior

- Validate handle.
- If terminal, no-op.
- Default reason `Task.Reason.User`.
- Mark token cancelled.
- Fire token cancellation hooks.
- Set status Cancelled.
- Run finally handlers.
- Emit trace `"Cancel"`.

## Status predicate methods

```luau
IsPending -> Status == "Pending"
IsFulfilled -> Status == "Fulfilled"
IsCancelled -> Status == "Cancelled"
IsErrored -> Status == "Errored"
IsDone -> Status ~= "Pending"
```

Invalid handles error.

## `task:Finally(fn)`

Registers terminal callback.

### Validation

`fn` function.

### Callback

```luau
(status: Status, valueOrErrorOrReason: unknown?) -> ()
```

### Behavior

- If pending, store fn.
- If terminal, schedule callback through `Scheduler.Defer`.
- Return same task.
- Callback errors route through ErrorHandler phase `"Finally"`.

## `task:Await(token?)`

Waits for task.

### Validation

- valid task
- token nil or valid Token
- if task pending, must be in yieldable coroutine

### Behavior

- Terminal task returns immediately.
- Pending task registers finally handler and yields.
- Resume waiting coroutine via `Scheduler.Defer`.
- Optional token cancels only the await operation, not the awaited task.
- If await token cancels first, return `false, reason`.

Returns:

```luau
true, result
false, errorOrReason
```

## `task:Unwrap(token?)`

Calls Await.

If ok false, errors with returned value.

If ok true, returns value.

## `task:Result()`

Returns:

```luau
hasResult: boolean, value: T?
```

`hasResult` true only if status Fulfilled.

Preserves nil result via boolean.

## `task:Error()`

Returns:

```luau
hasError: boolean, error: unknown?
```

`hasError` true only if status Errored.

## `task:Name()`

Returns name or nil.

## Token methods

### `token:Cancelled()`

Returns cancellation state.

Invalid token returns false only if implementation chooses tolerant token checks; preferred: invalid token errors for method calls. Normative: invalid token errors.

### `token:Reason()`

Returns reason or nil.

### `token:OnCancel(fn)`

Validation `fn` function.

If token pending, stores callback and returns Connection.

If token already cancelled, schedule callback through Scheduler.Defer and return disconnected Connection.

Callback errors route ErrorHandler phase `"TokenCancel"`.

## Group

Groups own pending tasks.

### `Task.Group(opts?)`

Validation opts table/nil, Name string/nil.

Creates live group.

### `group:Add(task)`

Requires live group and valid task.

Terminal tasks ignored.

Pending tasks tracked until finally removes them.

Returns group.

### `group:Start(fn, opts?)`

Starts task and adds it.

Returns task.

### `group:CancelAll(reason?)`

Defaults reason `Task.Reason.ModeExit`.

Snapshots current tasks, cancels each pending.

Does not destroy group.

### `group:JoinAll()`

Snapshots current tasks.

Returns task that fulfills nil when all snapshot tasks settle.

Ignores child success/failure.

### `group:Race()`

Snapshots current tasks.

Returns task that mirrors first settled task and preserves fulfilled result.

Does not cancel losers.

### `group:Destroy(reason?)`

Idempotent.

- cancel all pending tasks
- clear group
- mark destroyed
- future Add/Start error

### `group:Size()`

Returns count of currently tracked pending tasks.

### `group:Name()`

Returns name or nil.

## Tracing

`Task.SetTracer(fn?)` installs global tracer.

Tracer errors route through ErrorHandler phase `"Trace"`.

Events include at minimum:

```text
Start
Done
Error
Cancel
```
