# Signal

A reactive event stream. Signals are the fundamental push-based primitive in CoreAPI: fire a value, every connected listener receives it. Operators return new derived signals, enabling composable pipelines without mutation.

---

## API Reference

### Constructors

#### `Signal.New()`

Creates a new writable signal.

**Returns:** `Signal<unknown>`

```luau
local onDamage = Signal.New()
onDamage:Connect(function(amount) print("took", amount, "damage") end)
onDamage:Fire(50)  -- prints: took 50 damage
```

---

#### `Signal.Never()`

Creates a signal that can never be fired. Useful as a placeholder or disabled event source.

**Returns:** `Signal<never>`

**Errors if fired:**
- `Signal.Fire: cannot fire a never signal`

---

#### `Signal.After(seconds)`

Creates a signal that fires once after `seconds` seconds, then destroys itself.

| Parameter | Type | Description |
|-----------|------|-------------|
| `seconds` | `number` | Delay; must be `>= 0` |

**Returns:** `Signal<nil>`

**Errors:**
- `Signal.After: seconds must be non-negative`

```luau
local alarm = Signal.After(5)
alarm:Connect(function() print("5 seconds elapsed") end)
```

---

#### `Signal.Every(seconds)`

Creates a signal that fires every `seconds` seconds indefinitely until destroyed.

| Parameter | Type | Description |
|-----------|------|-------------|
| `seconds` | `number` | Interval; must be `> 0` |

**Returns:** `Signal<nil>`

**Errors:**
- `Signal.Every: seconds must be positive`

```luau
local ticker = Signal.Every(1)
ticker:Connect(function() print("tick") end)
-- later:
ticker:Destroy()
```

---

#### `Signal.FromRoblox(rbxSignal, mapper?)`

Wraps a `RBXScriptSignal`. If `mapper` is provided, its return value becomes the payload; errors from `mapper` are routed through `ErrorHandler` and the fire is skipped. Without a mapper, the payload is `table.pack(...)` of the raw Roblox arguments.

| Parameter | Type | Description |
|-----------|------|-------------|
| `rbxSignal` | `RBXScriptSignal` | The Roblox signal to bridge |
| `mapper` | `((...any) -> any)?` | Optional transform applied to the raw args |

**Returns:** `Signal<any>`

**Errors:**
- `Signal.FromRoblox: expected RBXScriptSignal`
- `Signal.FromRoblox: mapper must be a function or nil`

```luau
-- Without mapper: payload is table.pack(...)
local onTouch = Signal.FromRoblox(part.Touched)
onTouch:Connect(function(args) print(args[1].Name) end)

-- With mapper: payload is the mapped value
local onHumanoidDied = Signal.FromRoblox(humanoid.Died, function()
    return os.clock()
end)
```

---

#### `Signal.IsSignal(value)`

Returns `true` if `value` is a live Signal handle.

| Parameter | Type | Description |
|-----------|------|-------------|
| `value` | `unknown` | Any value |

**Returns:** `boolean`

---

### Replay Policies

Replay causes newly connected listeners to receive past events immediately (deferred via `Scheduler.Defer`). At most one replay policy may be set per signal.

#### `Signal.ReplayPolicy`

```luau
Signal.ReplayPolicy.Count  -- replay the last N events
Signal.ReplayPolicy.Time   -- replay events from the past N seconds
```

---

#### `handle:ReplayCount(count)`

Replays the last `count` events to each new subscriber.

| Parameter | Type | Description |
|-----------|------|-------------|
| `count` | `number` | Positive integer |

**Returns:** `self` (for chaining)

**Errors:**
- `Signal.ReplayCount: count must be a positive integer`
- `Signal.ReplayCount: signal is destroyed`
- `Signal: only one replay policy may be applied`

```luau
local recent = Signal.New()
recent:ReplayCount(3)  -- new listeners get up to 3 past events
```

---

#### `handle:ReplayTime(seconds)`

Replays events that occurred within the last `seconds` seconds to each new subscriber.

| Parameter | Type | Description |
|-----------|------|-------------|
| `seconds` | `number` | Must be `> 0` |

**Returns:** `self`

**Errors:**
- `Signal.ReplayTime: seconds must be positive`
- `Signal.ReplayTime: signal is destroyed`
- `Signal: only one replay policy may be applied`

