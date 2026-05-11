# 05 — Signal Specification

`Signal` is a synchronous single-payload event stream.

It supports direct subscriptions, waiting, replay, timing helpers, and stream operators.

## Public API

```luau
Signal.New<T>(): Signal.Signal<T>
Signal.Never<T>(): Signal.Signal<T>
Signal.After(seconds: number): Signal.Signal<nil>
Signal.Every(seconds: number): Signal.Signal<nil>
Signal.FromRoblox<T>(rbxSignal: RBXScriptSignal, mapper: ((...any) -> T)?): Signal.Signal<T>
Signal.Merge<T>(signals: { Signal.Signal<T> }): Signal.Signal<T>
Signal.Zip(signals: { Signal.Signal<any> }): Signal.Signal<{ any }>
Signal.Race<T>(signals: { Signal.Signal<T> }): Signal.Signal<T>
Signal.Sequence(signals: { Signal.Signal<any> }, opts: SequenceOptions?): Signal.Signal<SequenceResult>
Signal.IsSignal(value: unknown): boolean
```

## Methods

```luau
signal:Connect(listener: (payload: T) -> ()): Connection.Connection
signal:Once(listener: (payload: T) -> ()): Connection.Connection
signal:Fire(payload: T): ()
signal:Wait(): T
signal:DisconnectAll(): ()
signal:Destroy(): ()
signal:IsDestroyed(): boolean

signal:Map<U>(mapper: (T) -> U): Signal.Signal<U>
signal:Filter(predicate: (T) -> boolean): Signal.Signal<T>
signal:Scan<A>(reducer: (A, T) -> A, seed: A): Signal.Signal<A>
signal:MergeMap<U>(selector: (T) -> Signal.Signal<U>): Signal.Signal<U>
signal:SwitchMap<U>(selector: (T) -> Signal.Signal<U>): Signal.Signal<U>
signal:Take(count: number): Signal.Signal<T>
signal:Skip(count: number): Signal.Signal<T>
signal:TakeWhile(predicate: (T) -> boolean): Signal.Signal<T>
signal:SkipWhile(predicate: (T) -> boolean): Signal.Signal<T>
signal:TakeUntil(stopper: Signal.Signal<any>): Signal.Signal<T>
signal:SkipUntil(starter: Signal.Signal<any>): Signal.Signal<T>
signal:Debounce(seconds: number): Signal.Signal<T>
signal:Throttle(seconds: number, opts: ThrottleOptions?): Signal.Signal<T>
signal:Delay(seconds: number): Signal.Signal<T>
signal:BufferCount(count: number, step: number?): Signal.Signal<{ T }>
signal:BufferTime(seconds: number): Signal.Signal<{ T }>
signal:SampleBy(sampler: Signal.Signal<any>): Signal.Signal<T>
signal:ReplayCount(count: number): Signal.Signal<T>
signal:ReplayTime(seconds: number): Signal.Signal<T>
signal:ClearReplay(): Signal.Signal<T>
```

## Types

```luau
export type Signal<T> = {
    Connect: (self: Signal<T>, listener: (T) -> ()) -> Connection.Connection,
    Once: (self: Signal<T>, listener: (T) -> ()) -> Connection.Connection,
    Fire: (self: Signal<T>, payload: T) -> (),
    Wait: (self: Signal<T>) -> T,
    DisconnectAll: (self: Signal<T>) -> (),
    Destroy: (self: Signal<T>) -> (),
    IsDestroyed: (self: Signal<T>) -> boolean,
}

export type ThrottleOptions = {
    Leading: boolean?,
    Trailing: boolean?,
}

export type SequenceOptions = {
    MinTimeBetween: number?,
    MaxTimeBetween: number?,
    MinTotalTime: number?,
    MaxTotalTime: number?,
    ResetOnMismatch: boolean?,
    FireOnMismatch: boolean?,
}

export type SequenceResult = {
    Time: number,
    Completed: boolean,
}
```

## Core semantics

