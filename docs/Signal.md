# Signal

## Purpose

`Signal` is a typed event emitter with synchronous delivery, re-entrancy safety, optional replay, and a suite of combinators.

## Import

```luau
local Signal = require(path.to.Signal)
```

## Public API reference

```luau
Signal.New<T>(): Signal.Signal<T>
Signal.Never<T>(): Signal.Signal<T>
Signal.After<T>(seconds: number): Signal.Signal<T>
Signal.Every<T>(seconds: number): Signal.Signal<T>
Signal.FromRoblox<T>(rbxSignal: RBXScriptSignal): Signal.Signal<T>
Signal.Merge<T>(signals: { Signal.Signal<T> }): Signal.Signal<T>
Signal.Zip(signals: { Signal.Signal<any> }): Signal.Signal<{ any }>
Signal.Race<T>(signals: { Signal.Signal<T> }): Signal.Signal<T>
Signal.Sequence(signals: { Signal.Signal<any> }, opts: SequenceOptions?): Signal.Signal<{ any }>
Signal.IsSignal(value: unknown): boolean
```

## Instance methods

```luau
signal:Connect(fn: (payload: T) -> ()): Connection.Connection
signal:Once(fn: (payload: T) -> ()): Connection.Connection
signal:Fire(payload: T): ()
signal:Wait(): T
signal:DisconnectAll(): ()
signal:Destroy(): ()
signal:IsDestroyed(): boolean
signal:ReplayCount(count: number): Signal.Signal<T>
signal:ReplayTime(seconds: number): Signal.Signal<T>
signal:BufferCount(count: number): Signal.Signal<T>
signal:BufferTime(seconds: number): Signal.Signal<T>
signal:Debounce(seconds: number): Signal.Signal<T>
signal:Throttle(seconds: number): Signal.Signal<T>
signal:Map<U>(fn: (T) -> U): Signal.Signal<U>
signal:Filter(fn: (T) -> boolean): Signal.Signal<T>
signal:Reduce<U>(fn: (U, T) -> U, initial: U): Signal.Signal<U>
signal:Tap(fn: (T) -> ()): Signal.Signal<T>
signal:Skip(count: number): Signal.Signal<T>
signal:Take(count: number): Signal.Signal<T>
signal:Distinct(): Signal.Signal<T>
signal:DistinctUntilChanged(equals: ((T, T) -> boolean)?): Signal.Signal<T>
```

## Types

```luau
export type Signal<T> = {
    Connect: (self: Signal<T>, fn: (payload: T) -> ()) -> Connection.Connection,
    Once: (self: Signal<T>, fn: (payload: T) -> ()) -> Connection.Connection,
    Fire: (self: Signal<T>, payload: T) -> (),
    Wait: (self: Signal<T>) -> T,
    DisconnectAll: (self: Signal<T>) -> (),
    Destroy: (self: Signal<T>) -> (),
    IsDestroyed: (self: Signal<T>) -> boolean,
    ReplayCount: (self: Signal<T>, count: number) -> Signal<T>,
    ReplayTime: (self: Signal<T>, seconds: number) -> Signal<T>,
    ...
}

export type SequenceOptions = {
    Timeout: number?,
    ResetOnTimeout: boolean?,
}
```

## `Signal.New()`

Creates a standard signal. Payloads may be any value including nil.

## `Signal.Never()`

Creates a signal that never fires. Connecting returns a connection that is never called.

## `Signal.After(seconds)`

Creates a signal that fires once after `seconds`.

**Error behavior**

```text
Signal.After: seconds must be non-negative
```

## `Signal.Every(seconds)`

Creates a signal that fires repeatedly every `seconds`.

**Error behavior**

```text
Signal.Every: seconds must be positive
```

**Behavior**

- Fires indefinitely until destroyed.
- Timer is scheduled through `Scheduler`.

## `Signal.FromRoblox(rbxSignal)`

Wraps an `RBXScriptSignal`. Each Roblox event fires this signal with the same arguments packed into a table `{ ..., n = count }`.

**Error behavior**

```text
Signal.FromRoblox: rbxSignal must be an RBXScriptSignal
```

## `Signal.Merge(signals)`

Fires whenever any source signal fires. Output payload is the source payload.

**Error behavior**

```text
Signal.Merge: signals must be a non-empty dense array of Signals
```

**Behavior**

- Destroying any source destroys the merged signal.

