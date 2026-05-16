# Task

Structured async tasks with cooperative cancellation. A `Task` represents an async operation that can be awaited, cancelled, and composed with other tasks. `Token` is the cancellation signal passed into task functions. `TaskGroup` collects tasks for bulk cancel and join.

---

## Enum Tables

### `Task.Status`

```luau
Task.Status.Pending    -- running
Task.Status.Fulfilled  -- completed successfully
Task.Status.Cancelled  -- cancelled via token
Task.Status.Errored    -- threw an error
```

### `Task.Reason`

Standard cancellation reason strings:

```luau
Task.Reason.ModeExit   -- FSM mode exited
Task.Reason.GuardFalse -- guard store turned false
Task.Reason.Superseded -- replaced by Switch concurrency
Task.Reason.Timeout    -- Task.Timeout fired
Task.Reason.User       -- Task:Cancel() with no reason
Task.Reason.Shutdown   -- TaskGroup destroyed
Task.Reason.Capacity   -- capacity limit hit
```

### `Task.Backoff`

```luau
Task.Backoff.Fixed  -- constant retry delay
Task.Backoff.Expo   -- exponential backoff
```

---

## API Reference

### Constructors

#### `Task.Start(fn, opts?)`

Spawns an async task. `fn` receives a `Token` and runs inside a new coroutine via `Scheduler.Defer`. The task settles as `Fulfilled` with `fn`'s return value, or `Errored` if `fn` throws.

| Parameter | Type | Description |
|-----------|------|-------------|
| `fn` | `(token: Token) -> any` | The task body |
| `opts` | `TaskOptions?` | Optional `{ Name: string? }` |

**Returns:** `Task<any>`

**Errors:**
- `Task.Start: fn must be a function`
- `Task.Start: opts must be a table or nil`
- `Task.Start: Name must be a string or nil`

```luau
local t = Task.Start(function(token)
    local ok = Task.Sleep(2, token)
    if not ok then return end  -- cancelled during sleep
    return "done"
end)

t:Finally(function(status, value)
    print(status, value)  -- "Fulfilled", "done"
end)
```

---

#### `Task.Delay(seconds, fn?)`

Creates a task that settles after `seconds` seconds. If `fn` is provided, it is called at that point and the task settles with its return value (or `Errored` if it throws). Without `fn`, the task fulfills with `nil`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `seconds` | `number` | Must be `>= 0` |
| `fn` | `(() -> any)?` | Optional thunk called after the delay |

**Returns:** `Task<any>`

**Errors:**
- `Task.Delay: seconds must be non-negative`
- `Task.Delay: fn must be a function or nil`

```luau
-- Wait 3 seconds, then do something:
Task.Delay(3, function()
    print("3 seconds elapsed")
end):Finally(function(status)
    print(status)  -- "Fulfilled"
end)
```

---

#### `Task.Sleep(seconds, token?)`

Yields the current coroutine for `seconds` seconds. Returns `(true, nil)` on success, or `(false, reason)` if the token was cancelled. Must be called from a yieldable coroutine.

| Parameter | Type | Description |
|-----------|------|-------------|
| `seconds` | `number` | Must be `>= 0` |
| `token` | `Token?` | Optional cancellation token |

**Returns:** `(boolean, string?)` — `(true, nil)` or `(false, cancelReason)`

**Errors:**
- `Task.Sleep: seconds must be non-negative`
- `Task.Sleep: invalid token`
- `Task.Sleep: must be called from a yieldable coroutine`

```luau
local t = Task.Start(function(token)
    for i = 1, 5 do
        local ok, reason = Task.Sleep(1, token)
        if not ok then
            print("cancelled:", reason)
            return
        end
        print("step", i)
    end
end)
```

---

#### `Task.Resolved(value)`

Creates an already-fulfilled task.

| Parameter | Type | Description |
|-----------|------|-------------|
| `value` | `any` | The fulfilled value |

**Returns:** `Task<any>`

```luau
local t = Task.Resolved(42)
local ok, v = t:Await()  -- ok = true, v = 42
```

---

#### `Task.Rejected(errorValue)`

Creates an already-errored task.

| Parameter | Type | Description |
|-----------|------|-------------|
| `errorValue` | `unknown` | The error |

**Returns:** `Task<any>`

---

#### `Task.Cancelled(reason?)`

Creates an already-cancelled task.

| Parameter | Type | Description |
|-----------|------|-------------|
| `reason` | `string?` | Optional cancellation reason |

**Returns:** `Task<any>`

---

### Combinators

#### `Task.All(tasks)`

Fulfills when all tasks fulfill (with an array of their values). Cancels or errors immediately if any task fails, and cancels all remaining tasks with `Task.Reason.Superseded`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `tasks` | `{ Task<any> }` | Non-empty array |

