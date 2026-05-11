# Rule

A declarative event-driven effect runner. A `Rule` listens to a `Signal`, evaluates an optional guard, and runs an effect with configurable concurrency, throttle, debounce, retry, and error policy. Rules are typically attached to FSM modes so they enable and disable automatically with state changes.

---

## Enum Tables

### `Rule.Concurrency`

```luau
Rule.Concurrency.Exhaust  -- (default) drop new events while effect is in-flight
Rule.Concurrency.Merge    -- run all events concurrently up to Capacity
Rule.Concurrency.Concat   -- queue events and run them one after another
Rule.Concurrency.Switch   -- cancel the current run and start with the new event
```

### `Rule.Overflow`

Controls what happens when the `Concat` queue is full (at `Capacity`):

```luau
Rule.Overflow.Drop    -- (default) discard the new event
Rule.Overflow.Latest  -- replace the last queued event with the new one
Rule.Overflow.Fifo    -- discard the oldest queued event, enqueue the new one
```

### `Rule.Schedule`

```luau
Rule.Schedule.Immediate  -- run effect synchronously when signal fires
Rule.Schedule.Deferred   -- (default) defer effect via Scheduler.Defer
```

---

## API Reference

### `Rule.New(name)`

Creates a new unconfigured rule. The rule is inactive until `Enable` is called.

| Parameter | Type | Description |
|-----------|------|-------------|
| `name` | `string` | Non-empty identifier shown in traces and metrics |

**Returns:** `Rule<any, any>`

**Errors:**
- `Rule.New: name must be a non-empty string`

```luau
local killRule = Rule.New("ScoreOnKill")
    :On(onEnemyKilled)
    :Run(function(ctx, payload, frame)
        score:Set(score:Get() + (payload.Points or 10))
    end)
```

---

### `Rule.IsRule(value)`

Returns `true` if `value` is a live Rule handle.

**Returns:** `boolean`

---

### `Rule.DefaultPolicy()`

Returns a copy of the default policy table.

**Returns:** `Policy`

---

### `Rule.ValidatePolicy(policy)`

Validates a partial policy table without applying it.

**Returns:** `(boolean, string?)` — `(true, nil)` on success; `(false, message)` on invalid input

---

### `Rule.SetTracer(fn?)`

Installs a global tracer called on every rule lifecycle event. Pass `nil` to remove.

| Parameter | Type | Description |
|-----------|------|-------------|
| `fn` | `((TraceEvent) -> ())?` | Receives a `TraceEvent` |

**`TraceEvent` fields:**

| Field | Type | Description |
|-------|------|-------------|
| `Event` | `string` | One of `Rule.Enable`, `Rule.Disable`, `Rule.Admit`, `Rule.Skip`, `Rule.Start`, `Rule.Done`, `Rule.Error`, `Rule.Cancel`, `Rule.Once`, `Rule.Destroy` |
| `RuleName` | `string` | The rule's name |
| `Tag` | `string?` | The policy `Tag`, if set |

---

### Builder Methods (configure before enabling)

All builder methods return `self` for chaining. Calling any builder method while the rule is enabled throws.

---

#### `handle:On(signal)`

Binds the signal that triggers this rule.

| Parameter | Type | Description |
|-----------|------|-------------|
| `signal` | `Signal.Signal<Payload>` | Must be a live Signal |

**Errors:**
- `Rule.On: rule is destroyed`
- `Rule.On: cannot configure while enabled`
- `Rule.On: signal must be a live Signal`

---

#### `handle:When(guard)`

Sets an optional guard. The effect only runs when the guard passes.

| Parameter | Type | Description |
|-----------|------|-------------|
| `guard` | `Store.ReadableStore<boolean> \| (ctx, payload, frame) -> boolean` | Store or predicate function |

**Errors:**
- `Rule.When: rule is destroyed`
- `Rule.When: cannot configure while enabled`
- `Rule.When: guard must be a Store or function`

```luau
-- Store guard: effect runs only while isAlive is true.
rule:When(isAlive)

-- Function guard: custom predicate.
rule:When(function(ctx, payload, frame)
    return payload.Points > 0
end)
```

---

#### `handle:Run(effect)`

Sets the effect function.

| Parameter | Type | Description |
|-----------|------|-------------|
| `effect` | `(ctx, payload, frame) -> (nil \| (() -> ()) \| Task)` | Effect; return a cleanup function or a Task to track |

**Errors:**
- `Rule.Run: rule is destroyed`
- `Rule.Run: cannot configure while enabled`
- `Rule.Run: effect must be a function`

