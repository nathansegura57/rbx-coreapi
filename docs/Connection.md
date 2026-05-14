# Connection API Reference

`Connection` is the shared lifecycle handle for CoreAPI systems that register ongoing work.

Place this module at:

```text
ReplicatedStorage/Shared/Kernel/Connection
```

It is used by systems such as signals, stores, context observers, destruction hooks, task subscriptions, and any other API that gives a caller something they may later cancel.

A connection gives consumers one consistent capability:

```luau
connection:Disconnect()
```

The handle is intentionally opaque. Consumers can observe whether it is connected, disconnect it, and validate unknown values with `Connection.IsConnection`. They cannot mutate its lifecycle state, inspect its private cleanup callback, or forge a valid connection by constructing a table with the same shape.

`Connection` depends on:

```text
ReplicatedStorage/Shared/Kernel/ErrorHandler
```

That dependency is used only for cleanup callback failures. API misuse errors are raised directly.

---

## Design Goals

`Connection` is intentionally small, explicit, and lifecycle-focused.

It exists so that every subscription-like API follows the same ownership model:

```luau
register ongoing behavior
    ↓
return Connection
    ↓
caller stores the handle
    ↓
caller disconnects during cleanup
```

This produces predictable cleanup behavior across components, services, signals, stores, observers, and other long-lived systems.

The module is designed around these principles:

- **Opaque lifecycle capability**: a connection is a control token, not a public data object.
- **Idempotent disconnection**: calling `Disconnect` more than once is always safe.
- **Read-only public state**: `Connected` can be observed but not assigned.
- **Private cleanup storage**: cleanup callbacks are not exposed on the handle.
- **Weak internal registry**: discarded handles are not kept alive by the module.
- **Centralized callback failure routing**: cleanup callback errors go through `ErrorHandler.Protect`.
- **Direct usage failures**: invalid API usage fails immediately instead of being routed through runtime error policy.
- **Typed public surface**: exported Luau types describe the module contract clearly.

---

## Importing

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Connection = require(ReplicatedStorage.Shared.Kernel.Connection)
```

When writing another Kernel module, `Connection` is typically required from the same folder:

```luau
local Connection = require(script.Parent.Connection)
```

---

## Relationship to `ErrorHandler`

`Connection` intentionally separates two categories of failure.

### API usage errors

These are developer mistakes:

- passing a non-function to `Connection.New`;
- assigning to `connection.Connected`;
- assigning any other field on the connection handle;
- calling `Disconnect` with a forged or invalid receiver.

These errors are raised directly with `error` because they indicate incorrect use of the `Connection` API itself.

### Runtime cleanup callback errors

These come from user-provided cleanup code:

```luau
local connection = Connection.New(function()
    error("cleanup failed")
end)
```

These failures are routed through `ErrorHandler.Protect` using:

```luau
Module = "Connection"
Phase = "Disconnect"
```

This keeps callback failure behavior consistent with the rest of CoreAPI. `Connection` does not decide whether such failures should throw, warn, collect, or be swallowed. That decision belongs to the active `ErrorHandler` policy.

---

## Exported Types

### `Connection.DisconnectCallback`

```luau
type DisconnectCallback = () -> ()
```

A cleanup function called when a connection is disconnected for the first time.

The callback receives no arguments and returns nothing. Return values are ignored.

Use it to release the resource represented by the connection:

```luau
local connection = Connection.New(function()
    listenerRecords[listenerRecord] = nil
end)
```

Keep disconnect callbacks small and lifecycle-focused. They should remove listeners, disconnect child connections, clear records, or release resources. They should not perform unrelated application work.

---

### `Connection.Connection`

```luau
type Connection = {
    Connected: boolean,
    Disconnect: (self: Connection) -> (),
}
```

An opaque handle representing a live or previously live subscription.

The public surface has only two members:

| Member | Type | Purpose |
|---|---|---|
| `Connected` | `boolean` | Read-only lifecycle state. |
| `Disconnect` | `(self: Connection) -> ()` | Idempotently disconnects the handle. |

Although the type is structural, a plain table with the same fields is not treated as a real connection by `Connection.IsConnection`. Runtime identity is tracked through private module state.

---

### `Connection.ConnectionModule`

```luau
type ConnectionModule = {
    New: (disconnectCallback: DisconnectCallback?) -> Connection,
    IsConnection: (value: unknown) -> boolean,
}
```

The type of the frozen module table returned by `require`.

---

## Public Functions

## `Connection.New`

```luau
Connection.New(disconnectCallback: Connection.DisconnectCallback?): Connection.Connection
```

Creates a new opaque connection handle.

Most consumers should not call this directly. Higher-level modules such as `Signal`, `Store`, `Context`, or lifecycle helpers should create connections internally and return them to callers.

### Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `disconnectCallback` | `Connection.DisconnectCallback?` | No | Optional cleanup function called once when the connection is disconnected. |

### Returns

| Type | Description |
|---|---|
| `Connection.Connection` | A new opaque, read-only connection handle. |

### Behavior

`Connection.New` creates a handle whose initial state is connected.

```luau
local connection = Connection.New(nil)

