# Signal API Reference

`Signal` is the reactive event-stream primitive for CoreAPI.

Place this module at:

```text
ReplicatedStorage/Shared/Kernel/Signal
```

A signal represents a push-based stream of values. Consumers connect listeners. Producers fire payloads. Operators derive new signals from existing ones without mutating the source.

`Signal` is the foundation for event-driven and reactive composition across CoreAPI systems.

It depends on:

```text
ReplicatedStorage/Shared/Kernel/Connection
ReplicatedStorage/Shared/Kernel/ErrorHandler
ReplicatedStorage/Shared/Kernel/Scheduler
```

Those dependencies define the lifecycle, runtime error-routing, and timing behavior of the signal system.

---

# Design Goals

`Signal` is designed to make event-driven code composable, deterministic, and lifecycle-safe.

It exists so that systems can express:

```luau
source
    :Filter(predicate)
    :Map(transform)
    :Debounce(0.2)
    :Connect(listener)
```

instead of manually wiring stateful listener graphs.

The module is designed around these principles:

- **Push-based events**: values flow from producers to listeners.
- **Composable operators**: transformations return derived signals instead of mutating sources.
- **Consistent lifecycle handles**: subscriptions return `Connection.Connection`.
- **Centralized failure routing**: listener and operator callback errors route through `ErrorHandler`.
- **Scheduler-backed timing**: timers, replay, delay, debounce, throttle, and buffer windows use `Scheduler`.
- **Deterministic teardown**: destroying a source destroys derived signals.
- **Replay as explicit policy**: past events are replayed only when requested.
- **Nil-safe payload semantics**: `nil` is a valid event payload.
- **Roblox interop**: `RBXScriptSignal` can be bridged into CoreAPI signal streams.

---

# Core Mental Model

A signal has three roles.

```text
producer
    ↓ Fire(payload)
signal
    ↓ Connect(listener)
consumer
```

Operators create new derived signals.

```text
source signal
    ↓ operator
derived signal
    ↓ operator
derived signal
    ↓ Connect
listener
```

Derived signals are owned by their source chain. When a source signal is destroyed, derived signals are destroyed as well.

---

# Importing

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Shared.Kernel.Signal)
```

---

# Relationship to Other Kernel Modules

## Relationship to `Connection`

Every listener registration returns a `Connection.Connection`.

```luau
local connection = signal:Connect(listener)

connection:Disconnect()
```

This makes listener lifecycle consistent with the rest of CoreAPI.

---

## Relationship to `ErrorHandler`

Listeners, mappers, predicates, reducers, selectors, and bridged Roblox mappers are user-provided runtime callbacks. If they throw, the failure routes through `ErrorHandler`.

This means:

- one listener failure does not stop other listeners;
- operator callback failures follow global error policy;
- production, test, and development behavior remain consistent.

---

## Relationship to `Scheduler`

Timing-based behavior uses `Scheduler`.

This includes:

- `After`;
- `Every`;
- replay delivery;
- `Debounce`;
- `Throttle`;
- `Delay`;
- `BufferTime`;
- deferred already-replayed emissions.

This makes Signal timing deterministic under mock schedulers.

---

# Exported Types

## `Signal.Listener<T>`

```luau
type Listener<T> = (payload: T) -> ()
```

A callback invoked when a signal fires. Listeners receive exactly one payload value. The payload may be `nil`. Return values are ignored.

---

## `Signal.Signal<T>`

```luau
type Signal<T> = opaque
```

A signal handle carrying payloads of type `T`.

Signals are opaque runtime handles. Consumers should use the public API instead of inspecting internal fields.

A signal may be:

- writable;
- derived;
- timer-backed;
- bridged from Roblox;
- replay-enabled;
- destroyed;
- unfirable, in the case of `Signal.Never`.

---

## `Signal.ReplayPolicy`

```luau
type ReplayPolicy = "Count" | "Time"
```

Controls how past events are replayed to new subscribers.

Use values from:

```luau
Signal.ReplayPolicy.Count
Signal.ReplayPolicy.Time
```

---

## `Signal.ThrottleOptions`

```luau
type ThrottleOptions = {
    Leading: boolean?,
    Trailing: boolean?,
}
```

Controls whether throttled output fires at the beginning and/or end of a throttle window.

Defaults:

```luau
Leading = true
Trailing = true
```

---

## `Signal.SequenceOptions`

```luau
type SequenceOptions = {
    MinTimeBetween: number?,
    MaxTimeBetween: number?,
    MinTotalTime: number?,
    MaxTotalTime: number?,
    ResetOnMismatch: boolean?,
    FireOnMismatch: boolean?,
}
```

Configures sequence recognition.

---

## `Signal.SequenceResult`

```luau
type SequenceResult = {
    Time: number,
    Completed: boolean,
}
```

Payload emitted by `Signal.Sequence`.

`Completed` indicates whether the sequence completed successfully or emitted because a mismatch was configured to fire. `Time` is the elapsed sequence duration.

---

# Public Constants

# `Signal.ReplayPolicy`

```luau
Signal.ReplayPolicy.Count
Signal.ReplayPolicy.Time
```

A frozen enum-like table of replay policy names.

---

# Constructors

# `Signal.New`

```luau
Signal.New<T>(): Signal.Signal<T>
```

Creates a new writable signal.

## Parameters

None.

## Returns

| Type | Description |
|---|---|
| `Signal.Signal<T>` | New writable signal. |

## Behavior

The returned signal can be fired manually with `Fire`. Listeners connected before a fire receive the payload synchronously.

## Example

```luau
local damageTaken = Signal.New<number>()