---

#### `handle:ClearReplay()`

Clears the replay buffer and removes the replay policy from this signal.

**Returns:** `self`

---

### Instance Methods

#### `handle:Connect(listener)`

Subscribes `listener` to receive payloads. Errors from `listener` are routed through `ErrorHandler`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `listener` | `(T) -> ()` | Called on each fire |

**Returns:** `Connection.Connection`

**Errors:**
- `Signal.Connect: signal is destroyed`
- `Signal.Connect: listener must be a function`

```luau
local conn = signal:Connect(function(value)
    print("received:", value)
end)
conn:Disconnect()
```

---

#### `handle:Once(listener)`

Like `Connect`, but disconnects automatically after the first fire.

| Parameter | Type | Description |
|-----------|------|-------------|
| `listener` | `(T) -> ()` | Called once |

**Returns:** `Connection.Connection`

**Errors:**
- `Signal.Once: signal is destroyed`
- `Signal.Once: listener must be a function`

```luau
signal:Once(function(v)
    print("first fire only:", v)
end)
```

---

#### `handle:Fire(payload)`

Fires the signal, calling all connected listeners synchronously.

| Parameter | Type | Description |
|-----------|------|-------------|
| `payload` | `T` | Any value, including `nil` |

**Errors:**
- `Signal.Fire: cannot fire a never signal`

---

#### `handle:Wait()`

Yields the current coroutine until the signal fires once, then returns the payload. If the signal is destroyed while waiting, throws.

**Returns:** `T`

**Errors:**
- `Signal.Wait: signal is destroyed`
- `Signal.Wait: must be called from a yieldable coroutine`
- `Signal.Wait: signal destroyed` — signal was destroyed during the wait

```luau
-- Inside a Task coroutine:
local value = signal:Wait()
```

---

#### `handle:DisconnectAll()`

Disconnects all listeners without destroying the signal. New connections may still be added afterward.

---

#### `handle:Destroy()`

Destroys the signal. All listeners are disconnected; any `Wait` calls are resumed with an error. Derived signals registered via `connectDerived` are also destroyed.

Idempotent — safe to call multiple times.

---

#### `handle:IsDestroyed()`

Returns `true` if the signal has been destroyed.

**Returns:** `boolean`

---

### Operators

All operators return a **new derived signal** that is automatically destroyed when the source signal is destroyed.

---

#### `handle:Map(mapper)`

Transforms each payload through `mapper`. Errors from `mapper` are routed through `ErrorHandler`; the event is skipped on error.

```luau
local doubled = numbers:Map(function(n) return n * 2 end)
```

---

#### `handle:Filter(predicate)`

Only forwards payloads where `predicate` returns `true`. Errors skip the event.

```luau
local positive = numbers:Filter(function(n) return n > 0 end)
```

---

#### `handle:Scan(reducer, seed)`

Accumulates payloads using `reducer(accumulator, payload) -> newAccumulator`. The derived signal emits the running accumulator after each event.

```luau
local sum = numbers:Scan(function(acc, n) return acc + n end, 0)
```

---

#### `handle:MergeMap(selector)`

For each payload, calls `selector` to produce an inner Signal. Events from all active inner signals are forwarded.

```luau
local merged = outer:MergeMap(function(id)
    return getSignalForId(id)
end)
```

**Errors (from selector):**
- `Signal.MergeMap: selector must return a Signal`

---

#### `handle:SwitchMap(selector)`

Like `MergeMap`, but only the most recent inner signal is active. When a new outer event arrives, the previous inner signal is silently unsubscribed.

```luau
local switched = outer:SwitchMap(function(query)
    return searchSignal(query)
end)
```

**Errors (from selector):**
- `Signal.SwitchMap: selector must return a Signal`

---

#### `handle:Take(count)`

Forwards only the first `count` events, then destroys itself.

| Parameter | Type | Description |
|-----------|------|-------------|
| `count` | `number` | Positive integer |

**Errors:**
- `Signal.Take: count must be a positive integer`

---

#### `handle:Skip(count)`

Skips the first `count` events, then forwards all subsequent ones.

| Parameter | Type | Description |
|-----------|------|-------------|
| `count` | `number` | Non-negative integer |

**Errors:**
- `Signal.Skip: count must be a non-negative integer`