The `frame` argument has type `RuleFrame`:

| Field | Type | Description |
|-------|------|-------------|
| `RuleName` | `string` | Name or tag |
| `Now` | `() -> number` | Current time |
| `Token` | `Task.Token?` | Set when running inside a `Task.Retry` |

**Effect return values:**
- `nil` — no cleanup needed
- `() -> ()` — called when the next event fires (replaces the previous disposer)
- `Task.Task<any>` — tracked by the rule for concurrency accounting

---

#### `handle:Policy(policy)`

Merges `policy` into the defaults.

| Parameter | Type | Description |
|-----------|------|-------------|
| `policy` | `PartialPolicy` | Fields to override; see table below |

**`PartialPolicy` fields:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `Concurrency` | `string?` | `"Exhaust"` | Use `Rule.Concurrency.*` |
| `Capacity` | `number?` | `math.huge` | Max in-flight / queue depth |
| `Overflow` | `string?` | `"Drop"` | Use `Rule.Overflow.*`; only for `Concat` |
| `Cooldown` | `number?` | `nil` | Min seconds between admits |
| `Debounce` | `number?` | `nil` | Collapse rapid fires; delay in seconds |
| `Throttle` | `number?` | `nil` | Rate limit; window in seconds |
| `Leading` | `boolean?` | `true` | Fire on leading edge of throttle window |
| `Trailing` | `boolean?` | `true` | Fire on trailing edge of throttle window |
| `Schedule` | `string?` | `"Deferred"` | Use `Rule.Schedule.*` |
| `RecheckGuardBeforeRun` | `boolean?` | `false` | Re-evaluate guard just before running effect |
| `CancelTasksWhenGuardFalse` | `boolean?` | `false` | Cancel in-flight tasks when a Store guard turns false |
| `Once` | `boolean?` | `false` | Disable rule after first successful run |
| `ErrorPolicy` | `string?` | `nil` | Per-rule policy; overrides global for effect errors |
| `Retry` | `RetryOptions?` | `nil` | Retry configuration; see Task.Retry |
| `Trace` | `boolean?` | `false` | Enable tracing for this rule |
| `Tag` | `string?` | `nil` | Override name in traces |

**Errors:**
- `Rule.Policy: rule is destroyed`
- `Rule.Policy: cannot configure while enabled`
- `Rule.Policy: {validation message}` — see `Rule.ValidatePolicy` for all messages

**Constraints:**
- `Merge` concurrency only supports `Overflow.Drop`
- `Concurrency` must be one of the `Rule.Concurrency.*` values
- `Overflow` must be one of the `Rule.Overflow.*` values
- `Schedule` must be one of the `Rule.Schedule.*` values
- `ErrorPolicy` must be one of the four ErrorHandler policy values

---

#### `handle:WithContext(ctx)`

Provides a fixed context used as the `ctx` argument to the guard and effect. Overrides the context passed to `Enable`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `ctx` | `Context.Context<any>` | Must be a valid Context |

**Errors:**
- `Rule.WithContext: rule is destroyed`
- `Rule.WithContext: cannot configure while enabled`
- `Rule.WithContext: ctx must be a Context`

---

#### `handle:Attach(scope)`

Registers this rule with an FSM or FSM Mode so it is enabled/disabled automatically with that scope. Must be called before `Start`/`Enable`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `scope` | `FSM \| Mode` | The FSM or Mode to attach to |

**Errors:**
- `Rule.Attach: rule is destroyed`
- `Rule.Attach: scope must be an FSM or FSM Mode`

---

### Lifecycle Methods

#### `handle:Enable(ctx?)`

Enables the rule. The rule begins listening to the signal. Idempotent — calling `Enable` multiple times increments a reference count; each `Enable` must be matched with a `Disable`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `ctx` | `Context.Context<any>?` | Context passed to the guard and effect (if `WithContext` is not set) |

**Errors:**
- `Rule.Enable: rule is destroyed`
- `Rule.Enable: signal is not configured`
- `Rule.Enable: effect is not configured`
- `Rule.Enable: ctx must be Context`

---

#### `handle:Disable()`

Decrements the enable reference count. When it reaches zero:
1. Disconnects from the signal.
2. Cancels all in-flight tasks with `Task.Reason.ModeExit`.
3. Runs and clears the current disposer.
4. Cancels pending debounce and throttle timers.
5. Clears the `Concat` queue.

Idempotent at zero count.

---

#### `handle:Destroy()`

Disables the rule (if enabled) and permanently marks it destroyed. Further configuration or enable attempts throw.