- `Fire` is synchronous.
- Listeners are called in connection order.
- One payload value is delivered per fire.
- Nil payloads are allowed unless a method explicitly rejects them.
- Listener errors route through `ErrorHandler`.
- If `ErrorHandler` policy is `"Throw"`, delivery stops because the thrown error propagates.
- If policy is not `"Throw"`, later listeners still run.
- Disconnect during fire takes effect before the listener is considered for future invocations.
- Physical compaction of disconnected listeners may wait until fire depth returns to zero.
- Re-entrant `Fire` is allowed.
- Destroy is idempotent.
- Fire after destroy is a no-op.
- Connect after destroy errors.

## Handle model

Signal handles may be opaque frozen tables.

If opaque handles are used:

- `getmetatable(signal)` returns protected string `"Signal"`
- assigning fields errors:

```text
Signal: '<field>' is read-only
```

## `Signal.New()`

Creates a live signal.

### Behavior

- no listeners
- no replay policy
- not destroyed
- not never
- no internal timers

## `Signal.Never()`

Creates a live signal that never emits by itself.

### Behavior

- `Connect`, `Once`, `Wait`, and operators are allowed.
- `Fire` errors:

```text
Signal.Fire: cannot fire a never signal
```

- Destroy works normally.

## `Signal.After(seconds)`

Creates a signal that fires once after `seconds`, emits `nil`, then destroys itself.

### Validation

`seconds >= 0`.

Error:

```text
Signal.After: seconds must be non-negative
```

### Behavior

- Use `Scheduler.Delay(seconds, callback)`.
- When timer fires:
  1. if signal is destroyed, return
  2. fire `nil`
  3. destroy signal
- Destroy before timer fires cancels timer through `Scheduler.Cancel`.

## `Signal.Every(seconds)`

Creates a signal that emits `nil` every `seconds` until destroyed.

### Validation

`seconds > 0`.

Error:

```text
Signal.Every: seconds must be positive
```

### Behavior

- Schedule next tick using `Scheduler.Delay`.
- Each tick fires `nil`.
- Next tick is scheduled after current tick callback begins or completes; implementation must avoid overlapping ticks from the same Every signal.
- Destroy cancels pending timer.

## `Signal.FromRoblox(rbxSignal, mapper?)`

Wraps an `RBXScriptSignal`.

### Validation

`typeof(rbxSignal) == "RBXScriptSignal"`.

`mapper`, if supplied, must be function.

Errors:

```text
Signal.FromRoblox: expected RBXScriptSignal
Signal.FromRoblox: mapper must be a function or nil
```

### Behavior

- Connect to the Roblox signal.
- If `mapper` exists, call `mapper(...args)` and fire the returned payload.
- If `mapper` is nil, fire `table.pack(...args)`.
- Mapper errors route through `ErrorHandler.Report`:
  - `Module = "Signal"`
  - `Phase = "FromRoblox"`
- Destroy disconnects the Roblox connection.

## `Signal.IsSignal(value)`

Returns whether `value` is a signal handle created by this module.

Destroyed signals still return `true`.

## `signal:Connect(listener)`

Registers a listener.

### Validation

- Signal must be live.
- `listener` must be function.

Errors:

```text
Signal.Connect: signal is destroyed
Signal.Connect: listener must be a function
```

### Behavior

- Append listener to listener list.
- Return a `Connection`.
- If replay policy exists, schedule every replay entry through `Scheduler.Defer`.
- Replayed entries check connection still connected before invoking listener.
- Replay does not run inline during `Connect`.

### Error behavior

Listener errors route through `ErrorHandler.Report`:

```luau
Module = "Signal"
Phase = "Listener"
```

If policy is not `"Throw"`, delivery continues to later listeners.

## `signal:Once(listener)`

Registers a listener that runs at most once.

### Validation

Same as `Connect`.

### Behavior

- Uses a connection.
- On first delivered payload:
  1. disconnect before invoking listener
  2. invoke listener
- Replay entries may trigger `Once`, but only the first delivered entry invokes the listener.
- Re-entrant fires inside the listener do not invoke it again.