damageTaken:Connect(function(amount)
    print(`Took {amount} damage`)
end)

damageTaken:Fire(50)
```

---

# `Signal.Never`

```luau
Signal.Never(): Signal.Signal<never>
```

Creates a signal that can never be fired.

## Returns

| Type | Description |
|---|---|
| `Signal.Signal<never>` | Unfirable signal. |

## Behavior

`Signal.Never` is useful as a disabled event source, optional placeholder, or neutral branch in systems that expect a signal but should never receive events.

## Possible Errors

Calling `Fire` on a never signal raises:

```text
Signal.Fire: cannot fire a never signal
```

## Example

```luau
local disabledDamageSignal = Signal.Never()
```

---

# `Signal.After`

```luau
Signal.After(seconds: number): Signal.Signal<nil>
```

Creates a signal that fires once after a delay, then destroys itself.

## Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `seconds` | `number` | Yes | Delay duration in seconds. Must be non-negative. |

## Returns

| Type | Description |
|---|---|
| `Signal.Signal<nil>` | Timer signal that fires once. |

## Possible Usage Errors

```text
Signal.After: seconds must be non-negative
```

## Example

```luau
Signal.After(5):Connect(function()
    print("Five seconds elapsed")
end)
```

## Behavior

The signal emits `nil`. This is still a real event. Do not treat `nil` as “no event.”

---

# `Signal.Every`

```luau
Signal.Every(seconds: number): Signal.Signal<nil>
```

Creates a signal that fires repeatedly at a fixed interval until destroyed.

## Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `seconds` | `number` | Yes | Interval duration in seconds. Must be positive. |

## Returns

| Type | Description |
|---|---|
| `Signal.Signal<nil>` | Repeating timer signal. |

## Possible Usage Errors

```text
Signal.Every: seconds must be positive
```

## Example

```luau
local ticker = Signal.Every(1)

local connection = ticker:Connect(function()
    print("tick")
end)

ticker:Destroy()
```

Destroying the signal cancels future ticks.

---

# `Signal.FromRoblox`

```luau
Signal.FromRoblox<T>(
    robloxSignal: RBXScriptSignal,
    mapper: ((...any) -> T)?
): Signal.Signal<T>
```

Wraps a Roblox `RBXScriptSignal` as a CoreAPI signal.

## Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `robloxSignal` | `RBXScriptSignal` | Yes | Roblox signal to bridge. |
| `mapper` | `((...any) -> T)?` | No | Optional transform for raw Roblox arguments. |

## Returns

| Type | Description |
|---|---|
| `Signal.Signal<T>` | Signal that emits mapped Roblox events. |

## Behavior Without Mapper

When no mapper is provided, the payload is a packed table:

```luau
table.pack(...)
```

This preserves multiple arguments, argument order, nil values, and the `.n` field.

## Behavior With Mapper

When a mapper is provided, the mapper receives the raw Roblox signal arguments and returns the payload.

If the mapper errors:

1. the error routes through `ErrorHandler`;
2. the event is skipped;
3. the bridged signal does not fire for that Roblox event.

## Possible Usage Errors

```text
Signal.FromRoblox: expected RBXScriptSignal
Signal.FromRoblox: mapper must be a function or nil
```

## Example: Raw Roblox Arguments

```luau
local touched = Signal.FromRoblox(part.Touched)

