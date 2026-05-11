# 01 — Connection Specification

`Connection` represents a disposable subscription or hook.

It is used by `Signal`, `Store`, `Task.Token`, `Context.OnDestroy`, `Scheduler.OnStep`, and any kernel API that registers a callback and returns a handle.

## Public API

```luau
Connection.New(disconnectFn: (() -> ())?): Connection.Connection
Connection.IsConnection(value: unknown): boolean
```

## Public type

```luau
export type Connection = {
    Connected: boolean,
    Disconnect: (self: Connection) -> (),
}
```

## Handle model

A connection handle is an opaque frozen table backed by a private record.

`getmetatable(connection)` must return the protected string:

```text
Connection
```

Assigning any field must error:

```text
Connection: '<field>' is read-only
```

The `Connected` property is exposed through `__index`; it must reflect the live record state.

## `Connection.New(disconnectFn?)`

Creates a connected connection.

### Parameters

```luau
disconnectFn: (() -> ())?
```

### Validation

If `disconnectFn` is neither `nil` nor a function, error:

```text
Connection.New: disconnectFn must be a function or nil
```

### Behavior

1. Create a private record:
   - `Connected = true`
   - `DisconnectFn = disconnectFn`
2. Return an opaque handle.

### Guarantees

- The returned connection starts connected.
- `connection.Connected` is `true` until disconnected.
- `DisconnectFn` runs at most once.
- If the connection is garbage-collected without disconnection, no guarantee is made that `DisconnectFn` runs.

## `Connection.IsConnection(value)`

Returns whether `value` is a live or disconnected connection handle created by this module.

### Parameters

```luau
value: unknown
```

### Returns

```luau
boolean
```

### Behavior

- Return `true` if `value` has an internal connection record.
- Return `false` otherwise.
- Destroyed/disconnected connections still return `true`; disconnection changes `Connected`, not identity.

## `connection.Connected`

Boolean property.

### Behavior

- Returns `true` while the connection has not been disconnected.
- Returns `false` after `Disconnect`.
- If a stale handle somehow has no record, returns `false`.

This property is read-only.

## `connection:Disconnect()`

Disconnects the connection.

### Validation

If `self` is not a valid connection handle, error:

```text
Connection.Disconnect: invalid connection
```

### Behavior

1. If already disconnected, return immediately.
2. Set `Connected = false` before running `DisconnectFn`.
3. Clear the stored `DisconnectFn` so it cannot run twice.
4. If `DisconnectFn` exists, call it.
5. If `DisconnectFn` errors, route the error through:

```luau
ErrorHandler.Report({
    Module = "Connection",
    Phase = "Disconnect",
    Name = nil,
    Error = err,
})
```

### Error behavior

- `Disconnect` itself must not call `DisconnectFn` more than once even if error reporting throws.
- If `ErrorHandler.Report` throws because policy is `"Throw"`, the error may propagate from `Disconnect`.
- Even if the error propagates, the connection remains disconnected.