## `Signal.Zip(signals)`

Fires when all sources have fired at least once since the last zip. Output is an array of one payload per source in order.

**Nil behavior**

Nil payloads are tracked with presence flags. A nil payload from source `i` counts as slot `i` filled.

## `Signal.Race(signals)`

Fires once with the payload from the first source that fires.

**Behavior**

- After the first fire, the signal fires no further events.
- Destroying any source destroys the race signal.

## `Signal.Sequence(signals, opts?)`

Fires once when sources fire in order within optional timeout windows.

**Options**

```luau
{
    Timeout: number?,      -- seconds per step
    ResetOnTimeout: boolean?,
}
```

**Behavior**

- Requires sources to fire in index order.
- If `Timeout` is set and a step times out: resets to step 1 if `ResetOnTimeout` is true, else remains at step 1.

## `Signal.IsSignal(value)`

Returns `true` for any Signal handle, including destroyed signals.

## `signal:Connect(fn)`

Registers a listener.

**Behavior**

- Listeners fire in connection order.
- Listener errors route through `ErrorHandler` with phase `"Signal"`.
- Returns a `Connection`.

**Error behavior**

```text
Signal.Connect: fn must be a function
Signal.Connect: signal is destroyed
```

## `signal:Once(fn)`

Registers a listener that disconnects itself after first invocation.

## `signal:Fire(payload)`

Fires all current listeners synchronously with `payload`.

**Behavior**

- Listeners added during a fire are not called for that fire.
- Disconnections during a fire are respected; disconnected listeners are skipped.
- Nil payloads are supported.

**Error behavior**

```text
Signal.Fire: signal is destroyed
```

## `signal:Wait()`

Yields the calling coroutine until the next fire.

**Behavior**

- Returns the payload from the next fire.
- Must be called from a yieldable coroutine.
- If the signal is destroyed while waiting, errors:

```text
Signal.Wait: signal destroyed
```

## `signal:DisconnectAll()`

Disconnects all listeners. The signal remains live and can accept new connections.

## `signal:Destroy()`

Permanently destroys the signal.

**Behavior**

- All listeners are disconnected.
- Pending `Wait` calls receive a destroy error.
- Replay buffers are cleared.
- Derived signals are destroyed.
- Idempotent.

## `signal:IsDestroyed()`

Returns `true` after `Destroy`.

## Replay policies

### `signal:ReplayCount(count)`

On new connection, delivers the last `count` buffered payloads immediately.

**Error behavior**

```text
Signal: count must be a positive integer
Signal: only one replay policy may be applied
```

### `signal:ReplayTime(seconds)`

On new connection, delivers all buffered payloads from the last `seconds`.

**Error behavior**

```text
Signal: seconds must be positive
Signal: only one replay policy may be applied
```

## Operators

### `signal:Debounce(seconds)`

Returns a derived signal that fires only after `seconds` of silence. Each payload resets the timer.

### `signal:Throttle(seconds)`

Returns a derived signal that fires at most once per `seconds` window.

### `signal:Map(fn)`

Returns a derived signal with payloads transformed by `fn`.

### `signal:Filter(fn)`

Returns a derived signal that only fires when `fn(payload) == true`.

### `signal:Reduce(fn, initial)`

Returns a derived signal that accumulates a running value. Fires the accumulated value on each source fire.

### `signal:Tap(fn)`

Returns a derived signal that calls `fn` as a side effect then passes through the payload unchanged.

### `signal:Skip(count)`

Returns a derived signal that ignores the first `count` fires.

### `signal:Take(count)`

Returns a derived signal that fires at most `count` times then destroys itself.

### `signal:Distinct()`

Returns a derived signal that skips consecutive duplicate payloads by identity (`==`).

### `signal:DistinctUntilChanged(equals?)`

Returns a derived signal using a custom equality function.

## Lifecycle behavior

Destroying a source signal destroys all derived signals built from it. Destroying a derived signal disconnects it from the source but does not destroy the source.

## Nil behavior

All APIs support nil payloads. Buffer entries use presence wrappers internally so nil does not truncate array length.

## Scheduler behavior

`Signal.After`, `Signal.Every`, debounce, and throttle operators use `Scheduler.Delay` and `Scheduler.Defer`.

## Not implemented

`Signal.Never` signals never fire. `Signal.Race` fires once and never again. These behaviors are intentional.