## `signal:Fire(payload)`

Synchronously emits `payload`.

### Behavior

1. If destroyed, return.
2. If never, error.
3. If replay enabled, store payload using presence-aware storage.
4. Increment fire depth.
5. Iterate listeners in connection order.
6. For each connected listener, call it with payload through error boundary.
7. Decrement fire depth.
8. If fire depth reaches zero, compact listener list.

### Nil behavior

`payload` may be nil.

Replay, Wait, buffers, and operators that support nil must preserve it.

## `signal:Wait()`

Yields until the next fire.

### Validation

Signal must be live.

Must be called from a yieldable coroutine.

Errors:

```text
Signal.Wait: signal is destroyed
Signal.Wait: must be called from a yieldable coroutine
```

### Behavior

- Connect temporary listener.
- On next fire:
  1. capture payload with presence
  2. disconnect listener
  3. resume waiting coroutine through `Scheduler.Defer` or directly?  
     Required: resume asynchronously through `Scheduler.Defer` to avoid resuming inside listener iteration.
- Return payload, including nil.
- If signal is destroyed while waiting, resume waiter by raising:

```text
Signal.Wait: signal destroyed
```

## `signal:DisconnectAll()`

Disconnects all current listeners.

### Behavior

- Signal remains live.
- Replay buffer is unchanged.
- Pending timers remain active.
- Current fire iteration must not call disconnected listeners after disconnection is observed.
- Future connections work.

## `signal:Destroy()`

Destroys signal.

### Behavior

1. If already destroyed, return.
2. Mark destroyed.
3. Disconnect all listeners.
4. Resume all `Wait` callers with `"Signal.Wait: signal destroyed"`.
5. Clear replay buffer and policy.
6. Cancel internal timers.
7. Run operator cleanup hooks.
8. Release references.

## `signal:IsDestroyed()`

Returns destroyed state.

No errors.

## Operator defaults

Every operator creates a derived signal.

Default guarantees:

- source destroy destroys derived
- derived destroy disconnects from source
- source replay is not consumed by operator subscriptions
- if derived needs replay, call replay on derived
- callback errors route through `ErrorHandler`
- if policy is not `"Throw"`, failed operator callback skips only that payload
- nil payloads must be supported unless the operator explicitly rejects them

## `signal:Map(mapper)`

Transforms payloads.

### Validation

`mapper` must be function.

Error:

```text
Signal.Map: mapper must be a function
```

### Behavior

- For each source payload, call `mapper(payload)`.
- Fire mapper result, including nil.
- Mapper error reports phase `"Map"` and skips payload if policy is not `"Throw"`.

## `signal:Filter(predicate)`

Emits original payload when predicate returns exactly `true`.

### Validation

`predicate` must be function.

### Behavior

- Call `predicate(payload)`.
- If result is exactly `true`, fire original payload.
- Truthy non-true values do not pass.
- Predicate errors report phase `"Filter"` and skip payload if policy is not `"Throw"`.

## `signal:Scan(reducer, seed)`

Accumulates state.

### Validation

`reducer` must be function.

### Behavior

- Internal accumulator starts as `seed`, including nil.
- For each payload, call `reducer(accumulator, payload)`.
- Store returned accumulator, including nil.
- Fire new accumulator.
- Reducer errors report phase `"Scan"` and keep previous accumulator if policy is not `"Throw"`.

## `signal:MergeMap(selector)`

Maps each payload to an inner signal and merges all active inner emissions.

### Validation

`selector` must be function.

Selector result must be live Signal.

Error:

```text
Signal.MergeMap: selector must return a Signal
```

### Behavior

- Each source payload calls selector.
- Subscribe to returned inner signal.
- Track every inner connection.
- Inner payloads fire through derived signal.
- Inner subscriptions remain active until:
  - derived destroyed
  - inner signal destroyed
  - inner connection explicitly cleaned by inner destroy hook
- Destroying derived disconnects all active inner subscriptions.

## `signal:SwitchMap(selector)`