**Returns:** `Task<{ any }>`

**Errors:**
- `Task.All: tasks must be a non-empty dense array`
- `Task.All: task at index {i} is not a valid Task`

```luau
local combined = Task.All({ taskA, taskB, taskC })
combined:Finally(function(status, values)
    if status == Task.Status.Fulfilled then
        print(values[1], values[2], values[3])
    end
end)
```

---

#### `Task.Race(tasks)`

Settles with the first task to settle (in any status). Other tasks are not cancelled.

| Parameter | Type | Description |
|-----------|------|-------------|
| `tasks` | `{ Task<any> }` | Non-empty array |

**Returns:** `Task<any>`

**Errors:**
- `Task.Race: tasks must be a non-empty dense array`
- `Task.Race: task at index {i} is not a valid Task`

---

#### `Task.Any(tasks)`

Fulfills with the first task to fulfill. If all tasks fail, settles as `Errored` with `{ Failures: { SettledResult } }`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `tasks` | `{ Task<any> }` | Non-empty array |

**Returns:** `Task<any>`

**Errors:**
- `Task.Any: tasks must be a non-empty dense array`
- `Task.Any: task at index {i} is not a valid Task`

---

#### `Task.AllSettled(tasks)`

Waits for all tasks to settle (in any status), then fulfills with an array of `SettledResult` objects. Never cancels or errors.

| Parameter | Type | Description |
|-----------|------|-------------|
| `tasks` | `{ Task<any> }` | Non-empty array |

**Returns:** `Task<{ SettledResult }>`

**`SettledResult` fields:**

| Field | Type | Description |
|-------|------|-------------|
| `Status` | `Status` | The final status |
| `Value` | `unknown?` | Fulfilled value (if `Status == "Fulfilled"`) |
| `Error` | `unknown?` | Error value (if `Status == "Errored"`) |
| `Reason` | `string?` | Cancel reason (if `Status == "Cancelled"`) |

**Errors:**
- `Task.AllSettled: tasks must be a non-empty dense array`
- `Task.AllSettled: task at index {i} is not a valid Task`

---

#### `Task.Timeout(inner, seconds, reason?)`

Wraps a task (or a thunk returning a task) with a timeout. If the inner task doesn't complete within `seconds`, it is cancelled with `reason` (default: `Task.Reason.Timeout`).

| Parameter | Type | Description |
|-----------|------|-------------|
| `inner` | `Task<any> \| (() -> Task<any>)` | The task or a thunk that creates it |
| `seconds` | `number` | Must be `> 0` |
| `reason` | `string?` | Custom cancellation reason |

**Returns:** `Task<any>` — mirrors inner on success; cancels with reason on timeout

**Errors:**
- `Task.Timeout: seconds must be positive`
- `Task.Timeout: thunk errored: {error}` — thunk threw
- `Task.Timeout: thunk must return a Task`
- `Task.Timeout: inner must be a Task or function returning a Task`

```luau
local withTimeout = Task.Timeout(longRunningTask, 5)
withTimeout:Finally(function(status, value)
    if status == Task.Status.Cancelled then
        print("timed out!")
    end
end)
```

---

#### `Task.Retry(makeTask, opts)`

Retries a task-producing function up to `Count` times. Succeeds as soon as any attempt fulfills. After all attempts fail, settles as `Errored` with the last error.

| Parameter | Type | Description |
|-----------|------|-------------|
| `makeTask` | `(token: Token) -> Task<any>` | Returns a new task attempt |
| `opts` | `RetryOptions` | Required configuration |

**`RetryOptions` fields:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `Count` | `number` | ✓ | Positive integer; max attempts |
| `Backoff` | `"Fixed" \| "Expo"` | ✓ | Use `Task.Backoff.*` constants |
| `Base` | `number` | ✓ | Base delay in seconds; `>= 0` |
| `Jitter` | `number?` | — | Random multiplier `>= 0`; `0.5` = ±50% |

**Returns:** `Task<any>`

**Errors:**
- `Task.Retry: opts must be a table`
- `Task.Retry: Count must be a positive integer`
- `Task.Retry: Backoff must be 'Fixed' or 'Expo'`
- `Task.Retry: Base must be >= 0`
- `Task.Retry: Jitter must be >= 0 or nil`
- `Task.Retry: makeTask must be a function`

```luau
local result = Task.Retry(function(token)
    return Task.Start(function(_t)
        return fetchData()  -- may throw
    end)
end, {
    Count   = 3,
    Backoff = Task.Backoff.Expo,
    Base    = 1,
    Jitter  = 0.3,
})
```

---

#### `Task.FromRoblox(rbxSignal, untilSignal?)`