---

#### `handle:TakeWhile(predicate)`

Forwards events while `predicate` returns `true`. The first `false` result destroys the derived signal. Errors from `predicate` also destroy it.

---

#### `handle:SkipWhile(predicate)`

Skips events while `predicate` returns `true`. Once `predicate` returns `false` (or errors), all subsequent events are forwarded.

---

#### `handle:TakeUntil(stopper)`

Forwards events until `stopper` fires, then destroys itself.

| Parameter | Type | Description |
|-----------|------|-------------|
| `stopper` | `Signal<any>` | Must be a live Signal |

**Errors:**
- `Signal.TakeUntil: stopper must be a live Signal`

---

#### `handle:SkipUntil(starter)`

Skips all events until `starter` fires at least once.

| Parameter | Type | Description |
|-----------|------|-------------|
| `starter` | `Signal<any>` | Must be a live Signal |

**Errors:**
- `Signal.SkipUntil: starter must be a live Signal`

---

#### `handle:Debounce(seconds)`

Collapses rapid bursts into a single event fired `seconds` after the last input.

| Parameter | Type | Description |
|-----------|------|-------------|
| `seconds` | `number` | Must be `>= 0` |

**Errors:**
- `Signal.Debounce: seconds must be non-negative`

```luau
local settled = input:Debounce(0.3)
-- fires 300 ms after the last rapid input event
```

---

#### `handle:Throttle(seconds, opts?)`

Limits the derived signal to at most one event per `seconds`-second window.

| Parameter | Type | Description |
|-----------|------|-------------|
| `seconds` | `number` | Must be `> 0` |
| `opts` | `ThrottleOptions?` | Optional `{ Leading: boolean?, Trailing: boolean? }` |

Default: `Leading = true, Trailing = true`.

**Errors:**
- `Signal.Throttle: seconds must be positive`
- `Signal.Throttle: opts must be a table or nil`
- `Signal.Throttle: Leading must be a boolean or nil`
- `Signal.Throttle: Trailing must be a boolean or nil`

```luau
-- Leading-only: fires immediately on first input, ignores rest of window.
local leading = clicks:Throttle(1, { Trailing = false })

-- Trailing-only: fires at end of window with the last seen value.
local trailing = clicks:Throttle(1, { Leading = false })
```

---

#### `handle:Delay(seconds)`

Re-emits each event after a `seconds`-second delay. Multiple in-flight events are tracked independently.

| Parameter | Type | Description |
|-----------|------|-------------|
| `seconds` | `number` | Must be `>= 0` |

**Errors:**
- `Signal.Delay: seconds must be non-negative`

---

#### `handle:BufferCount(count, step?)`

Accumulates events into arrays of size `count`. When `step` is given, the window slides by `step` (overlapping windows). The payload is a packed array with `.n` set.

| Parameter | Type | Description |
|-----------|------|-------------|
| `count` | `number` | Buffer size; positive integer |
| `step` | `number?` | Slide step; defaults to `count` |

**Errors:**
- `Signal.BufferCount: count must be a positive integer`
- `Signal.BufferCount: step must be a positive integer`

```luau
local windows = values:BufferCount(3)
-- fires {1,2,3}, {4,5,6}, ... (non-overlapping)

local sliding = values:BufferCount(3, 1)
-- fires {1,2,3}, {2,3,4}, {3,4,5}, ... (overlapping)
```

---

#### `handle:BufferTime(seconds)`

Accumulates events over a `seconds`-second window, then emits the collected array.

| Parameter | Type | Description |
|-----------|------|-------------|
| `seconds` | `number` | Must be `> 0` |

**Errors:**
- `Signal.BufferTime: seconds must be positive`

---

#### `handle:SampleBy(sampler)`

Emits the most recent value from this signal whenever `sampler` fires. Skips if no value has arrived since the last sample.

| Parameter | Type | Description |
|-----------|------|-------------|
| `sampler` | `Signal<any>` | Must be a live Signal |

**Errors:**
- `Signal.SampleBy: sampler must be a live Signal`

---

### Static Combinators

#### `Signal.Merge(signals)`

Creates a signal that forwards events from any of the source signals.

| Parameter | Type | Description |
|-----------|------|-------------|
| `signals` | `{ Signal<any> }` | Non-empty array of live Signals |