Maps each payload to an inner signal and switches to the latest.

### Validation

Same as MergeMap.

### Behavior

- On each source payload:
  1. call selector
  2. disconnect previous inner subscription, if any
  3. subscribe to new inner
- Only latest inner signal can emit.

## `signal:Take(count)`

Emits first `count` payloads, then destroys derived.

### Validation

`count` must be positive integer.

Error:

```text
Signal.Take: count must be a positive integer
```

### Behavior

- Emit payloads 1 through count.
- After emitting the count-th payload, destroy derived.
- Source remains live.

## `signal:Skip(count)`

Skips first `count` payloads.

### Validation

`count` must be integer >= 0.

Error:

```text
Signal.Skip: count must be a non-negative integer
```

### Behavior

- `count = 0` emits all payloads.
- Payloads after skipped count emit normally.

## `signal:TakeWhile(predicate)`

Emits while predicate returns exactly true.

### Behavior

- For each payload, call predicate.
- If exactly true, emit payload.
- First non-true result destroys derived and does not emit that payload.
- Predicate errors report and destroy derived if policy is not `"Throw"`.

## `signal:SkipWhile(predicate)`

Skips while predicate returns exactly true.

### Behavior

- While skipping, call predicate.
- If exactly true, skip payload.
- First non-true result emits that payload and disables future predicate checks.
- Later payloads emit unconditionally.
- Predicate error reports and treats as non-true if policy is not `"Throw"`.

## `signal:TakeUntil(stopper)`

Emits source until stopper fires.

### Validation

`stopper` must be live Signal.

### Behavior

- Source payloads emit until stopper fires.
- When stopper fires, destroy derived.
- Destroy derived disconnects both source and stopper subscriptions.
- Stopper payload ignored.

## `signal:SkipUntil(starter)`

Ignores source until starter fires once.

### Validation

`starter` must be live Signal.

### Behavior

- Source payloads before starter are ignored.
- Starter fires once, enabling future source payloads.
- Starter subscription disconnects after first starter fire.
- Starter payload ignored.

## `signal:Debounce(seconds)`

Emits latest payload after quiet period.

### Validation

`seconds >= 0`.

### Behavior

- On source payload, cancel pending debounce timer.
- Store payload and presence.
- Schedule timer with `Scheduler.Delay(seconds, ...)`.
- When timer fires, emit stored payload if present.
- Nil payloads are supported.
- Destroy cancels pending timer.

## `signal:Throttle(seconds, opts?)`

Limits emissions to leading/trailing interval.

### Validation

`seconds > 0`.

`opts`, if supplied, must be table.

`Leading` and `Trailing`, if supplied, must be boolean.

Defaults:

```luau
Leading = true
Trailing = true
```

### Behavior

- If both false, derived emits nothing.
- When throttle window is closed:
  - if Leading true, emit payload immediately
  - if Leading false and Trailing true, store payload for trailing
  - open window for `seconds`
- While window open:
  - if Trailing true, replace pending payload with latest payload
  - if Trailing false, drop payload
- When window closes:
  - if pending presence exists, emit pending payload including nil
  - clear pending
- Destroy cancels timer.

## `signal:Delay(seconds)`

Delays each payload independently.

### Validation

`seconds >= 0`.

### Behavior

- Every source payload schedules its own timer.
- Timer emits that payload when fired.
- Nil payloads are supported.
- Destroy cancels all pending timers.

## `signal:BufferCount(count, step?)`

Collects count payloads into arrays.

### Validation

- `count` positive integer.
- `step`, if supplied, positive integer.
- default `step = count`.

### Behavior

- Append each payload with presence.
- When buffer has at least `count` entries:
  - emit an array of first `count` payloads
  - array preserves nil payload slots using packed representation with `n = count`
  - remove first `step` entries from internal buffer
- If `step < count`, buffers overlap.
- If `step == count`, buffers do not overlap.
- If `step > count`, gaps are created by discarding additional buffered entries.

## `signal:BufferTime(seconds)`