---

#### `handle:IsEnabled()`

Returns `true` if the rule's enable count is greater than zero.

**Returns:** `boolean`

---

#### `handle:IsDestroyed()`

Returns `true` if the rule has been destroyed.

**Returns:** `boolean`

---

#### `handle:Name()`

Returns the rule's display name (the policy `Tag` if set, otherwise the name passed to `Rule.New`).

**Returns:** `string`

---

### Metrics

#### `handle:Metrics()`

Returns a snapshot of the rule's runtime metrics.

**Returns:** `Metrics`

| Field | Type | Description |
|-------|------|-------------|
| `Runs` | `number` | Total effect executions |
| `Skipped` | `number` | Events that passed guard but were dropped by concurrency/cooldown |
| `Errors` | `number` | Effect + guard errors |
| `AvgMs` | `number` | Average effect duration in milliseconds |
| `CollectedErrors` | `{ unknown }` | Errors accumulated under `ErrorPolicy = "Collect"` |

---

#### `handle:ResetMetrics()`

Zeroes all metrics counters and clears `CollectedErrors`.

---

## Policy Interactions

| Mechanism | When it applies |
|-----------|----------------|
| **Debounce** | Applied first. Collapses rapid fires into one. |
| **Throttle** | Applied after debounce (or instead, if no debounce). Controls leading/trailing fires. |
| **Guard** | Checked after debounce/throttle. If false, event is skipped. |
| **Cooldown** | Checked after guard. Skips if last admit was within cooldown period. |
| **Concurrency** | Checked last. Determines whether the effect runs immediately or is queued/dropped. |

**Effect ordering when a disposer is returned:**
- The disposer from the _previous_ run is called just before the new effect begins (for non-task effects with Exhaust/Switch concurrency).

---

## Gotchas

- **Builder methods throw while enabled.** `On`, `When`, `Run`, `Policy`, `WithContext`, `Attach` all check `EnableCount > 0` and throw `cannot configure while enabled`.
- **`Enable` is reference-counted.** FSM modes call `Enable` on enter and `Disable` on exit. If you also call `Enable`/`Disable` manually, the counts must balance. An extra `Enable` without a matching `Disable` keeps the rule alive indefinitely.
- **Effect errors go to `handleEffectError`, not `ErrorHandler.Report` directly.** If a per-rule `ErrorPolicy` is set, it overrides the global policy for effect errors only. Guard errors always go through `ErrorHandler`.
- **`CancelTasksWhenGuardFalse` only works with Store guards.** When the store turns false, all in-flight tasks are cancelled with `Task.Reason.GuardFalse`. Function guards do not support this behavior.
- **`Once` disables after the first admitted run, not the first signal fire.** If the guard is false or the event is throttled/debounced away, `Once` does not trigger.
- **`Merge` only supports `Overflow.Drop`.** Attempting to combine `Merge` with `Latest` or `Fifo` is a validation error.
- **Disposers are not called on `Disable`.** They are cleared and called when a new effect starts (replacing the old disposer). If you need cleanup on disable, do it in the effect body using `token:OnCancel`.

---

## Complete Example

```luau
local Rule    = require(path.to.Rule)
local Signal  = require(path.to.Signal)
local Store   = require(path.to.Store)
local Task    = require(path.to.Task)

local onMessage = Signal.New()
local isConnected = Store.Value(true)
local messageCount = Store.Value(0)

-- A rule that processes messages while connected, with retry and metrics.
local messageRule = Rule.New("ProcessMessage")
    :On(onMessage)
    :When(isConnected)
    :Run(function(ctx, payload, frame)
        -- Return a Task — Rule tracks it for concurrency.
        return Task.Start(function(token)
            local ok, result = Task.Sleep(0.1, token) -- simulated async work
            if not ok then return end
            messageCount:Update(function(n) return n + 1 end)
            print("processed:", payload)
        end)
    end)
    :Policy({
        Concurrency = Rule.Concurrency.Merge,
        Capacity    = 4,              -- max 4 concurrent handlers
        Throttle    = 0.05,           -- at most one admit per 50ms
        ErrorPolicy = "Warn",
        Trace       = true,
        Tag         = "MessageProcessor",
    })

-- Enable manually with an empty context (no shared state needed).
messageRule:Enable()

-- Fire some events.
onMessage:Fire("hello")
onMessage:Fire("world")

-- Check metrics.
local m = messageRule:Metrics()
print(m.Runs, m.Skipped, m.AvgMs)

-- Clean up.
messageRule:Disable()
messageRule:Destroy()
```