touched:Connect(function(arguments)
    local otherPart = arguments[1]
    print(otherPart.Name)
end)
```

## Example: Mapped Payload

```luau
local humanoidDied = Signal.FromRoblox(humanoid.Died, function()
    return os.clock()
end)

humanoidDied:Connect(function(timestamp)
    print(`Humanoid died at {timestamp}`)
end)
```

---

# `Signal.IsSignal`

```luau
Signal.IsSignal(value: unknown): boolean
```

Returns whether a value is a live signal handle created by this module.

## Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `value` | `unknown` | Yes | Value to inspect. |

## Returns

| Type | Description |
|---|---|
| `boolean` | Whether the value is a live signal handle. |

## Example

```luau
if Signal.IsSignal(value) then
    print("value is a signal")
end
```

---

# Replay APIs

Replay causes newly connected listeners to receive previous events.

Replay delivery is deferred through `Scheduler.Defer`. This means replayed values do not fire synchronously inside `Connect`.

At most one replay policy may be active on a signal at a time.

---

# `signal:ReplayCount`

```luau
signal:ReplayCount(count: number): Signal.Signal<T>
```

Configures the signal to replay the most recent `count` events to new listeners.

## Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `count` | `number` | Yes | Number of events to remember. Must be a positive integer. |

## Returns

| Type | Description |
|---|---|
| `Signal.Signal<T>` | The same signal, for chaining. |

## Possible Usage Errors

```text
Signal.ReplayCount: count must be a positive integer
Signal.ReplayCount: signal is destroyed
Signal: only one replay policy may be applied
```

## Example

```luau
local recentMessages = Signal.New<string>():ReplayCount(10)

recentMessages:Fire("hello")
recentMessages:Fire("world")

recentMessages:Connect(function(message)
    print(message)
end)
```

The listener receives `"hello"` and `"world"` deferred through `Scheduler.Defer`.

---

# `signal:ReplayTime`

```luau
signal:ReplayTime(seconds: number): Signal.Signal<T>
```

Configures the signal to replay events fired within the last `seconds` seconds.

## Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `seconds` | `number` | Yes | Replay window duration. Must be positive. |

## Returns

| Type | Description |
|---|---|
| `Signal.Signal<T>` | The same signal, for chaining. |

## Possible Usage Errors

```text
Signal.ReplayTime: seconds must be positive
Signal.ReplayTime: signal is destroyed
Signal: only one replay policy may be applied
```

---

# `signal:ClearReplay`

```luau
signal:ClearReplay(): Signal.Signal<T>
```

Clears the replay buffer and removes the active replay policy.

## Returns

| Type | Description |
|---|---|
| `Signal.Signal<T>` | The same signal, for chaining. |

---

# Instance Methods

# `signal:Connect`

```luau
signal:Connect(listener: Signal.Listener<T>): Connection.Connection
```

Subscribes a listener to the signal.

## Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `listener` | `(payload: T) -> ()` | Yes | Function called for each event. |

## Returns

| Type | Description |
|---|---|
| `Connection.Connection` | Subscription handle. |

## Behavior

The listener is called every time the signal fires until the returned connection is disconnected, `DisconnectAll` is called, or the signal is destroyed.

Listener errors route through `ErrorHandler`. One listener failure does not prevent later listeners from running.

## Possible Usage Errors

```text
Signal.Connect: signal is destroyed
Signal.Connect: listener must be a function
```

## Example

```luau
local connection = signal:Connect(function(value)
    print(value)
end)

