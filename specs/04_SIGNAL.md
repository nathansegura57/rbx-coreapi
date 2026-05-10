# 04 — Signal

Signal is a synchronous single-payload event stream.

## Public API

```luau
Signal.New(): Signal<T>
Signal.Never(): Signal<T>
Signal.After(seconds: number): Signal<nil>
Signal.Every(seconds: number): Signal<nil>
Signal.FromRoblox(rbxSignal: RBXScriptSignal, mapper: ((...any) -> T)?): Signal<T>
Signal.Merge(signals: { Signal<T> }): Signal<T>
Signal.Zip(signals: { Signal<any> }): Signal<{ any }>
Signal.Race(signals: { Signal<T> }): Signal<T>
Signal.Sequence(signals: { Signal<any> }, opts?): Signal<SequenceResult>
Signal.IsSignal(value: unknown): boolean
```

Methods:

```luau
signal:Connect(listener: (payload: T) -> ()): Connection
signal:Once(listener: (payload: T) -> ()): Connection
signal:Fire(payload: T): ()
signal:Wait(): T
signal:DisconnectAll(): ()
signal:Destroy(): ()
signal:IsDestroyed(): boolean

signal:Map(mapper: (T) -> U): Signal<U>
signal:Filter(predicate: (T) -> boolean): Signal<T>
signal:Scan(reducer: (A, T) -> A, seed: A): Signal<A>
signal:MergeMap(selector: (T) -> Signal<U>): Signal<U>
signal:SwitchMap(selector: (T) -> Signal<U>): Signal<U>
signal:Take(count: number): Signal<T>
signal:Skip(count: number): Signal<T>
signal:TakeWhile(predicate: (T) -> boolean): Signal<T>
signal:SkipWhile(predicate: (T) -> boolean): Signal<T>
signal:TakeUntil(stopper: Signal<any>): Signal<T>
signal:SkipUntil(starter: Signal<any>): Signal<T>
signal:Debounce(seconds: number): Signal<T>
signal:Throttle(seconds: number, opts?): Signal<T>
signal:Delay(seconds: number): Signal<T>
signal:BufferCount(count: number, step: number?): Signal<{ T }>
signal:BufferTime(seconds: number): Signal<{ T }>
signal:SampleBy(sampler: Signal<any>): Signal<T>
signal:ReplayCount(count: number): Signal<T>
signal:ReplayTime(seconds: number): Signal<T>
signal:ClearReplay(): Signal<T>
```

## Core semantics

- `Fire` is synchronous.
- Listeners are called in connection order.
- One payload value is delivered per fire.
- Nil payloads are allowed unless a specific method says otherwise.
- Listener errors route through `ErrorHandler`.
- A listener error must not prevent later listeners unless `ErrorHandler` policy throws.
- Disconnect during fire takes effect for future listener checks.
- Physical compaction may wait until fire depth returns to zero.
- Destroy is idempotent.
- Fire after destroy is a no-op.
- Connect after destroy errors.

## `New`

Creates a live signal with no listeners and no replay policy.

## `Never`

Creates a live signal that never emits by itself.

`Fire` on a never signal errors:

```text
Signal.Fire: cannot fire a never signal
```

`Connect`, `Once`, `Wait`, and operators are otherwise allowed.

## `Connect`

Requires live signal and function listener.

Behavior:

- appends listener
- returns Connection
- if replay policy exists, schedules replayed entries through `Scheduler.Defer`
- replayed entries check connection still connected before invoking

Errors:

```text
Signal.Connect: signal is destroyed
Signal.Connect: listener must be a function
```

## `Once`

Like Connect, but disconnects before first listener invocation.

Replay entries may trigger Once, but only the first delivered entry invokes listener.

## `Fire`

Behavior:

1. If destroyed: return.
2. If never: error.
3. If replay enabled: store payload.
4. Deliver payload to connected listeners synchronously.

Nil payload must be stored and delivered.

## `Wait`

Yields current coroutine until next fire.

Behavior:

- connects a temporary listener
- on next fire, disconnects and resumes caller with payload
- supports nil payload
- if signal is destroyed while waiting, resume with error through normal Luau error semantics or return a defined failure if you choose; choose one and document. Preferred: error `"Signal.Wait: signal destroyed"`.
- must be called inside a coroutine that can yield

## `DisconnectAll`

Disconnects all current listeners.

Behavior:

- signal remains live
- replay buffer is unchanged
- future connections still work

