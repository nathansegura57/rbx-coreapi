# Connection

An opaque, read-only handle that represents a live subscription. Every `Connect`, `Subscribe`, and `OnDestroy` call in CoreAPI returns a `Connection`. Calling `Disconnect` on it stops the subscription and releases resources.

---

## API Reference

### `Connection.New(disconnectFn?)`

Creates a new connection backed by an optional cleanup function. You rarely need to call this directly — it is used internally by Signal, Store, Context, etc.

| Parameter | Type | Description |
|-----------|------|-------------|
| `disconnectFn` | `(() -> ())?` | Called once when `Disconnect` is invoked. May be `nil`. |

**Returns:** `Connection`

**Errors:**
- `Connection.New: disconnectFn must be a function or nil`

```luau
local conn = Connection.New(function()
    print("Cleaned up!")
end)
conn:Disconnect()  -- prints "Cleaned up!"
conn:Disconnect()  -- no-op; already disconnected
```

---

### `Connection.IsConnection(value)`

Returns `true` if `value` is a live Connection handle (created by `Connection.New`).

| Parameter | Type | Description |
|-----------|------|-------------|
| `value` | `unknown` | Any value |

**Returns:** `boolean`

```luau
local conn = Connection.New(nil)
print(Connection.IsConnection(conn))  -- true
print(Connection.IsConnection({}))    -- false
```

---

### `handle.Connected`

A read-only boolean property. `true` until `Disconnect` is called.

```luau
local conn = signal:Connect(fn)
print(conn.Connected)  -- true
conn:Disconnect()
print(conn.Connected)  -- false
```

**Errors if written:**
- `Connection: 'Connected' is read-only`

---

### `handle:Disconnect()`

Disconnects the subscription. Idempotent — safe to call multiple times.

On the first call:
1. Sets `Connected` to `false`.
2. Calls `disconnectFn()` if one was provided, routing any error through `ErrorHandler.Protect`.

Subsequent calls are no-ops.

```luau
local conn = store:Subscribe(function(v) print(v) end)
conn:Disconnect()
conn:Disconnect()  -- safe; does nothing
```

---

## Gotchas

- **Handles are weakly referenced.** The internal records table uses weak keys, so a Connection that has been garbage-collected no longer appears valid. Hold a reference to any Connection whose lifecycle you want to control explicitly.
- **`disconnectFn` errors are routed, not rethrown.** If the cleanup function errors, the error passes through `ErrorHandler.Protect` (and thus the active policy) — `Disconnect` itself does not throw.
- **`Connected` is the source of truth.** Do not rely on the absence of a reference to infer disconnection. Check `conn.Connected` explicitly.

```luau
-- Pattern: store connections in a table and disconnect all on cleanup.
local connections = {}
table.insert(connections, signal:Connect(handler))
table.insert(connections, store:Subscribe(listener))

local function cleanup()
    for _, conn in connections do
        conn:Disconnect()
    end
    table.clear(connections)
end
```