connection:Disconnect()
```

---

# `signal:Once`

```luau
signal:Once(listener: Signal.Listener<T>): Connection.Connection
```

Subscribes a listener that automatically disconnects after the first event.

## Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `listener` | `(payload: T) -> ()` | Yes | Function called once. |

## Returns

| Type | Description |
|---|---|
| `Connection.Connection` | Subscription handle. |

## Possible Usage Errors

```text
Signal.Once: signal is destroyed
Signal.Once: listener must be a function
```

## Example

```luau
signal:Once(function(value)
    print("first value:", value)
end)
```

---

# `signal:Fire`

```luau
signal:Fire(payload: T): ()
```

Fires the signal synchronously.

## Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `payload` | `T` | Yes | Event payload. May be `nil`. |

## Returns

Nothing.

## Behavior

All currently connected listeners are called before `Fire` returns. Each listener is protected independently.

## Possible Usage Errors

```text
Signal.Fire: cannot fire a never signal
```

---

# `signal:Wait`

```luau
signal:Wait(): T
```

Yields the current coroutine until the signal fires once.

## Returns

| Type | Description |
|---|---|
| `T` | Payload from the next signal fire. |

## Possible Usage Errors

```text
Signal.Wait: signal is destroyed
Signal.Wait: must be called from a yieldable coroutine
Signal.Wait: signal destroyed
```

`Signal.Wait: signal destroyed` is raised when the signal is destroyed while the coroutine is waiting.

## Example

```luau
task.spawn(function()
    local value = signal:Wait()
    print("waited value:", value)
end)
```

---

# `signal:DisconnectAll`

```luau
signal:DisconnectAll(): ()
```

Disconnects all current listeners without destroying the signal.

New listeners may still be connected afterward.

---

# `signal:Destroy`

```luau
signal:Destroy(): ()
```

Destroys the signal.

Destroying a signal:

1. marks the signal destroyed;
2. disconnects all listeners;
3. resumes active `Wait` calls with an error;
4. destroys derived signals owned by the signal;
5. cancels signal-owned scheduled work.

Destruction is idempotent.

---

# `signal:IsDestroyed`

```luau
signal:IsDestroyed(): boolean
```

Returns whether the signal has been destroyed.

## Returns

| Type | Description |
|---|---|
| `boolean` | Whether the signal is destroyed. |

---

# Operators

Operators return derived signals.

A derived signal:

- receives events from its source;
- applies transformation behavior;
- emits its own events;
- is destroyed when the source is destroyed.

Operators do not mutate the source signal.

---

# `signal:Map`

```luau
signal:Map<U>(mapper: (payload: T) -> U): Signal.Signal<U>
```

Transforms each payload.

If `mapper` throws, the error routes through `ErrorHandler` and that event is skipped.

## Example

```luau
local doubled = numbers:Map(function(number)
    return number * 2
end)
```

---

# `signal:Filter`

```luau
signal:Filter(predicate: (payload: T) -> boolean): Signal.Signal<T>
```

Forwards only payloads whose predicate returns `true`.

If the predicate throws, the error routes through `ErrorHandler` and that event is skipped.

## Example

```luau
local positive = numbers:Filter(function(number)
    return number > 0
end)
```

---

# `signal:Scan`

```luau
signal:Scan<Accumulator>(
    reducer: (accumulator: Accumulator, payload: T) -> Accumulator,
    seed: Accumulator
): Signal.Signal<Accumulator>
```

Accumulates state over time.

## Example

```luau
local runningTotal = numbers:Scan(function(total, number)
    return total + number
end, 0)
```

Each source event emits the new accumulator value.

---

# `signal:MergeMap`

```luau
signal:MergeMap<U>(selector: (payload: T) -> Signal.Signal<U>): Signal.Signal<U>
```

Maps each outer payload to an inner signal and forwards events from all active inner signals.

## Possible Errors

```text
Signal.MergeMap: selector must return a Signal
```

## Example

```luau
local projectiles = weaponIds:MergeMap(function(weaponId)
    return getProjectileSignalForWeapon(weaponId)
end)
```

Use this when concurrent inner streams are desired.

---

# `signal:SwitchMap`

```luau
signal:SwitchMap<U>(selector: (payload: T) -> Signal.Signal<U>): Signal.Signal<U>
```

Maps each outer payload to an inner signal, but only keeps the latest inner signal active.

## Possible Errors

```text
Signal.SwitchMap: selector must return a Signal
```

## Example

```luau
local results = queryChanged:SwitchMap(function(query)
    return search(query)
end)
```

When a new outer event arrives, the previous inner subscription is disconnected.

---

# `signal:Take`

```luau
signal:Take(count: number): Signal.Signal<T>
```

Forwards only the first `count` events, then destroys the derived signal.

## Possible Usage Errors

```text
Signal.Take: count must be a positive integer
```

---

# `signal:Skip`

```luau
signal:Skip(count: number): Signal.Signal<T>
```

Skips the first `count` events, then forwards all later events.

## Possible Usage Errors

```text
Signal.Skip: count must be a non-negative integer
```

---

# `signal:TakeWhile`

```luau
signal:TakeWhile(predicate: (payload: T) -> boolean): Signal.Signal<T>
```

Forwards events while the predicate returns `true`. The first `false` result destroys the derived signal. Predicate errors also destroy the derived signal after routing through `ErrorHandler`.

---

# `signal:SkipWhile`

```luau
signal:SkipWhile(predicate: (payload: T) -> boolean): Signal.Signal<T>
```

Skips events while the predicate returns `true`. Once the predicate returns `false`, all subsequent events are forwarded. If the predicate errors, the error routes through `ErrorHandler` and skipping stops.

---

# `signal:TakeUntil`

```luau
signal:TakeUntil(stopper: Signal.Signal<any>): Signal.Signal<T>
```

Forwards source events until `stopper` fires, then destroys the derived signal.

## Possible Usage Errors

```text
Signal.TakeUntil: stopper must be a live Signal
```

---

# `signal:SkipUntil`

```luau
signal:SkipUntil(starter: Signal.Signal<any>): Signal.Signal<T>
```

Skips source events until `starter` fires at least once.

## Possible Usage Errors

```text
Signal.SkipUntil: starter must be a live Signal
```

---

# `signal:Debounce`

```luau
signal:Debounce(seconds: number): Signal.Signal<T>
```

Collapses rapid bursts into one event emitted after no new input arrives for `seconds`.

## Possible Usage Errors

```text
Signal.Debounce: seconds must be non-negative
```

## Example

```luau
local settledInput = inputChanged:Debounce(0.3)
```

If multiple events arrive within the debounce window, only the most recent event is emitted.

---

# `signal:Throttle`

```luau
signal:Throttle(
    seconds: number,
    options: Signal.ThrottleOptions?
): Signal.Signal<T>
```

Limits emissions to at most one value per time window.

## Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `seconds` | `number` | Yes | Window duration. Must be positive. |
| `options` | `Signal.ThrottleOptions?` | No | Leading/trailing behavior. |

## Defaults

```luau
Leading = true
Trailing = true
```

## Possible Usage Errors

```text
Signal.Throttle: seconds must be positive
Signal.Throttle: opts must be a table or nil
Signal.Throttle: Leading must be a boolean or nil
Signal.Throttle: Trailing must be a boolean or nil
```

## Example: Leading Only

```luau
local leadingClicks = clicks:Throttle(1, {
    Trailing = false,
})
```

## Example: Trailing Only

```luau
local trailingClicks = clicks:Throttle(1, {
    Leading = false,
})
```

---

# `signal:Delay`

```luau
signal:Delay(seconds: number): Signal.Signal<T>
```

Re-emits each event after a delay. Each input event has its own scheduled delayed emission.

## Possible Usage Errors

```text
Signal.Delay: seconds must be non-negative
```

---

# `signal:BufferCount`

```luau
signal:BufferCount(count: number, step: number?): Signal.Signal<{ any }>
```

Collects events into count-based arrays.

## Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `count` | `number` | Yes | Buffer size. Must be a positive integer. |
| `step` | `number?` | No | Window slide step. Defaults to `count`. |

## Possible Usage Errors

```text
Signal.BufferCount: count must be a positive integer
Signal.BufferCount: step must be a positive integer
```

## Example: Non-Overlapping Windows

```luau
local windows = values:BufferCount(3)
```

Emits:

```luau
{ 1, 2, 3, n = 3 }
{ 4, 5, 6, n = 3 }
```

## Example: Sliding Windows

```luau
local sliding = values:BufferCount(3, 1)
```

Emits:

```luau
{ 1, 2, 3, n = 3 }
{ 2, 3, 4, n = 3 }
{ 3, 4, 5, n = 3 }
```

---

# `signal:BufferTime`

```luau
signal:BufferTime(seconds: number): Signal.Signal<{ any }>
```

Collects events over a time window, then emits a packed array.

## Possible Usage Errors

```text
Signal.BufferTime: seconds must be positive
```

---

# `signal:SampleBy`

```luau
signal:SampleBy(sampler: Signal.Signal<any>): Signal.Signal<T>
```

Emits the most recent source value whenever the sampler fires.

## Possible Usage Errors

```text
Signal.SampleBy: sampler must be a live Signal
```

If no source value has arrived since the last sample opportunity, no event is emitted.

---

# Static Combinators

# `Signal.Merge`

```luau
Signal.Merge(signals: { Signal.Signal<any> }): Signal.Signal<any>
```

Creates a signal that forwards events from any source signal.

## Possible Usage Errors

```text
Signal.Merge: signals must be a non-empty dense array of Signals
```

---

# `Signal.Zip`

```luau
Signal.Zip(signals: { Signal.Signal<any> }): Signal.Signal<{ any }>
```

Emits grouped arrays when every source has produced one new value.

`Zip` waits until each source has at least one queued event, then emits an array in source order.

## Possible Usage Errors

```text
Signal.Zip: signals must be a non-empty dense array of Signals
```

---

# `Signal.Race`

```luau
Signal.Race(signals: { Signal.Signal<any> }): Signal.Signal<any>
```

Mirrors whichever source signal fires first, then ignores the others.

## Possible Usage Errors

```text
Signal.Race: signals must be a non-empty dense array of Signals
```

---

# `Signal.Sequence`

```luau
Signal.Sequence(
    signals: { Signal.Signal<any> },
    options: Signal.SequenceOptions?
): Signal.Signal<Signal.SequenceResult>
```

Detects ordered signal sequences.

## Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `signals` | `{ Signal.Signal<any> }` | Yes | Non-empty ordered dense array of live signals. |
| `options` | `Signal.SequenceOptions?` | No | Timing and mismatch behavior. |

## Options

| Field | Type | Default | Description |
|---|---|---:|---|
| `MinTimeBetween` | `number?` | `0` | Minimum seconds between consecutive steps. |
| `MaxTimeBetween` | `number?` | `math.huge` | Maximum seconds between consecutive steps. |
| `MinTotalTime` | `number?` | `0` | Minimum total sequence duration. |
| `MaxTotalTime` | `number?` | `math.huge` | Maximum total sequence duration. |
| `ResetOnMismatch` | `boolean?` | `true` | Reset progress on out-of-order or timed-out step. |
| `FireOnMismatch` | `boolean?` | `false` | Emit a failed result on mismatch. |

## Possible Usage Errors

```text
Signal.Sequence: signals must be a non-empty dense array of Signals
Signal.Sequence: opts must be a table or nil
Signal.Sequence: timing options must be non-negative
Signal.Sequence: MaxTimeBetween must be >= MinTimeBetween
Signal.Sequence: MaxTotalTime must be >= MinTotalTime
Signal.Sequence: ResetOnMismatch must be a boolean or nil
Signal.Sequence: FireOnMismatch must be a boolean or nil
```

## Example: Double Tap

```luau
local doubleTap = Signal.Sequence({ tap, tap }, {
    MaxTimeBetween = 0.5,
})