print(connection.Connected) -- true
```

If a cleanup callback is provided, the callback is stored privately. It is not exposed through the public handle.

```luau
local connection = Connection.New(function()
    print("cleanup")
end)

print(connection.Connected) -- true
print(connection.Disconnect) -- function
print(connection.DisconnectCallback) -- nil
```

The returned handle is read-only from the caller's perspective.

```luau
local connection = Connection.New(nil)

connection.Connected = false
-- Error: Connection: 'Connected' is read-only
```

### Possible Errors

```text
Connection.New: disconnectCallback must be a function or nil
```

Raised when `disconnectCallback` is neither a function nor `nil`.

```luau
Connection.New("not a function" :: any)
-- Error: Connection.New: disconnectCallback must be a function or nil
```

This is a direct usage error. It is not routed through `ErrorHandler` because the caller violated the constructor contract.

### Example: Manual Connection

```luau
local connection = Connection.New(function()
    print("Cleaned up")
end)

connection:Disconnect()
-- Cleaned up

connection:Disconnect()
-- No-op
```

### Example: Subscription API

```luau
function Signal.Connect(self: Signal, listener: Listener): Connection.Connection
    local listenerRecord = addListenerRecord(self, listener)

    return Connection.New(function()
        removeListenerRecord(self, listenerRecord)
    end)
end
```

The consumer receives a simple lifecycle handle:

```luau
local connection = signal:Connect(function(value)
    print(value)
end)

connection:Disconnect()
```

### Why the Callback Is Optional

Some connection handles only need to represent lifecycle state. They do not always need custom cleanup work.

```luau
local connection = Connection.New(nil)
connection:Disconnect()
```

Making the callback optional avoids forcing every caller to allocate a no-op function.

---

## `Connection.IsConnection`

```luau
Connection.IsConnection(value: unknown): boolean
```

Returns whether a value is a valid connection handle created by this module.

### Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `value` | `unknown` | Yes | Any value that may or may not be a connection. |

### Returns

| Type | Description |
|---|---|
| `boolean` | `true` if `value` is a currently recognized connection handle; otherwise `false`. |

### Behavior

`Connection.IsConnection` checks the module's private connection registry.

A plain table with the same public shape is not a valid connection:

```luau
local fakeConnection = {
    Connected = true,
    Disconnect = function() end,
}

print(Connection.IsConnection(fakeConnection)) -- false
```

A real handle created by `Connection.New` is valid:

```luau
local connection = Connection.New(nil)

print(Connection.IsConnection(connection)) -- true
```

### Important Weak-Registry Detail

The internal private-state registry uses weak keys. This means the registry does not keep discarded connection handles alive.

If no other code holds a reference to a connection, the garbage collector may collect it, and its private state may disappear naturally.

This is intentional. The registry should validate live handles without becoming a hidden memory leak.

### Example: Trust Boundary Validation

```luau
local function disconnectIfPossible(value: unknown): boolean
    if not Connection.IsConnection(value) then
        return false
    end

    value:Disconnect()
    return true