## `Destroy`

Behavior:

- disconnects all listeners
- clears replay buffer and policy
- cancels internal timers
- destroys derived cleanup hooks
- marks destroyed

## Operators

All operators create derived signals.

Default derived behavior:

- source destroy destroys derived
- derived destroy disconnects source subscription
- source replay is not consumed by operator subscriptions
- if derived needs replay, call replay on derived

### `Map`

For each payload, fires `mapper(payload)`.

Mapper errors route through `ErrorHandler`.

### `Filter`

Fires original payload only when predicate returns exactly true.

Predicate errors route through `ErrorHandler` and the payload is not emitted unless policy throws.

### `Scan`

Maintains accumulator.

On each payload:

```luau
acc = reducer(acc, payload)
derived:Fire(acc)
```

Reducer errors route through `ErrorHandler`.

### `MergeMap`

For each source payload:

- selector returns inner signal
- subscribe to inner
- all active inner signals can emit
- all inner connections are tracked until derived destroy or inner destroy

Selector must return live signal or error.

### `SwitchMap`

For each source payload:

- disconnect previous inner subscription
- selector returns new inner signal
- only latest inner signal emits

### `Take`

Requires positive count.

Emits first `count` payloads, then destroys derived after emitting the final allowed payload.

### `Skip`

Requires non-negative count.

Skips first `count` payloads.

Allow `count = 0`.

### `TakeWhile`

Emits while predicate returns true. First false payload is not emitted and destroys derived.

### `SkipWhile`

Skips while predicate returns true. First false payload is emitted and all later payloads emit.

### `TakeUntil`

Emits source until stopper fires, then destroys derived.

### `SkipUntil`

Ignores source until starter fires once, then emits future source payloads.

### `Debounce`

Requires seconds >= 0.

Each payload cancels previous pending emission. Latest payload emits after quiet period. Supports nil payload by tracking presence separately.

### `Throttle`

Requires seconds > 0.

Options:

```luau
{
    Leading: boolean?,
    Trailing: boolean?,
}
```

Defaults:

```luau
Leading = true
Trailing = true
```

Behavior:

- leading emits immediately when interval is open
- trailing emits latest suppressed payload after interval
- supports nil trailing payload
- if both false, emits nothing

### `Delay`

Requires seconds >= 0.

Every payload gets its own timer. Destroy cancels pending timers.

### `BufferCount`

Requires count > 0 and step > 0 if supplied.

Default step = count.

When buffer length >= count, emit first count values as array, then remove first step values.

### `BufferTime`

Requires seconds > 0.

Collects payloads during window. Emits non-empty array at flush time. Supports nil payloads by storing packed entries or presence wrappers.

### `SampleBy`

Stores latest source payload and emits it when sampler fires. Clears stored presence after sample. Supports nil source payloads.

### `ReplayCount`

Requires count > 0.

One replay policy allowed at a time. Stores latest count payloads. Returns same signal.

### `ReplayTime`

Requires seconds > 0.

Stores payloads whose timestamps are within the last seconds using `Scheduler.Now()`.

### `ClearReplay`

Clears replay entries and policy. Returns same signal.

## Static combinators

### `Merge`

Requires non-empty array of live signals.

Fires source payload when any source fires.

Destroying any source destroys merged. Destroying merged disconnects all source subscriptions.

### `Zip`

Requires non-empty array of live signals.

Waits for one payload from each source. Emits array in source order. Tracks slot presence separately so nil payloads work. Extra emissions from a source before round completion are ignored.

### `Race`

Requires non-empty array of live signals.

First source to emit becomes winner. Emit winning payload and disconnect losing subscriptions. Future winner emissions continue to pass through.

Destroying all candidates before winner destroys race. Destroying winner after selection destroys race.

### `Sequence`

Requires non-empty array of live signals.

Options:

```luau
{
    MinTimeBetween: number?,
    MaxTimeBetween: number?,
    MinTotalTime: number?,
    MaxTotalTime: number?,
    ResetOnMismatch: boolean?,
    FireOnMismatch: boolean?,
}
```

Defaults:

```luau
MinTimeBetween = 0
MaxTimeBetween = math.huge
MinTotalTime = 0
MaxTotalTime = math.huge
ResetOnMismatch = true
FireOnMismatch = false
```

Emits:

```luau
{
    Time: number,
    Completed: boolean,
}
```

Min/max between applies only between accepted steps, not before first step.