doubleTap:Connect(function(result)
    if result.Completed then
        print(`double tap in {result.Time} seconds`)
    end
end)
```

---

# Behavior in Complex Cases

# `Fire` Is Synchronous

All listeners run before `Fire` returns.

# Listener Errors Do Not Stop Other Listeners

Each listener is protected independently. If one listener fails, its failure routes through `ErrorHandler`, and later listeners still run.

# Replay Delivery Is Deferred

Replay values are delivered with `Scheduler.Defer`. This prevents `Connect` from synchronously invoking historical events before the caller receives the returned connection.

# `nil` Is a Valid Payload

A signal firing `nil` is still a real event. This matters for `Wait`, replay, buffers, timers, `After`, and `Every`.

Do not use `payload ~= nil` as a proxy for whether an event occurred.

# Derived Signals Are Owned By Their Source

Destroying a source destroys derived signals. This prevents operator chains from leaking listeners or scheduled work.

# `Wait` Requires a Yieldable Coroutine

`Wait` yields. It must be called from a yieldable context such as `task.spawn` or another yieldable coroutine.

# Roblox Bridge Payloads Preserve Multiple Arguments

Without a mapper, `FromRoblox` emits a packed table. This avoids losing multiple values, nil holes, and argument count.

---

# Gotchas

# Do Not Forget To Disconnect

Every `Connect` and `Once` returns a `Connection`.

Store it when the listener lifetime matters.

```luau
local connection = signal:Connect(listener)