end
```

Use `IsConnection` when accepting unknown values from user code, plugin boundaries, test utilities, or generalized cleanup systems.

---

## Public Properties and Methods

## `connection.Connected`

```luau
connection.Connected: boolean
```

A read-only boolean property indicating whether the connection is still connected.

### Type

```luau
boolean
```

### Behavior

A new connection starts connected:

```luau
local connection = Connection.New(nil)

print(connection.Connected) -- true
```

After the first call to `Disconnect`, it becomes disconnected forever:

```luau
connection:Disconnect()

print(connection.Connected) -- false
```

Repeated calls do not change the result:

```luau
connection:Disconnect()
connection:Disconnect()
connection:Disconnect()

print(connection.Connected) -- false
```

### Possible Errors

```text
Connection: '<key>' is read-only
```

Raised when assigning `Connected` or any other public field on the connection handle.

```luau
connection.Connected = false
-- Error: Connection: 'Connected' is read-only
```

### Why `Connected` Is a Property

`Connected` represents observable state, so property syntax is ergonomic and expressive:

```luau
if connection.Connected then
    print("Subscription is still active")
end
```

The property is not a control surface. To change the state, call `Disconnect`.

Good:

```luau
connection:Disconnect()
```

Invalid:

```luau
connection.Connected = false
```

### When to Check `Connected`

You do not need to check `Connected` before calling `Disconnect` because disconnection is idempotent.

This is safe:

```luau
connection:Disconnect()
```

Check `Connected` only when the state itself matters:

```luau
local wasConnected = connection.Connected
connection:Disconnect()

if wasConnected then
    print("A live subscription was cleaned up")
end
```

---

## `connection:Disconnect`

```luau
connection:Disconnect(): ()
```

Disconnects the handle and runs its cleanup callback if one exists.

Equivalent function-call form:

```luau
connection.Disconnect(connection)
```

### Parameters

None when called with method syntax.

When using function-call syntax, the first argument must be the connection handle.

### Returns

Nothing.

`Disconnect` does not return whether it performed cleanup. Use `Connected` before calling it if that distinction matters.

### Behavior

On the first call, `Disconnect` performs this sequence:

1. Validates that the receiver is a real connection handle.
2. Returns immediately if the handle is already disconnected.
3. Marks the handle disconnected.
4. Removes the cleanup callback from private state.
5. Runs the cleanup callback, if present, through `ErrorHandler.Protect`.

The cleanup callback is removed before it is invoked. This ensures the callback can run at most once, even in reentrant or recursive cases.

### Idempotency

`Disconnect` is safe to call repeatedly.

```luau
local cleanupCalls = 0

local connection = Connection.New(function()
    cleanupCalls += 1
end)

connection:Disconnect()
connection:Disconnect()
connection:Disconnect()

print(cleanupCalls) -- 1
```

Idempotency is essential because cleanup ownership can overlap across multiple shutdown paths.

```luau
local connection = signal:Connect(listener)

local function cleanup(): ()
    connection:Disconnect()
end

component.Destroying:Connect(cleanup)
playerRemovingSignal:Connect(cleanup)
```

Even if both paths run, the subscription is cleaned up only once.

### Cleanup Callback Errors

If the cleanup callback throws, the failure is routed through:

```luau
ErrorHandler.Protect(disconnectCallback, "Connection", "Disconnect")
```

The active `ErrorHandler` policy determines what happens next.

| Active `ErrorHandler` Policy | Result of Cleanup Failure |
|---|---|
| `Throw` | `Disconnect` raises through the reported ErrorHandler failure path. |
| `Warn` | A warning is emitted and `Disconnect` returns. |
| `Swallow` | The failure is observed by any reporter, then ignored. |
| `Collect` | A report is collected for later inspection. |

The reported context is:

```luau
Module = "Connection"
Phase = "Disconnect"
```

### Cleanup Failure Does Not Reconnect the Handle

Once disconnection begins, the handle is considered disconnected. If the cleanup callback fails, the lifecycle transition is not rolled back.

```luau
local connection = Connection.New(function()
    error("cleanup failed")
end)