**Returns:** `Signal<any>`

**Errors:**
- `Signal.Merge: signals must be a non-empty dense array of Signals`

```luau
local combined = Signal.Merge({ onAttack, onHeal, onMove })
```

---

#### `Signal.Zip(signals)`

Fires once every time all source signals have each emitted one new event. The payload is an array `{ [1] = v1, [2] = v2, ..., n = count }` in source order.

| Parameter | Type | Description |
|-----------|------|-------------|
| `signals` | `{ Signal<any> }` | Non-empty array of live Signals |

**Returns:** `Signal<{ any }>`

**Errors:**
- `Signal.Zip: signals must be a non-empty dense array of Signals`

```luau
local zipped = Signal.Zip({ xSignal, ySignal })
zipped:Connect(function(pair)
    print(pair[1], pair[2])  -- matched pair
end)
```

---

#### `Signal.Race(signals)`

Creates a signal that mirrors whichever source fires first, then ignores all others.

| Parameter | Type | Description |
|-----------|------|-------------|
| `signals` | `{ Signal<any> }` | Non-empty array of live Signals |

**Returns:** `Signal<any>`

**Errors:**
- `Signal.Race: signals must be a non-empty dense array of Signals`

---

#### `Signal.Sequence(signals, opts?)`

Detects when signals fire in order. The derived signal fires a `{ Time: number, Completed: boolean }` result when the sequence completes (or mismatches, if `FireOnMismatch = true`).

| Parameter | Type | Description |
|-----------|------|-------------|
| `signals` | `{ Signal<any> }` | Non-empty ordered array |
| `opts` | `SequenceOptions?` | Timing and behavior options |

**`SequenceOptions` fields:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `MinTimeBetween` | `number?` | `0` | Minimum seconds between consecutive steps |
| `MaxTimeBetween` | `number?` | `math.huge` | Maximum seconds between consecutive steps |
| `MinTotalTime` | `number?` | `0` | Minimum total sequence duration |
| `MaxTotalTime` | `number?` | `math.huge` | Maximum total sequence duration |
| `ResetOnMismatch` | `boolean?` | `true` | Reset progress on out-of-order or timed-out step |
| `FireOnMismatch` | `boolean?` | `false` | Emit `{ Completed = false }` on mismatch |

**Returns:** `Signal<SequenceResult>`

**Errors:**
- `Signal.Sequence: signals must be a non-empty dense array of Signals`
- `Signal.Sequence: opts must be a table or nil`
- `Signal.Sequence: timing options must be non-negative`
- `Signal.Sequence: MaxTimeBetween must be >= MinTimeBetween`
- `Signal.Sequence: MaxTotalTime must be >= MinTotalTime`
- `Signal.Sequence: ResetOnMismatch must be a boolean or nil`
- `Signal.Sequence: FireOnMismatch must be a boolean or nil`

```luau
-- Detect double-tap: two taps within 0.5s of each other.
local doubleTap = Signal.Sequence({ tap, tap }, {
    MaxTimeBetween = 0.5,
})
doubleTap:Connect(function(result)
    if result.Completed then
        print("double tap! in", result.Time, "seconds")
    end
end)
```

---

## Gotchas

- **`Fire` is synchronous.** All listeners run before `Fire` returns. Avoid mutating signal or subscription state inside a listener during a fire.
- **Derived signals are destroyed when the source is destroyed.** Chains like `src:Filter(...):Map(...)` are fully cleaned up when `src:Destroy()` is called.
- **Replay fires are deferred, not immediate.** When `ReplayCount` or `ReplayTime` is set, new subscribers receive past events via `Scheduler.Defer` — they do not receive them synchronously inside `Connect`.
- **`Wait` must be called from a yieldable coroutine.** Task coroutines are yieldable; module-level or non-coroutine code is not.
- **`nil` is a valid payload.** Signals distinguish between "no event" and "event with nil payload" using internal presence tracking. Do not check `payload ~= nil` as a signal-fired indicator.
- **`Signal.Never()` is truly unfirable.** Calling `Fire` on it throws, making it a safe "no-op" source for optional event wiring.
- **Listener errors do not stop other listeners.** Each listener is wrapped in `ErrorHandler.Protect`; one error is routed but does not prevent subsequent listeners from running.