connection:Disconnect()
```

# Do Not Fire `Signal.Never`

`Signal.Never` exists to represent an impossible event source. Firing it is a usage error.

# Do Not Assume Operators Mutate Sources

Operators create derived signals.

```luau
local filtered = source:Filter(predicate)
```

does not change `source`.

# Do Not Depend On Replay Being Immediate

Replay is deferred. This is intentional and protects `Connect` from surprising synchronous side effects.

# Be Careful With Long Operator Chains

Long chains are valid, but each derived signal represents additional runtime work. Destroy the root or relevant derived signal when the pipeline is no longer needed.

---

# Testing Recommendations

A robust Signal test suite should cover:

1. `Signal.New` creates a live writable signal.
2. `Signal.Never` cannot be fired.
3. `Signal.After` fires once and destroys itself.
4. `Signal.Every` repeats until destroyed.
5. `FromRoblox` preserves raw arguments when no mapper exists.
6. `FromRoblox` uses mapped payloads when mapper exists.
7. `Connect` returns a valid `Connection`.
8. `Once` fires only once.
9. `Fire` calls all listeners synchronously.
10. Listener errors route through `ErrorHandler`.
11. `Wait` resumes with payload.
12. Destroying during wait raises.
13. Replay count replays only the last N values.
14. Replay time respects scheduler time.
15. Operators return derived signals.
16. Source destruction destroys derived signals.
17. Timing operators respect mock scheduler control.
18. Static combinators validate dense signal arrays.
19. `nil` payloads are preserved.
20. Buffers preserve `.n`.

---

# Best Practices

# Prefer Signals For Push-Based Events

Use signals when values are discrete events: button clicks, player damage, state changes, request completion, cooldown expiration.

# Prefer Stores For Persistent State

Signals represent events. They do not inherently remember current state unless replay is configured.

# Prefer Operators Over Manual Listener State

Good:

```luau
local positiveDoubled = numbers
    :Filter(function(number)
        return number > 0
    end)
    :Map(function(number)
        return number * 2
    end)