connection:Disconnect()

print(connection.Connected) -- false, unless ErrorHandler.Throw interrupted execution first
```

### Possible Errors

```text
Connection.Disconnect: invalid connection handle
```

Raised when `Disconnect` is called with a receiver that is not a valid connection handle.

```luau
local disconnect = Connection.New(nil).Disconnect

disconnect({} :: any)
-- Error: Connection.Disconnect: invalid connection handle
```

This is a direct usage error because the method was invoked with an invalid receiver.

### Example: Recursive Disconnect Is Safe

```luau
local connection: Connection.Connection

connection = Connection.New(function()
    connection:Disconnect()
    print("cleanup")
end)

connection:Disconnect()
-- cleanup
```

The callback runs once because the connection is marked disconnected and its callback is consumed before invocation.

---

## Behavior in Complex Cases

### `Connected` Changes Before Cleanup Runs

The public state changes to `false` before the cleanup callback runs.

```luau
local connection: Connection.Connection

connection = Connection.New(function()
    print(connection.Connected) -- false
end)

connection:Disconnect()
```

This ordering makes lifecycle state immediately reflect that the subscription is no longer active once disconnection begins.

---

### Cleanup Callback Runs at Most Once

The callback is consumed during the first disconnect.

```luau
local cleanupCalls = 0

local connection = Connection.New(function()
    cleanupCalls += 1
end)

connection:Disconnect()
connection:Disconnect()

print(cleanupCalls) -- 1
```

---

### Disconnecting a Connection With No Callback

A connection without a cleanup callback is still valid.

```luau
local connection = Connection.New(nil)

connection:Disconnect()
print(connection.Connected) -- false
```

This is useful for APIs that need to return a uniform handle even when no additional cleanup is required.

---

### Unknown Public Keys Return `nil`

Only `Connected` and `Disconnect` are public.

```luau
local connection = Connection.New(nil)

print(connection.SomeOtherProperty) -- nil
```

This mirrors normal table reads while still preventing public mutation.

---

### The Metatable Is Locked

Connection handles expose a protected metatable label.

```luau
local connection = Connection.New(nil)

print(getmetatable(connection)) -- "Connection"
```

External code cannot inspect or replace the implementation metatable.

---

## Recommended Usage Patterns

### Store Connections and Clean Them Up Together

```luau
local activeConnections: { Connection.Connection } = {}

table.insert(activeConnections, signalA:Connect(listenerA))
table.insert(activeConnections, signalB:Connect(listenerB))
table.insert(activeConnections, store:Subscribe(subscriber))

local function disconnectAllActiveConnections(): ()
    for _, connection in activeConnections do
        connection:Disconnect()
    end

    table.clear(activeConnections)
end
```

This is the standard pattern for components, controllers, view models, effects, tools, and services.

---

### Return a Connection From Every Subscription API

```luau
function Signal.Connect(self: Signal, listener: Listener): Connection.Connection
    local listenerRecord = addListenerRecord(self, listener)

    return Connection.New(function()
        removeListenerRecord(self, listenerRecord)
    end)
end
```

This keeps all subscription APIs consistent:

```luau
local connection = signal:Connect(listener)
connection:Disconnect()
```

---

### Compose Multiple Connections Behind One Handle

```luau
local function connectToBothSignals(
    firstSignal: Signal,
    secondSignal: Signal,
    listener: () -> ()
): Connection.Connection
    local firstConnection = firstSignal:Connect(listener)
    local secondConnection = secondSignal:Connect(listener)

    return Connection.New(function()
        firstConnection:Disconnect()
        secondConnection:Disconnect()
    end)
