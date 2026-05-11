# ErrorHandler

The global error-routing module. Every runtime callback error in CoreAPI — signal listeners, store subscribers, task finally handlers, FSM enter/exit callbacks, rule effects, etc. — is funnelled through `ErrorHandler.Report`. The active *policy* determines what happens next: throw, warn, silently swallow, or collect for later inspection.

Set the policy once at startup and leave it. All other modules respect it automatically.

---

## API Reference

### `ErrorHandler.Policy`

A frozen enum table. Use these values instead of raw strings wherever a `Policy` is accepted.

```luau
ErrorHandler.Policy.Throw    -- (default) re-throws the error; best for development
ErrorHandler.Policy.Warn     -- warn() without stopping execution; best for production
ErrorHandler.Policy.Swallow  -- silently discard; rarely useful outside tests
ErrorHandler.Policy.Collect  -- accumulate; retrieve with TakeCollected()
```

**Type:** `{ Throw: "Throw", Warn: "Warn", Swallow: "Swallow", Collect: "Collect" }`

---

### `ErrorHandler.SetPolicy(policy)`

Sets the global error-routing policy.

| Parameter | Type | Description |
|-----------|------|-------------|
| `policy` | `ErrorHandler.Policy` | One of the four policy values |

**Errors:**
- `ErrorHandler.SetPolicy: invalid policy '…'` — `policy` is not one of the four valid values.

```luau
ErrorHandler.SetPolicy(ErrorHandler.Policy.Warn)
```

---

### `ErrorHandler.GetPolicy()`

Returns the current policy.

**Returns:** `ErrorHandler.Policy`

```luau
local current = ErrorHandler.GetPolicy()
-- current == "Throw" by default
```

---

### `ErrorHandler.SetReporter(fn?)`

Installs a custom reporter function that is called *before* the policy action for every `Report` invocation. Pass `nil` to remove.

| Parameter | Type | Description |
|-----------|------|-------------|
| `fn` | `((ErrorInfo) -> ())?` | Called with the error info table; errors inside `fn` are caught and warn'd |

**Errors:**
- `ErrorHandler.SetReporter: reporter must be a function or nil`

```luau
ErrorHandler.SetReporter(function(info)
    -- info.Module  — e.g. "Signal"
    -- info.Phase   — e.g. "Listener"
    -- info.Name    — optional label (e.g. rule name), may be nil
    -- info.Message — optional human message, may be nil
    -- info.Error   — the raw error value
    print(("[%s.%s] %s"):format(info.Module, info.Phase, tostring(info.Error)))
end)
```

**Gotcha — reentrancy guard:** If the reporter itself throws, its error is `warn`'d and the reporter is *not* called again for that error (prevents infinite loops).

---

### `ErrorHandler.Report(info)`

Routes an error through the active policy. Called internally by all CoreAPI modules; you may also call it from your own code.

| Parameter | Type | Description |
|-----------|------|-------------|
| `info` | `ErrorInfo` | See table below |

**`ErrorInfo` fields:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `Module` | `string` | ✓ | Module name, e.g. `"Signal"` |
| `Phase` | `string` | ✓ | Lifecycle phase, e.g. `"Listener"` |
| `Error` | `unknown` | ✓ | The raw error value (may be `nil`) |
| `Name` | `string?` | — | Optional label (rule name, key name, …) |
| `Message` | `string?` | — | Optional human-readable override message |

> **Important:** `Error` must be present as a *key*, even if its value is `nil`. Use the full table literal form — do not omit the key.

**Errors thrown by `Report` itself (before the policy runs):**
- `ErrorHandler.Report: info must be a table`
- `ErrorHandler.Report: Phase must be a string`
- `ErrorHandler.Report: Module must be a string`
- `ErrorHandler.Report: Error is required` — the `Error` key was absent entirely
- `ErrorHandler.Report: Name must be a string or nil`
- `ErrorHandler.Report: Message must be a string or nil`

```luau
-- Correct — Error key is present even though the value is nil:
ErrorHandler.Report({ Module = "MyMod", Phase = "Setup", Error = nil })

-- Also correct:
ErrorHandler.Report({ Module = "MyMod", Phase = "Callback", Error = someError })

-- Wrong — omitting the Error key entirely:
-- ErrorHandler.Report({ Module = "MyMod", Phase = "Callback" })  ← throws
```

---

### `ErrorHandler.Protect(fn, module, phase, name?)`

A convenience wrapper that calls `fn()` in a protected call. On error, calls `Report` and returns `(false, err)`. On success, returns `(true, result)`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `fn` | `() -> any` | The function to protect |
| `module` | `string` | Forwarded to `Report` as `Module` |
| `phase` | `string` | Forwarded to `Report` as `Phase` |
| `name` | `string?` | Optional, forwarded to `Report` as `Name` |

**Returns:** `(boolean, any)` — `(true, returnValue)` or `(false, errorValue)`

```luau
local ok, result = ErrorHandler.Protect(function()
    return someRiskyCall()
end, "MyModule", "Setup")

if ok then
    print("Got:", result)
end
```

---

### `ErrorHandler.TakeCollected()`

Returns all errors accumulated under the `"Collect"` policy, then clears the internal list.

**Returns:** `{ ErrorInfo }`

```luau
ErrorHandler.SetPolicy(ErrorHandler.Policy.Collect)

-- … run some code …

local errors = ErrorHandler.TakeCollected()
for _, e in errors do
    print(e.Module, e.Phase, tostring(e.Error))
end
```

---

## Gotchas

- **Policy is global.** There is no per-module policy (except Rule and FSM, which have an optional `ErrorPolicy` field in their own policy table that overrides the global for *effect* errors only).
- **The `Error` key must be present.** `rawget` cannot distinguish an absent key from a `nil` value, so `Report` iterates all keys to verify `Error` is explicitly set. Pass `Error = nil` when the error value itself is nil.
- **Reporter errors are suppressed.** If your reporter throws, the error is `warn`'d once and the reporter is skipped for that call. It will be called again on the next `Report` invocation.
- **Collect mode accumulates indefinitely.** Call `TakeCollected()` periodically to avoid memory growth.
