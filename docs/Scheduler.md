# Scheduler

The time and frame-scheduling abstraction. Every module that touches time calls `Scheduler` exclusively — never `task.defer`, `task.delay`, or `RunService.Heartbeat` directly. Swapping in a `MockScheduler` at test time gives you deterministic control over all async behavior in the entire library.

---

## API Reference

### `Scheduler.Defer(fn)`

Schedules `fn` to run after the current frame, wrapped in error protection. Errors from `fn` are routed through `ErrorHandler`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `fn` | `() -> ()` | The function to defer |

**Returns:** `any?` — an opaque handle that can be passed to `Scheduler.Cancel`.

**Errors:**
- `Scheduler.Defer: fn must be a function`

```luau
Scheduler.Defer(function()
    print("runs next frame")
end)
```

---

### `Scheduler.Delay(seconds, fn)`

Schedules `fn` to run after `seconds` seconds, wrapped in error protection.

| Parameter | Type | Description |
|-----------|------|-------------|
| `seconds` | `number` | Delay in seconds; must be `>= 0` |
| `fn` | `() -> ()` | The function to call after the delay |

**Returns:** `any?` — an opaque timer handle for `Scheduler.Cancel`.

**Errors:**
- `Scheduler.Delay: seconds must be non-negative`
- `Scheduler.Delay: fn must be a function`

```luau
local handle = Scheduler.Delay(2, function()
    print("2 seconds later")
end)

-- Cancel before it fires:
Scheduler.Cancel(handle)
```

---

### `Scheduler.Cancel(handle)`

Cancels a pending `Defer` or `Delay` handle. Safe to call with `nil` or an already-fired handle.

| Parameter | Type | Description |
|-----------|------|-------------|
| `handle` | `any?` | Handle returned by `Defer` or `Delay`. May be `nil`. |

**Returns:** nothing

```luau
local h = Scheduler.Delay(5, cleanup)
-- Changed our mind:
Scheduler.Cancel(h)
```

---

### `Scheduler.Now()`

Returns the current elapsed time (seconds since server start) from the active driver.

**Returns:** `number`

**Errors:**
- `Scheduler.Now: driver returned non-number` — custom driver returned a non-numeric value

```luau
local t0 = Scheduler.Now()
-- ... some work ...
local elapsed = Scheduler.Now() - t0
```

---

### `Scheduler.OnStep(fn)`

Connects `fn` to the frame step (Heartbeat) event. Called once per frame with `dt` (delta time in seconds). Errors from `fn` are routed through `ErrorHandler`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `fn` | `(dt: number) -> ()` | Frame callback |

**Returns:** `Connection.Connection` — disconnect to unsubscribe.

**Errors:**
- `Scheduler.OnStep: fn must be a function`
- `Scheduler.OnStep: no step driver available` — running outside Roblox without a custom driver that implements `OnStep`
- `Scheduler.OnStep: driver must return Connection` — custom driver returned something other than a `Connection`

```luau
local conn = Scheduler.OnStep(function(dt)
    print("frame:", dt)
end)
-- later:
conn:Disconnect()
```

---

### `Scheduler.SetDriver(driver)`

Replaces the active driver with a custom implementation. Any field may be omitted; missing fields fall back to the Roblox defaults.

| Parameter | Type | Description |
|-----------|------|-------------|
| `driver` | `Driver` | Partial driver table — see below |

**`Driver` fields** (all optional):

| Field | Type | Description |
|-------|------|-------------|
| `Defer` | `((() -> ()) -> any)?` | Defer implementation |
| `Delay` | `((number, () -> ()) -> any)?` | Delay implementation |
| `Cancel` | `((any) -> ())?` | Cancel implementation |
| `Now` | `(() -> number)?` | Current time implementation |
| `OnStep` | `(((number) -> ()) -> Connection)?` | Frame step implementation |

**Errors:**
- `Scheduler.SetDriver: driver must be a table`
- `Scheduler.SetDriver: {field} must be a function or nil` — a field was present but not a function

```luau
local queue: { () -> () } = {}
local fakeTime = 0

Scheduler.SetDriver({
    Defer = function(fn) table.insert(queue, fn) end,
    Delay = function(_s, fn) table.insert(queue, fn) end,  -- ignores time in this simple mock
    Cancel = function(_h) end,
    Now = function() return fakeTime end,
})

-- Flush manually:
for _, fn in queue do fn() end
table.clear(queue)
```

---

### `Scheduler.ResetDriver()`

Restores the default Roblox driver (`task.defer`, `task.delay`, `task.cancel`, `time()`, `RunService.Heartbeat`).

```luau
Scheduler.ResetDriver()
```

---

## Driver Type

```luau
export type Driver = {
    Defer: ((() -> ()) -> any)?,
    Delay: ((number, () -> ()) -> any)?,
    Cancel: ((any) -> ())?,
    Now: (() -> number)?,
    OnStep: (((number) -> ()) -> Connection.Connection)?,
}
```

---

## Testing with MockScheduler

`tests/TestKit.luau` provides `ctx.Mock`, which installs a `MockScheduler`. Use it to control time and flush deferred callbacks synchronously:

```luau
local TestKit = require(path.to.tests.TestKit)

local suite = TestKit.Suite("Scheduler tests")

suite:Test("deferred callback fires on flush", function(ctx)
    local fired = false
    Scheduler.Defer(function() fired = true end)
    ctx:Expect(fired):ToBe(false)   -- not yet
    ctx.Mock:Flush()
    ctx:Expect(fired):ToBe(true)    -- now it ran
end)

suite:Test("delay respects time", function(ctx)
    local fired = false
    Scheduler.Delay(3, function() fired = true end)
    ctx.Mock:Advance(2)
    ctx:Expect(fired):ToBe(false)
    ctx.Mock:Advance(2)             -- total 4s → fires
    ctx:Expect(fired):ToBe(true)
end)
```

---

## Gotchas

- **Never call Roblox primitives directly.** All CoreAPI modules call `Scheduler.*` only. Tests that call `task.defer` or `time()` directly bypass the mock and will behave non-deterministically.
- **`OnStep` is unavailable without a Roblox driver.** Outside of Roblox (e.g. a standalone Luau runtime), `OnStep` is `nil` in the default driver. Call `SetDriver` with a custom `OnStep` if you need frame callbacks in that environment.
- **`Now()` falls back to `0` on driver error.** If the driver's `Now` function throws and the policy is not `Throw`, `Scheduler.Now` returns `0` rather than propagating the failure.
- **Errors from scheduled callbacks are routed, not rethrown.** `Defer` and `Delay` wrap callbacks in pcall and call `ErrorHandler.Report`. The error reaches your reporter, but does not bubble up from the scheduling call site.