end
```

Because every connection is idempotent, composed cleanup remains safe even if one child connection was already disconnected elsewhere.

---

### Validate Unknown Values Before Disconnecting

```luau
local function tryDisconnect(value: unknown): boolean
    if not Connection.IsConnection(value) then
        return false
    end

    value:Disconnect()
    return true
end
```

This pattern is useful for generalized cleanup helpers or APIs that accept untrusted input.

---

## Implementation Rationale

### Why an Opaque Handle?

A connection represents permission to disconnect a subscription.

Consumers should know this:

```luau
connection.Connected
connection:Disconnect()
```

Consumers should not know this:

- where the cleanup callback is stored;
- how connection identity is tracked;
- whether weak tables are used;
- how reentrant cleanup is guarded;
- how metatables expose public members.

Keeping the handle opaque allows internals to evolve without changing the public contract.

---

### Why Private State Instead of Public Fields?

A naive implementation might return this:

```luau
return {
    Connected = true,
    DisconnectCallback = disconnectCallback,
}
```

That exposes lifecycle internals and lets callers corrupt state.

The actual design stores private state in a module-owned registry so the handle remains a small read-only capability.

---

### Why Weak Keys?

The private registry uses weak keys so connection handles are not kept alive solely because they were registered internally.

If a caller discards a connection, the registry should not become a hidden memory leak.

This is especially important in systems that create many short-lived subscriptions.

---

### Why Is `Connected` Read Through `__index`?

`Connected` is public state, but the caller should not own it.

Reading through `__index` allows ergonomic property access:

```luau
print(connection.Connected)
```

while preserving control over mutation:

```luau
connection.Connected = false -- usage error
```

---

### Why Is `Disconnect` Read Through `__index`?

Every connection handle can share the same method function. The module does not need to allocate a new `Disconnect` closure for every handle.

This keeps handles lightweight and makes the public API consistent.

---

### Why Mark Disconnected Before Cleanup?

Once disconnection begins, the lifecycle state should immediately reflect that the handle is no longer active.

This also protects reentrant cleanup:

```luau
local connection: Connection.Connection

connection = Connection.New(function()
    connection:Disconnect()
end)

connection:Disconnect()
```

The inner call sees that the connection is already disconnected and returns.

---

### Why Remove the Callback Before Running It?

The cleanup callback is consumed as part of the disconnect transition.

Removing it before invocation guarantees that it can run at most once, even if cleanup indirectly triggers another disconnect path.

---

### Why Use `ErrorHandler.Protect`?

Cleanup callbacks are user-provided runtime code. They belong to the same error category as signal listeners, store subscribers, rule effects, and task finalizers.

`Connection` identifies the context:

```luau
Module = "Connection"
Phase = "Disconnect"
```

Then `ErrorHandler` applies the global policy.

This avoids duplicating error policy logic in every module.

---

### Why Direct `error` for Usage Problems?

Usage errors are not runtime callback failures. They mean the caller used the API incorrectly.

Examples:

```luau
Connection.New(123 :: any)
connection.Connected = false
connection.Disconnect({} :: any)
```

These should fail immediately so the calling code can be fixed. Routing them through `ErrorHandler` would allow a global runtime policy to hide broken API usage.

---

## Gotchas

### `Disconnect` Does Not Return Whether It Did Work

`Disconnect` always returns nothing.

```luau
connection:Disconnect()
```

If you need to know whether the connection was active, check `Connected` first.

```luau
local wasConnected = connection.Connected
connection:Disconnect()

if wasConnected then
    print("Disconnected an active subscription")
