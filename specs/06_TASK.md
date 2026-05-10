# 06 — Task

Task is cancellable async work.

## Public API

```luau
Task.Start(fn: (token: Token) -> T, opts?): Task<T>
Task.Defer(fn: (token: Token) -> T, opts?): Task<T>
Task.Delay(seconds: number, fn: (() -> any)?): Task<nil>
Task.Sleep(seconds: number, token: Token?): (boolean, string?)
Task.Resolved(value: T): Task<T>
Task.Rejected(errorValue: unknown): Task<never>
Task.Cancelled(reason: string?): Task<never>
Task.Timeout(inner: Task<T> | (() -> Task<T>), seconds: number, reason: string?): Task<T>
Task.Retry(makeTask: (token: Token) -> T | Task<T>, opts): Task<T>
Task.All(tasks: { Task<any> }): Task<{ any }>
Task.Race(tasks: { Task<any> }): Task<any>
Task.Any(tasks: { Task<any> }): Task<any>
Task.AllSettled(tasks: { Task<any> }): Task<{ SettledResult }>
Task.FromRoblox(rbxSignal: RBXScriptSignal, untilSignal: RBXScriptSignal?): Task<{ any }?>
Task.Group(opts?): TaskGroup
Task.IsTask(value: unknown): boolean
Task.IsToken(value: unknown): boolean
Task.IsGroup(value: unknown): boolean
Task.SetTracer(fn?): ()
Task.SetScheduler(driver): ()
```

Task methods:

```luau
task:Token(): Token
task:Cancel(reason: string?): ()
task:Status(): Status
task:IsPending(): boolean
task:IsFulfilled(): boolean
task:IsCancelled(): boolean
task:IsErrored(): boolean
task:IsDone(): boolean
task:Finally(fn): Task<T>
task:Await(token: Token?): (boolean, T | unknown)
task:Unwrap(token: Token?): T
task:Result(): (boolean, T?)
task:Error(): (boolean, unknown?)
task:Name(): string?
```

Token methods:

```luau
token:Cancelled(): boolean
token:Reason(): string?
token:OnCancel(fn: (reason: string?) -> ()): Connection
```

Group methods:

```luau
group:Add(task): TaskGroup
group:Start(fn, opts?): Task<any>
group:CancelAll(reason?): ()
group:JoinAll(): Task<nil>
group:Race(): Task<any>
group:Destroy(reason?): ()
group:Size(): number
group:Name(): string?
```

## Status

```luau
export type Status = "Pending" | "Fulfilled" | "Cancelled" | "Errored"
```

Terminal statuses: Fulfilled, Cancelled, Errored.

## Cancellation

Cancellation is cooperative.

`Cancel`:

- marks token cancelled
- fires token cancel hooks
- sets task status Cancelled if still Pending
- runs finally handlers
- does not forcibly kill coroutine

Task body must check token or await cancellable work.

## `Start`

Behavior:

- creates task and token
- schedules first coroutine resume through Scheduler.Defer
- returns task immediately
- if fn returns, task Fulfilled with result
- if fn errors, task Errored with error
- if task already Cancelled, return/error is ignored

Options:

```luau
{
    Name: string?,
}
```

No per-task scheduler option.

## `Defer`

Same as Start semantically. Exists for readability when caller wants explicitly deferred work.

## `Delay`

Requires seconds >= 0.

Creates task that completes after delay. If fn supplied, calls fn after delay and task result remains nil unless you choose to return fn result. Preferred: return fn result if supplied; document. Use one consistent behavior.

Cancellation before delay fires cancels timer and task becomes Cancelled.

## `Sleep`

Convenience yielding helper for inside a task/coroutine.

Returns:

```luau
ok: boolean, reason: string?
```

- true,nil when time elapsed
- false,reason when token cancelled before elapsed

Requires seconds >= 0.

## Pre-settled tasks

`Resolved(value)` creates already Fulfilled task.

`Rejected(errorValue)` creates already Errored task.

`Cancelled(reason)` creates already Cancelled task.

Finally handlers registered later are scheduled through Scheduler.Defer.

## `Timeout`

Requires seconds > 0.

Behavior:

- start/obtain inner task
- start timer
- if timer wins: cancel inner with reason or `Task.Reason.Timeout`
- await inner
- if inner wins: cancel timer
- outer result mirrors inner if fulfilled
- outer errors if inner errored/cancelled

Timeout does not kill ignored coroutines.

## `Retry`

Options:

```luau
{
    Count: number,
    Backoff: "Fixed" | "Expo",
    Base: number,
    Jitter: number?,
}
```

Validation:

- Count > 0 integer
- Base >= 0
- Jitter >= 0 if supplied
- Backoff must be Fixed or Expo

Behavior:

- attempt up to Count times
- makeTask receives outer token or child token; choose one and document. Preferred: child token linked to outer token
- if makeTask returns Task, await it
- if returns value, success
- if attempt errors/fails, delay before next attempt
- if outer token cancelled, retry task becomes Cancelled
- after final failure, retry task Errored with last error

## `All`

Requires non-empty dense array of valid tasks.

Behavior:

- succeeds when all fulfill
- result array preserves input order
- nil task results are preserved using packed/sentinel internal storage
- if any task errors/cancels, cancel pending siblings with Superseded and error/cancel outer consistently. Preferred: outer Errored with failure value unless failure was cancellation; document exactly.

## `Race`

First settled task wins.

- fulfilled winner -> outer Fulfilled with result
- errored winner -> outer Errored
- cancelled winner -> outer Cancelled
- losing tasks are not cancelled by default

## `Any`

First fulfilled task wins.

- ignores errored/cancelled tasks until all settle
- if all fail/cancel, outer Errored with aggregate result
- losing pending tasks after first success may be cancelled with Superseded or left running; choose and document. Preferred: cancel losers.

## `AllSettled`

Waits until all settle. Never errors because child failed.

Result entry:

```luau
{
    Status: Status,
    Value: unknown?,
    Error: unknown?,
    Reason: string?,
}
```

## `FromRoblox`

Requires RBXScriptSignal. untilSignal optional and must also be RBXScriptSignal if supplied.

Behavior:

- waits for main signal once
- returns packed args array with field `n`
- if untilSignal fires first, resolves nil
- cancellation disconnects connections and cancels task

## `Await`

If task terminal, returns immediately.

If pending:

- must be called from yieldable coroutine
- registers finally handler
- yields
- resumes via Scheduler.Defer

Optional token cancels the awaiter and the awaited task? Preferred semantics: optional token cancels only waiting by default, not shared awaited task. To cancel awaited task, caller should call `task:Cancel`. Document this clearly.

Return:

```luau
true, value
false, errorOrReason
```

## `Unwrap`

Calls Await. If ok false, errors with value. Otherwise returns value.

## `Result` and `Error`

Return presence boolean plus value:

```luau
local hasResult, value = task:Result()
local hasError, err = task:Error()
```

This preserves nil results/errors.

## Token

`OnCancel`:

- if already cancelled, schedule callback through Scheduler.Defer
- otherwise store callback
- returned connection can disconnect before cancellation
- callback errors route through ErrorHandler

## Group

Group owns pending tasks.

`Destroy(reason)`:

- cancels all pending tasks
- clears group
- marks destroyed
- future Add/Start error
- idempotent

`JoinAll`:

- snapshots current tasks
- waits until all settle
- ignores child success/failure
- fulfills nil

`Race`:

- snapshots current tasks
- first settled decides
- preserves fulfilled result
- does not cancel losers unless group policy says so; preferred no

## Reason constants

Provide:

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