Creates a task that fulfills when `rbxSignal` fires (payload is `table.pack(...)`). If `untilSignal` fires first, the task fulfills with `nil`. Cancellation via token also resolves the task.

| Parameter | Type | Description |
|-----------|------|-------------|
| `rbxSignal` | `RBXScriptSignal` | The Roblox signal to await |
| `untilSignal` | `RBXScriptSignal?` | Optional stop signal |

**Returns:** `Task<table.pack result>`

**Errors:**
- `Task.FromRoblox: rbxSignal must be an RBXScriptSignal`
- `Task.FromRoblox: untilSignal must be an RBXScriptSignal`

---

### TaskGroup

#### `Task.Group(opts?)`

Creates a group that tracks pending tasks and supports bulk operations.

| Parameter | Type | Description |
|-----------|------|-------------|
| `opts` | `{ Name: string? }?` | Optional name |

**Returns:** `TaskGroup`

**Errors:**
- `Task.Group: opts must be a table or nil`
- `Task.Group: Name must be a string or nil`

---

#### `group:Add(task)`

Adds a task to the group. No-op if the task is already done. Returns `self`.

**Errors:**
- `Group.Add: group is destroyed`
- `Group.Add: invalid task handle`

---

#### `group:CancelAll(reason?)`

Cancels all pending tasks in the group. Default reason: `Task.Reason.ModeExit`.

---

#### `group:Size()`

Returns the count of currently-pending tasks.

**Returns:** `number`

---

#### `group:Name()`

Returns the group's name, or `nil`.

**Returns:** `string?`

---

#### `group:Destroy(reason?)`

Cancels all pending tasks and marks the group as destroyed. Default reason: `Task.Reason.ModeExit`.

---

### Predicates

#### `Task.IsTask(value)` / `Task.IsToken(value)` / `Task.IsGroup(value)`

Return `true` if `value` is a valid handle of the respective type.

---

### Tracing

#### `Task.SetTracer(fn?)`

Installs a global tracer called on every task lifecycle event. Pass `nil` to remove.

| Parameter | Type | Description |
|-----------|------|-------------|
| `fn` | `((TraceEvent) -> ())?` | Called with a `TraceEvent` table |

**`TraceEvent` fields:**

| Field | Type | Description |
|-------|------|-------------|
| `Event` | `string` | `"Start"`, `"Done"`, `"Cancel"`, or `"Error"` |
| `Name` | `string?` | Task name, if set |
| `Status` | `Status?` | Current task status at event time |

---

### Task Instance Methods

#### `task:Token()`

Returns the task's cancellation token.

**Returns:** `Token`

**Errors:** `Task.Token: invalid task handle`

---

#### `task:Cancel(reason?)`

Cancels the task. No-op if already settled. Default reason: `Task.Reason.User`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `reason` | `string?` | Optional reason string |

---

#### `task:Status()`

Returns the current status.

**Returns:** `"Pending" | "Fulfilled" | "Cancelled" | "Errored"`

---

#### `task:IsPending()` / `task:IsFulfilled()` / `task:IsCancelled()` / `task:IsErrored()` / `task:IsDone()`

Status predicates. `IsDone()` returns `true` for any non-Pending status.

---

#### `task:Finally(fn)`

Registers `fn` to run when the task settles. If already settled, schedules `fn` via `Scheduler.Defer`. Returns `self` for chaining.

| Parameter | Type | Description |
|-----------|------|-------------|
| `fn` | `(status: Status, value: unknown?) -> ()` | `value` is the result, error, or cancel reason depending on `status` |

**Errors:**
- `Task.Finally: fn must be a function`
- `Task.Finally: invalid task handle`

```luau
task:Finally(function(status, value)
    if status == Task.Status.Fulfilled then
        print("result:", value)
    elseif status == Task.Status.Errored then
        warn("error:", value)
    else
        print("cancelled:", value)  -- value is reason string
    end
end)
```

---

#### `task:Await(token?)`

Yields until the task settles, then returns `(true, value)` on fulfillment or `(false, errorOrReason)` on error/cancel. Passing a `token` allows the `Await` itself to be cancelled.

| Parameter | Type | Description |
|-----------|------|-------------|
| `token` | `Token?` | Optional; if cancelled, `Await` returns `(false, reason)` immediately |

**Returns:** `(boolean, any)` — `(true, value)` or `(false, errorOrReason)`

**Errors:**
- `Task.Await: invalid task handle`
- `Task.Await: invalid token`
- `Task.Await: must be called from a yieldable coroutine`

```luau
local ok, value = someTask:Await()
if ok then
    print("got:", value)
end
```

---

#### `task:Unwrap(token?)`

Like `Await`, but throws on failure instead of returning `(false, ...)`.

**Returns:** `T`

**Errors:** re-throws the error or cancel reason on failure