end
```

---

### Do Not Mutate `Connected`

This is invalid:

```luau
connection.Connected = false
```

Use this instead:

```luau
connection:Disconnect()
```

`Connected` is observable state, not a command.

---

### Do Not Rely on Table Shape

This is not a real connection:

```luau
local fakeConnection = {
    Connected = true,
    Disconnect = function() end,
}
```

Use `Connection.IsConnection` when validation matters.

---

### Keep a Reference to Connections You Need to Control

The connection handle is the caller's control token.

If you discard it, you lose the ability to disconnect manually:

```luau
signal:Connect(listener)
-- No retained handle; cannot explicitly disconnect this listener later.
```

Prefer:

```luau
local connection = signal:Connect(listener)
connection:Disconnect()
```

---

### Cleanup Callback Failures Follow `ErrorHandler` Policy

A failing cleanup callback may throw, warn, collect, or be swallowed depending on global configuration.

That means this code may not return under `ErrorHandler.Policy.Throw`:

```luau
local connection = Connection.New(function()
    error("cleanup failed")
end)

connection:Disconnect()
```

This is intentional. Cleanup callbacks are runtime callback code.

---

### Cleanup Callback Should Be Lifecycle-Focused

Good:

```luau
return Connection.New(function()
    listenerRecords[listenerRecord] = nil
end)
```

Risky:

```luau
return Connection.New(function()
    savePlayerData()
    awardCurrency()
    teleportPlayer()
end)
```

A disconnect callback should release resources, not perform unrelated gameplay behavior.

---

## Best Practices

### Return `Connection` From APIs That Register Ongoing Work

Any API that starts an ongoing listener, observer, subscription, or hook should return a connection.

Good:

```luau
local connection = store:Subscribe(subscriber)
```

Poor:

```luau
store:Subscribe(subscriber)
-- no way to disconnect
```

---

### Store Owned Connections in Arrays

```luau
local ownedConnections: { Connection.Connection } = {}

table.insert(ownedConnections, signal:Connect(listener))
table.insert(ownedConnections, store:Subscribe(subscriber))
```

Then disconnect them together:

```luau
for _, connection in ownedConnections do
    connection:Disconnect()
end

table.clear(ownedConnections)
```

---

### Avoid Defensive `Connected` Checks Before Disconnecting

This is unnecessary:

```luau
if connection.Connected then
    connection:Disconnect()
end
```

This is already safe:

```luau
connection:Disconnect()
```

Use the check only when you need the previous state for behavior or logging.

---

### Let `ErrorHandler` Own Callback Failure Policy

Do not wrap cleanup callbacks with custom warning, collection, or throwing logic inside each module.

Good:

```luau
return Connection.New(function()
    removeListenerRecord(signal, listenerRecord)
end)
```

`Connection` will route callback failures through `ErrorHandler`.

---

### Treat Direct `Connection` Errors as Bugs

Errors such as these indicate incorrect API usage:

```text
Connection.New: disconnectCallback must be a function or nil
Connection: 'Connected' is read-only
Connection.Disconnect: invalid connection handle
```

Fix the caller rather than suppressing the error.

---

## Full Example: Signal Integration

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Connection = require(ReplicatedStorage.Shared.Kernel.Connection)

export type Listener<T...> = (T...) -> ()

export type Signal<T...> = {
    Connect: (self: Signal<T...>, listener: Listener<T...>) -> Connection.Connection,
    Fire: (self: Signal<T...>, T...) -> (),
}

local Signal = {}
Signal.__index = Signal

function Signal.new<T...>(): Signal<T...>
    return setmetatable({
        ListenerRecords = {},
    }, Signal) :: any
end

function Signal.Connect<T...>(self: Signal<T...>, listener: Listener<T...>): Connection.Connection
    local listenerRecords = (self :: any).ListenerRecords

    local listenerRecord = {
        Listener = listener,
    }

    table.insert(listenerRecords, listenerRecord)

    return Connection.New(function()
        local listenerIndex = table.find(listenerRecords, listenerRecord)

        if listenerIndex ~= nil then
            table.remove(listenerRecords, listenerIndex)
        end
    end)
end

function Signal.Fire<T...>(self: Signal<T...>, ...: T...): ()
    for _, listenerRecord in (self :: any).ListenerRecords do
        listenerRecord.Listener(...)
    end
end
```

Consumer usage:

```luau
local healthChanged = Signal.new<number>()

local connection = healthChanged:Connect(function(health)
    print(`Health changed to {health}`)
end)

healthChanged:Fire(90)

connection:Disconnect()
```