Collects payloads during a time window.

### Validation

`seconds > 0`.

### Behavior

- First payload in empty unscheduled buffer starts timer.
- Payloads append with presence.
- When timer fires:
  - if buffer non-empty, emit packed array with `n`
  - clear buffer
- Empty buffers are not emitted.
- Nil payload slots are preserved.
- Destroy cancels timer.

## `signal:SampleBy(sampler)`

Samples latest source payload when sampler fires.

### Validation

`sampler` must be live Signal.

### Behavior

- Source payload updates latest value and presence.
- When sampler fires:
  - if presence exists, emit latest value including nil
  - clear presence
- Sampler payload ignored.

## `signal:ReplayCount(count)`

Enables count-based replay.

### Validation

`count` positive integer.

Only one replay policy active at a time.

Errors:

```text
Signal.ReplayCount: count must be a positive integer
Signal: only one replay policy may be applied
```

### Behavior

- Return same signal.
- Store latest `count` fired payloads with presence.
- New direct subscribers receive replay entries through `Scheduler.Defer`.
- Operators do not consume source replay.

## `signal:ReplayTime(seconds)`

Enables time-window replay.

### Validation

`seconds > 0`.

Only one replay policy active.

### Behavior

- Uses `Scheduler.Now()`.
- Store fired payloads with timestamps.
- Trim old entries on fire and connect.
- New direct subscribers receive entries within window through `Scheduler.Defer`.

## `signal:ClearReplay()`

Clears replay entries and policy.

### Behavior

- Return same signal.
- If no replay policy exists, no-op.
- Does not affect listeners.

## `Signal.Merge(signals)`

Merges source signals.

### Validation

`signals` must be non-empty dense array of live signals.

Error:

```text
Signal.Merge: signals must be a non-empty dense array of Signals
```

### Behavior

- Subscribe to each source in array order.
- Any source fire emits payload.
- Destroying any source destroys merged signal.
- Destroying merged disconnects all source subscriptions.

## `Signal.Zip(signals)`

Waits for one payload from each source per round.

### Validation

Same as Merge.

### Behavior

- Track values and filled slots separately.
- Nil payloads count as filled.
- Each source contributes at most once per round.
- Extra emissions from a filled source before round completion are ignored.
- When all filled, emit packed array in source order with `n`.
- Reset round.
- Destroying any source destroys zipped.

## `Signal.Race(signals)`

First source to emit becomes winner.

### Validation

Same as Merge.

### Behavior

- Subscribe to all candidates.
- First candidate to fire:
  - becomes winner
  - emits winning payload
  - disconnects losing subscriptions
  - stays subscribed to winner
- Future winner emissions pass through.
- Destroying all candidates before winner destroys race.
- Destroying winner after selection destroys race.

## `Signal.Sequence(signals, opts?)`

Recognizes ordered signal sequence.

### Validation

- `signals` non-empty dense array of live signals.
- `opts` table or nil.
- Numeric timing options must be non-negative.
- `Max*` must be >= corresponding `Min*`.

Defaults:

```luau
MinTimeBetween = 0
MaxTimeBetween = math.huge
MinTotalTime = 0
MaxTotalTime = math.huge
ResetOnMismatch = true
FireOnMismatch = false
```

### Behavior

- Source payloads ignored.
- Duplicate signals are allowed.
- Subscribe once per unique source.
- Maintain current step index.
- Timing uses `Scheduler.Now()`.
- `MinTimeBetween`/`MaxTimeBetween` apply only between accepted steps, not before first step.
- Immediate first step never fails due to `MinTimeBetween`.
- If correct next source fires within timing constraints, advance step.
- If full sequence completes:
  - emit `{ Time = elapsed, Completed = true }`
  - reset state
- If mismatch/timing failure:
  - if `FireOnMismatch`, emit `{ Time = elapsed, Completed = false }`
  - if `ResetOnMismatch`, reset state
  - otherwise preserve state as specified by mismatch logic
- Tie and duplicate behavior must be deterministic and covered by tests.