```

# Use `SwitchMap` For Latest-Only Workflows

Good use cases include search requests, selected entity streams, active tool events, and current target tracking.

# Use `MergeMap` For Concurrent Workflows

Good use cases include projectiles, parallel animations, many active entities, and overlapping requests.

# Use Replay Intentionally

Replay stores past events. Use it when late subscribers genuinely need historical events.

# Use `Signal.FromRoblox` At Boundaries

Bridge Roblox signals once at the boundary, then use CoreAPI signal operators internally.

---

# Full Example: Damage Pipeline

```luau
local damageTaken = Signal.New<number>()

local highDamage = damageTaken
    :Filter(function(amount)
        return amount >= 50
    end)
    :Map(function(amount)
        return {
            Amount = amount,
            Critical = amount >= 100,
        }
    end)

highDamage:Connect(function(event)
    print(event.Amount, event.Critical)
end)

damageTaken:Fire(25)
damageTaken:Fire(75)
```

Only the second event reaches `highDamage`.

---

# Full Example: Search With `SwitchMap`

```luau
local queryChanged = Signal.New<string>()

local searchResults = queryChanged:SwitchMap(function(query)
    return createSearchSignal(query)
end)

searchResults:Connect(function(results)
    renderResults(results)
end)
```

When a new query arrives, the previous search stream is disconnected.

---

# Full Example: Burst Input With `Debounce`

```luau
local inputChanged = Signal.New<string>()

local settledInput = inputChanged:Debounce(0.25)

settledInput:Connect(function(text)
    submitSearch(text)
end)
```

Rapid input produces one final event.

---

# Full Example: Component Cleanup

```luau
local connections = {}

table.insert(connections, signal:Connect(listener))
table.insert(connections, otherSignal:Connect(otherListener))

local function destroy()
    for _, connection in connections do
        connection:Disconnect()
    end

    table.clear(connections)
end
```

---

# Full Example: Replay For Late Subscribers

```luau
local messages = Signal.New<string>():ReplayCount(5)

messages:Fire("A")
messages:Fire("B")

messages:Connect(function(message)
    print(message)
end)
```

The listener receives `"A"` and `"B"` through deferred replay.

---

# Summary

Use `Signal` whenever a system needs a typed, composable, push-based event stream.

Use:

- `New` for writable event sources;
- `Never` for disabled event sources;
- `After` and `Every` for timer streams;
- `FromRoblox` for Roblox event boundaries;
- `Connect` and `Once` for subscriptions;
- `Fire` for synchronous emission;
- `Wait` for coroutine-based one-shot waiting;
- replay APIs for late subscriber history;
- operators for derived streams;
- static combinators for multi-signal composition.

The result is a declarative reactive event system that integrates with Kernel lifecycle, timing, and error-handling semantics.