---

## Full Example: Component Cleanup

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Connection = require(ReplicatedStorage.Shared.Kernel.Connection)

local PlayerNameplate = {}
PlayerNameplate.__index = PlayerNameplate

function PlayerNameplate.new(player: Player)
    local self = setmetatable({
        Player = player,
        Connections = {} :: { Connection.Connection },
    }, PlayerNameplate)

    table.insert(self.Connections, player:GetPropertyChangedSignal("DisplayName"):Connect(function()
        self:Render()
    end))

    table.insert(self.Connections, player.AncestryChanged:Connect(function()
        if player.Parent == nil then
            self:Destroy()
        end
    end))

    return self
end

function PlayerNameplate.Destroy(self): ()
    for _, connection in self.Connections do
        connection:Disconnect()
    end

    table.clear(self.Connections)
end
```

`Destroy` can be called multiple times safely because each connection is idempotent.

---

## Full Example: Composed Cleanup Handle

```luau
local function observeBothStores(
    firstStore: Store,
    secondStore: Store,
    observer: () -> ()
): Connection.Connection
    local firstConnection = firstStore:Subscribe(observer)
    local secondConnection = secondStore:Subscribe(observer)

    return Connection.New(function()
        firstConnection:Disconnect()
        secondConnection:Disconnect()
    end)
end
```

The caller receives one handle even though the implementation owns two child subscriptions.

```luau
local connection = observeBothStores(firstStore, secondStore, render)

connection:Disconnect()
```

---

## Testing Recommendations

A robust test suite should verify:

1. `Connection.New(nil)` returns a valid connection.
2. `Connection.New(function() end)` returns a valid connection.
3. `Connection.New` rejects non-function values.
4. `Connection.IsConnection` returns `true` for real handles.
5. `Connection.IsConnection` returns `false` for plain tables.
6. `Connected` starts as `true`.
7. `Connected` becomes `false` after `Disconnect`.
8. `Connected` cannot be assigned.
9. Unknown public fields cannot be assigned.
10. `Disconnect` calls the cleanup callback once.
11. Repeated `Disconnect` calls are no-ops.
12. Recursive `Disconnect` inside cleanup does not call cleanup twice.
13. Cleanup callback errors route through `ErrorHandler`.
14. Invalid method receivers raise direct usage errors.

Example:

```luau
local cleanupCalls = 0

local connection = Connection.New(function()
    cleanupCalls += 1
end)

connection:Disconnect()
connection:Disconnect()

assert(cleanupCalls == 1)
assert(connection.Connected == false)
```

Example with `ErrorHandler` collection:

```luau
ErrorHandler.SetPolicy(ErrorHandler.Policy.Collect)
ErrorHandler.ClearCollected()

local connection = Connection.New(function()
    error("cleanup failed")
end)

connection:Disconnect()

local collectedErrors = ErrorHandler.TakeCollected()

assert(#collectedErrors == 1)
assert(collectedErrors[1].Module == "Connection")
assert(collectedErrors[1].Phase == "Disconnect")
```

---

## Quick Reference

### Create

```luau
local connection = Connection.New(function()
    cleanup()
end)
```

### Check State

```luau
if connection.Connected then
    print("still active")
end
```

### Disconnect

```luau
connection:Disconnect()
```

### Validate Unknown Value

```luau
if Connection.IsConnection(value) then
    value:Disconnect()
end
```

---

## Summary

Use `Connection` when code registers ongoing work that needs a consistent cleanup handle.

Use:

- `Connection.New` inside subscription-like APIs;
- `connection:Disconnect()` to clean up ownership;
- `connection.Connected` when lifecycle state matters;
- `Connection.IsConnection` at trust boundaries;
- `ErrorHandler` to configure what happens when cleanup callbacks fail.

The result is a tiny, typed, opaque lifecycle primitive that makes larger systems easier to compose, safer to tear down, and consistent with the rest of the shared Kernel API suite.