---

#### `task:Result()`

Returns `(true, value)` if fulfilled, `(false, nil)` otherwise. Never yields.

**Returns:** `(boolean, T?)`

---

#### `task:Error()`

Returns `(true, errorValue)` if errored, `(false, nil)` otherwise.

**Returns:** `(boolean, unknown?)`

---

#### `task:Name()`

Returns the task name, or `nil`.

**Returns:** `string?`

---

### Token Instance Methods

#### `token:Cancelled()`

Returns `true` if the token has been cancelled.

**Returns:** `boolean`

---

#### `token:Reason()`

Returns the cancellation reason, or `nil` if not cancelled.

**Returns:** `string?`

---

#### `token:OnCancel(fn)`

Registers `fn` to run when the token is cancelled. If already cancelled, schedules `fn` via `Scheduler.Defer`. Returns an already-disconnected Connection (the callback still fires).

| Parameter | Type | Description |
|-----------|------|-------------|
| `fn` | `(reason: string?) -> ()` | Called with the cancellation reason |

**Returns:** `Connection.Connection` — disconnect to unregister

**Errors:**
- `Token.OnCancel: fn must be a function`
- `Token.OnCancel: invalid token handle`

```luau
local t = Task.Start(function(token)
    local conn = token:OnCancel(function(reason)
        print("cancelled because:", reason)
        -- Run cleanup here
    end)
    -- Long-running loop:
    while not token:Cancelled() do
        Task.Sleep(0.1, token)
    end
    conn:Disconnect()  -- no longer needed
end)
```

---

## Gotchas

- **Tasks start deferred.** `Task.Start` schedules the coroutine via `Scheduler.Defer`. The function body does not run synchronously — `Finally` handlers may be registered safely before the body executes.
- **Cancellation is cooperative.** Cancelling a task signals the token; the task body must check `token:Cancelled()` or use `Task.Sleep` (which returns `false` when cancelled) to actually stop.
- **`Finally` callbacks are always deferred.** Even if a task is already settled when `Finally` is called, `fn` runs via `Scheduler.Defer`, never synchronously.
- **`Await` requires a yieldable coroutine.** If called from non-coroutine code (module top level, or `init`), it throws. Always call `Await` inside a `Task.Start` body or equivalent coroutine.
- **`Task.Retry` inner tasks use their own child tokens.** Cancelling the outer retry task propagates to the current child token. The retry loop checks the outer token between attempts.
- **`Task.Delay` fn errors settle the task as Errored.** If the thunk passed to `Delay` throws, the resulting task is `Errored`, not `Cancelled`.
- **`Task.All` cancels siblings on first failure.** Any error or cancellation from one task immediately cancels all remaining pending siblings with `Task.Reason.Superseded`.
- **`Task.Any` collects all failures.** Only settles as `Errored` after every task has failed, producing a `{ Failures }` table. Use when you want the first success from a pool of fallibles.
- **TaskGroup does not own tasks.** Adding a task to a group does not prevent external cancellation. `CancelAll` only cancels tasks still in the group's `PendingTasks` set.

---

## Complete Example

```luau
local Task = require(path.to.Task)

-- Fetch with retry and timeout.
local function fetchWithRetry(url: string): Task.Task<string>
    return Task.Timeout(
        Task.Retry(function(token)
            return Task.Start(function(_t)
                -- Simulated fetch that may fail
                local data = httpGet(url)
                return data
            end)
        end, {
            Count   = 3,
            Backoff = Task.Backoff.Expo,
            Base    = 0.5,
            Jitter  = 0.2,
        }),
        10,
        "FetchTimeout"
    )
end

local group = Task.Group({ Name = "FetchGroup" })

local t = Task.Start(function(token)
    local ok, data = fetchWithRetry("https://example.com/api"):Await(token)
    if not ok then
        warn("fetch failed:", data)
        return
    end
    print("got data:", data)
end)
group:Add(t)

t:Finally(function(status)
    print("task finished with:", status)
end)

-- Cancel everything after 15 seconds if still running
Task.Delay(15, function()
    group:CancelAll("Shutdown")
end)
```

---

## Planned APIs

The following `TaskGroup` APIs are planned but not yet implemented:

#### `group:Start(fn, opts?)`

Equivalent to `Task.Start(fn, opts)` followed by `group:Add(task)`. Returns the new task.

**Status:** Planned — use `Task.Start` followed by `group:Add` in the meantime.

---

#### `group:JoinAll()`

Returns a task that fulfills when all currently-pending tasks in the group have settled.

**Returns:** `Task<nil>`

**Status:** Planned.

---

#### `group:Race()`

Returns a task that settles with the first pending task to settle.

**Returns:** `Task<any>`

**Status:** Planned.
