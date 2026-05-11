# Connection

## Purpose

`Connection` represents a cancellable subscription or listener link. It tracks whether the link is active and provides a single method to sever it.

## Import

```luau
local Connection = require(path.to.Connection)
```

## Public API reference

```luau
Connection.New(disconnectFn: (() -> ())?): Connection.Connection
Connection.IsConnection(value: unknown): boolean
```

## Types

```luau
export type Connection = {
    Connected: boolean,
    Disconnect: (self: Connection) -> (),
}
```

## `Connection.New(disconnectFn?)`

Creates a new live connection.

**Parameters**

- `disconnectFn` — optional cleanup function invoked once when `Disconnect` is called.

**Returns** a `Connection` handle.

**Behavior**

- The handle starts with `Connected = true`.
- When `Disconnect` is called, `Connected` is set to `false` before `disconnectFn` runs, so the function cannot observe the connected state.
- If `disconnectFn` errors, the error is routed through `ErrorHandler.Report` with phase `"Disconnect"`. `Connected` remains `false`.
- Calling `Disconnect` on an already-disconnected connection is a no-op.

**Error behavior**

```text
Connection.New: disconnectFn must be a function or nil
```

## `Connection.IsConnection(value)`

Returns `true` for any handle created by `Connection.New`, regardless of connected state.

## `connection.Connected`

Read-only property. `true` while connected, `false` after `Disconnect`.

## `connection:Disconnect()`

Severs the connection. Idempotent.

## Lifecycle behavior

Connections do not own external resources beyond the `disconnectFn` closure. They are garbage-collected when no references remain.

## Nil behavior

`disconnectFn` is optional. Passing `nil` creates a valid connection that does nothing on disconnect.

## Not implemented

Connection does not support reconnection or re-enabling after disconnect.
