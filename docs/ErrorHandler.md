# ErrorHandler API Reference

`ErrorHandler` is the shared runtime error-routing module for CoreAPI systems that execute user-provided or externally registered callbacks.

Place this module at:

```text
ReplicatedStorage/Shared/Kernel/ErrorHandler
```

Its job is to make callback failure behavior consistent across the codebase. Signal listeners, store subscribers, rule effects, lifecycle callbacks, task finalizers, finite-state-machine hooks, and any other protected execution path should report failures through `ErrorHandler.Report` or `ErrorHandler.Protect`.

The module separates three concerns that are often mixed together in application code:

1. **What failed** — represented by `ErrorInfo`.
2. **Who observes failures** — represented by an optional reporter.
3. **What the system does after observing the failure** — represented by the active policy.

The active policy is global. Set it once during startup, then allow the rest of the framework to route failures consistently.

---

## Design Goals

`ErrorHandler` is intentionally small, explicit, and centralized.

It exists so that every runtime callback failure follows the same path:

```luau
callback fails
    ↓
ErrorHandler.Report(errorInfo)
    ↓
optional reporter observes a snapshot
    ↓
active policy decides what happens next
```

This produces predictable behavior in development, production, and tests.

The module is designed around these principles:

- **Declarative error context**: callers describe where and why the error occurred instead of constructing inconsistent strings by hand.
- **Explicit policy control**: startup code decides whether failures throw, warn, collect, or disappear.
- **Reporter isolation**: a broken reporter cannot recursively break error handling.
- **Typed public surface**: public APIs use exported Luau types and avoid unstructured `any`.
- **Sentinel-based absence**: callers use `ErrorHandler.NoError` when there is intentionally no captured error value.
- **Caller-facing errors**: usage errors and thrown reports are raised as close as possible to the external caller, not deep inside validation helpers.

---

## Importing

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ErrorHandler = require(ReplicatedStorage.Shared.Kernel.ErrorHandler)
```

---

## Exported Types

### `ErrorHandler.Policy`

```luau
type Policy = "Throw" | "Warn" | "Swallow" | "Collect"
```

A string-literal union representing the four possible global error-routing behaviors.

Use values from `ErrorHandler.Policy` instead of raw strings:

```luau
ErrorHandler.SetPolicy(ErrorHandler.Policy.Warn)
```

Avoid this unless you are intentionally bridging untyped data:

```luau
ErrorHandler.SetPolicy("Warn")
```

The string literal is valid, but the enum table is clearer and prevents spelling drift.

---

### `ErrorHandler.PolicySet`

```luau
type PolicySet = {
    Throw: "Throw",
    Warn: "Warn",
    Swallow: "Swallow",
    Collect: "Collect",
}
```

The type of the frozen `ErrorHandler.Policy` table.

This table exists so code can depend on named values instead of raw strings.

---

### `ErrorHandler.NoErrorSentinel`

```luau
type NoErrorSentinel = typeof(ErrorHandler.NoError)
```

A unique frozen table used to explicitly say:

> This report intentionally has no captured error value.

Use this instead of `nil`:

```luau
ErrorHandler.Report({
    Module = "Bootstrap",
    Phase = "Validation",
    Message = "Configuration was missing an optional section",
    Error = ErrorHandler.NoError,
})
```

`nil` cannot be used because Luau/Lua tables do not store fields whose value is `nil`. Writing `Error = nil` is equivalent to omitting the key entirely.

---

### `ErrorHandler.ReportedError`

```luau
type ReportedError = unknown
```

The raw error value associated with a report.

This is intentionally `unknown`, not `string`, because protected Luau calls may fail with values that are not guaranteed to be strings. In practice, most errors are strings, but the error channel can still carry arbitrary values. Treating this as `unknown` forces callers and reporters to inspect or stringify the value intentionally.

Recommended handling:

```luau
local readableError = tostring(errorInfo.Error)
```

Check for the sentinel before stringifying when the distinction matters:

```luau
if errorInfo.Error == ErrorHandler.NoError then
    print("No captured error value was available")
else
    print(tostring(errorInfo.Error))
end
```

---

### `ErrorHandler.ErrorInfo`

```luau
type ErrorInfo = {
    Module: string,
    Phase: string,
    Name: string?,
    Message: string?,
    Error: ReportedError,
}
```

The structured description of one reported failure.

`ErrorInfo` has five fields because each field answers a different diagnostic question.

| Field | Required | Type | Purpose |
|---|---:|---|---|
| `Module` | Yes | `string` | Broad owner or subsystem where the failure occurred. |
| `Phase` | Yes | `string` | Operation, lifecycle stage, or callback category that was running. |
| `Name` | No | `string?` | Specific user-provided or domain-specific label, when available. |
| `Message` | No | `string?` | Human-facing explanation that overrides the raw error text in output. |
| `Error` | Yes | `ReportedError` | Raw captured error value, or `ErrorHandler.NoError` when no value exists. |

#### `Module`

`Module` describes the broad subsystem responsible for the callback or operation.

Examples:

```luau
Module = "Signal"
Module = "Store"
Module = "RuleEngine"
Module = "FiniteStateMachine"
Module = "TaskScheduler"
```

Use `Module` to answer:

> Where in the framework did this happen?

It should usually be stable and low-cardinality. Do not put dynamic names, user IDs, or object paths here. Use `Name` for specific labels.

Good:

```luau
Module = "Signal"
```

Poor:

```luau
Module = "Signal.PlayerAdded.Listener42"
```

---

#### `Phase`

`Phase` describes what kind of work was happening inside the module.

Examples:

```luau
Phase = "Listener"
Phase = "Subscriber"
Phase = "EnterCallback"
Phase = "ExitCallback"
Phase = "Effect"
Phase = "Finally"
Phase = "Middleware"
```

Use `Phase` to answer:

> What was the system doing when the failure happened?

Together, `Module` and `Phase` form the primary location label:

```text
Signal.Listener
Store.Subscriber
RuleEngine.Effect
FiniteStateMachine.EnterCallback
```

---

#### `Name`

`Name` is an optional specific label for the failed callback, rule, state, key, task, listener, or other domain object.

Examples:

```luau
Name = "OnPlayerJoined"
Name = "InventoryStore"
Name = "ValidatePurchaseRule"
Name = "CombatState"
```

Use `Name` to answer:

> Which specific registered thing failed?

When present, formatted output includes it in brackets:

```text
Signal.Listener[OnPlayerJoined]: attempt to index nil
```

When absent, output omits the bracketed section:

```text
Signal.Listener: attempt to index nil
```

Use `Name` only when it improves diagnosis. Do not invent placeholder names like `"Unknown"`; omit the field instead.

---

#### `Message`

`Message` is an optional human-facing explanation.

When present, it is used as the readable reason instead of `tostring(Error)`.

Example:

```luau
ErrorHandler.Report({
    Module = "RuleEngine",
    Phase = "Effect",
    Name = "GrantDailyReward",
    Message = "Daily reward effect failed while updating player currency",
    Error = caughtError,
})
```

Readable output:

```text
RuleEngine.Effect[GrantDailyReward]: Daily reward effect failed while updating player currency
```

Use `Message` when:

- the raw error is too low-level;
- the API can provide better domain context;
- the same raw error might be ambiguous without explanation;
- you want production warnings to be easier to understand.

Do not use `Message` to hide important details permanently. Reporters still receive the raw `Error` field and can log both.

---

#### `Error`

`Error` is the raw captured failure value.

Usually this is the second value from `pcall`, or the third value from `ErrorHandler.Protect`.

Example:

```luau
local callbackSucceeded, callbackError = pcall(callback)

if not callbackSucceeded then
    ErrorHandler.Report({
        Module = "Signal",
        Phase = "Listener",
        Name = listenerName,
        Error = callbackError,
    })
end
```

If there is intentionally no captured runtime error, use `ErrorHandler.NoError`:

```luau
ErrorHandler.Report({
    Module = "Bootstrap",
    Phase = "Validation",
    Message = "Optional diagnostics were unavailable",
    Error = ErrorHandler.NoError,
})
```

Never use `nil` for `Error`.

This is invalid:

```luau
ErrorHandler.Report({
    Module = "Bootstrap",
    Phase = "Validation",
    Error = nil,
})
```

At runtime, that is the same as omitting `Error`, and `Report` will raise a usage error.

---

### `ErrorHandler.Reporter`

```luau
type Reporter = (errorInfo: ErrorInfo) -> ()
```

A callback invoked before the active policy is applied.

Reporters are useful for telemetry, custom logging, analytics, developer tooling, or test assertions.

The reporter receives a snapshot of the report so that future internal mutations cannot affect what the reporter saw.

Example:

```luau
ErrorHandler.SetReporter(function(errorInfo)
    print(`[{errorInfo.Module}.{errorInfo.Phase}] {tostring(errorInfo.Error)}`)
end)
```

Reporter failures are caught and warned. A reporter error does not recursively invoke the reporter again.

---

## Public Constants

### `ErrorHandler.Policy`

```luau
ErrorHandler.Policy.Throw
ErrorHandler.Policy.Warn
ErrorHandler.Policy.Swallow
ErrorHandler.Policy.Collect
```

A frozen enum-like table containing valid policy values.

#### `Throw`

Development-oriented behavior.

`Report` raises an error after the reporter runs.

Use this when you want callback errors to stop execution loudly and point developers toward the caller.

```luau
ErrorHandler.SetPolicy(ErrorHandler.Policy.Throw)
```

#### `Warn`

Production-oriented behavior.

`Report` emits a warning after the reporter runs, then execution continues.

```luau
ErrorHandler.SetPolicy(ErrorHandler.Policy.Warn)
```

#### `Swallow`

Silent behavior.

`Report` calls the reporter if one exists, then discards the error.

This is rarely appropriate outside tests or intentionally fault-tolerant systems.

```luau
ErrorHandler.SetPolicy(ErrorHandler.Policy.Swallow)
```

#### `Collect`

Testing and inspection behavior.

`Report` calls the reporter if one exists, then stores a snapshot in an internal list. Use `TakeCollected` or `ClearCollected` to manage the list.

```luau
ErrorHandler.SetPolicy(ErrorHandler.Policy.Collect)
```

---

### `ErrorHandler.NoError`

```luau
ErrorHandler.NoError: ErrorHandler.NoErrorSentinel
```

A sentinel value used when an error report is valid but no raw error value was captured.

Example:

```luau
ErrorHandler.Report({
    Module = "Configuration",
    Phase = "Fallback",
    Message = "Using default configuration because custom configuration was absent",
    Error = ErrorHandler.NoError,
})
```

Why a sentinel is used:

- `nil` cannot be stored as a table field;
- omitted `Error` should be treated as a caller mistake;
- an explicit sentinel communicates intent;
- reporters can distinguish “no captured error” from “some captured error value.”

---

## Public Functions

## `ErrorHandler.SetPolicy`

```luau
ErrorHandler.SetPolicy(policy: ErrorHandler.Policy): ()
```

Sets the global error-routing policy.

### Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `policy` | `ErrorHandler.Policy` | Yes | One of `ErrorHandler.Policy.Throw`, `Warn`, `Swallow`, or `Collect`. |

### Returns

Nothing.

### Behavior

The policy affects every future call to `ErrorHandler.Report` and every failed call routed through `ErrorHandler.Protect`.

The policy does not retroactively affect already collected errors.

### Possible Errors

```text
ErrorHandler.SetPolicy: invalid policy '<value>'
```

Raised when `policy` is not exactly one of the supported policy values.

### Example

```luau
ErrorHandler.SetPolicy(ErrorHandler.Policy.Warn)
```

### Recommended Usage

Set the policy once at startup.

Example:

```luau
if RunService:IsStudio() then
    ErrorHandler.SetPolicy(ErrorHandler.Policy.Throw)
else
    ErrorHandler.SetPolicy(ErrorHandler.Policy.Warn)
end
```

Avoid repeatedly changing policy during normal runtime unless you are writing tests or a controlled diagnostic tool.

---

## `ErrorHandler.GetPolicy`

```luau
ErrorHandler.GetPolicy(): ErrorHandler.Policy
```

Returns the currently active global policy.

### Parameters

None.

### Returns

| Type | Description |
|---|---|
| `ErrorHandler.Policy` | The active policy. |

### Example

```luau
local activePolicy = ErrorHandler.GetPolicy()

if activePolicy == ErrorHandler.Policy.Collect then
    print("Errors are being collected for inspection")
end
```

---

## `ErrorHandler.SetReporter`

```luau
ErrorHandler.SetReporter(reporter: ErrorHandler.Reporter?): ()
```

Installs or removes the global reporter.

The reporter is called before the active policy is applied.

### Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `reporter` | `ErrorHandler.Reporter?` | No | Function to receive every error report. Pass `nil` to remove the reporter. |

### Returns

Nothing.

### Behavior

When a reporter is installed:

1. `Report` validates the incoming `ErrorInfo`.
2. The reporter receives a snapshot of the validated `ErrorInfo`.
3. The active policy is applied.

If the reporter throws, `ErrorHandler` catches that reporter failure and emits a warning:

```text
ErrorHandler: reporter failed: <reporter error>
```

The reporter is not called recursively for its own failure.

### Possible Errors

```text
ErrorHandler.SetReporter: reporter must be a function or nil
```

Raised when the provided value is neither a function nor `nil`.

### Example: Console Reporter

```luau
ErrorHandler.SetReporter(function(errorInfo)
    print(`Reported failure at {errorInfo.Module}.{errorInfo.Phase}`)
    print(`Name: {errorInfo.Name or "<none>"}`)
    print(`Error: {tostring(errorInfo.Error)}`)
end)
```

### Example: Telemetry Reporter

```luau
ErrorHandler.SetReporter(function(errorInfo)
    AnalyticsService:LogCustomEvent("CoreAPIError", {
        module = errorInfo.Module,
        phase = errorInfo.Phase,
        name = errorInfo.Name,
        message = errorInfo.Message,
        error = tostring(errorInfo.Error),
    })
end)
```

### Reporter Failure Isolation

This is safe:

```luau
ErrorHandler.SetReporter(function()
    error("Telemetry service unavailable")
end)

ErrorHandler.Report({
    Module = "Signal",
    Phase = "Listener",
    Error = "Listener failed",
})
```

The reporter failure is warned, but it does not recursively report itself forever.

---

## `ErrorHandler.GetReporter`

```luau
ErrorHandler.GetReporter(): ErrorHandler.Reporter?
```

Returns the currently installed reporter, if any.

### Parameters

None.

### Returns

| Type | Description |
|---|---|
| `ErrorHandler.Reporter?` | The active reporter function, or `nil` if none is installed. |

### Example

```luau
local previousReporter = ErrorHandler.GetReporter()

ErrorHandler.SetReporter(function(errorInfo)
    print("Temporary reporter saw:", errorInfo.Module, errorInfo.Phase)
end)

-- Later:
ErrorHandler.SetReporter(previousReporter)
```

---

## `ErrorHandler.Report`

```luau
ErrorHandler.Report(errorInfo: ErrorHandler.ErrorInfo): ()
```

Routes a structured error report through the global reporter and active policy.

This is the central function of the module.

### Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `errorInfo` | `ErrorHandler.ErrorInfo` | Yes | Structured description of the failure. |

### Returns

Nothing when the active policy is `Warn`, `Swallow`, or `Collect`.

When the active policy is `Throw`, this function raises an error and does not return.

### Behavior

`Report` performs the following steps:

1. Validates the incoming `errorInfo` table.
2. Creates a normalized `ErrorInfo` value.
3. Calls the active reporter, if present.
4. Applies the active policy.

### Policy-Specific Behavior

| Active Policy | Reporter Called? | Result |
|---|---:|---|
| `Throw` | Yes | Raises a formatted error. |
| `Warn` | Yes | Calls `warn` with a formatted message. |
| `Swallow` | Yes | Does nothing after reporting. |
| `Collect` | Yes | Stores a snapshot for `TakeCollected`. |

### Formatted Message

If `Name` is absent:

```text
<Module>.<Phase>: <reason>
```

If `Name` is present:

```text
<Module>.<Phase>[<Name>]: <reason>
```

The reason is:

1. `Message`, when provided;
2. `"No captured error value"`, when `Error == ErrorHandler.NoError`;
3. `tostring(Error)`, otherwise.

### Possible Usage Errors

`Report` validates its input before applying policy. These validation failures are usage errors and are raised immediately.

```text
ErrorHandler.Report: errorInfo must be a table
ErrorHandler.Report: Module must be a string
ErrorHandler.Report: Phase must be a string
ErrorHandler.Report: Name must be a string or nil
ErrorHandler.Report: Message must be a string or nil
ErrorHandler.Report: Error must be a captured error value or ErrorHandler.NoError
```

Usage errors are not routed through the reporter. They indicate incorrect use of the error-handling API itself.

### Example: Reporting a Caught Callback Error

```luau
local callbackSucceeded, callbackError = pcall(listener)

if not callbackSucceeded then
    ErrorHandler.Report({
        Module = "Signal",
        Phase = "Listener",
        Name = "PlayerJoinedListener",
        Error = callbackError,
    })
end
```

### Example: Reporting With a Human Message

```luau
ErrorHandler.Report({
    Module = "InventoryStore",
    Phase = "Subscriber",
    Name = "RecalculateWeight",
    Message = "Inventory subscriber failed while recalculating total carried weight",
    Error = caughtError,
})
```

### Example: Reporting Without a Captured Error Value

```luau
ErrorHandler.Report({
    Module = "Bootstrap",
    Phase = "Validation",
    Message = "Optional configuration section was not provided",
    Error = ErrorHandler.NoError,
})
```

### Complex Case: Reporter + Collect Policy

```luau
ErrorHandler.SetPolicy(ErrorHandler.Policy.Collect)

ErrorHandler.SetReporter(function(errorInfo)
    print("Reporter saw", errorInfo.Module, errorInfo.Phase)
end)

ErrorHandler.Report({
    Module = "RuleEngine",
    Phase = "Effect",
    Name = "GrantReward",
    Error = "Reward service unavailable",
})

local collectedErrors = ErrorHandler.TakeCollected()
print(#collectedErrors) -- 1
```

The reporter sees the error immediately. The collected copy remains available until taken or cleared.

---

## `ErrorHandler.Protect`

```luau
ErrorHandler.Protect<Result>(
    callback: () -> Result,
    moduleName: string,
    phaseName: string,
    errorName: string?
): (boolean, Result?, ErrorHandler.ReportedError?)
```

Runs a callback inside `pcall` and reports failures through `ErrorHandler.Report`.

This is the convenience API for most callback execution sites.

### Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `callback` | `() -> Result` | Yes | Function to execute safely. |
| `moduleName` | `string` | Yes | Forwarded to `ErrorInfo.Module`. |
| `phaseName` | `string` | Yes | Forwarded to `ErrorInfo.Phase`. |
| `errorName` | `string?` | No | Forwarded to `ErrorInfo.Name`. |

### Returns

| Position | Type | Meaning on Success | Meaning on Failure |
|---:|---|---|---|
| 1 | `boolean` | `true` | `false` |
| 2 | `Result?` | The callback result | `nil` |
| 3 | `ReportedError?` | `nil` | The caught error value |

### Behavior

If the callback succeeds:

```luau
return true, callbackResult, nil
```

If the callback fails:

1. The caught error is reported with `Module`, `Phase`, `Name`, and `Error`.
2. The active policy is applied.
3. If the policy does not throw, `Protect` returns:

```luau
return false, nil, callbackError
```

If the active policy is `Throw`, the failed `Protect` call does not return because `Report` raises an error.

### Example: Listener Execution

```luau
local listenerSucceeded, listenerResult, listenerError = ErrorHandler.Protect(
    function()
        return listener(player)
    end,
    "Signal",
    "Listener",
    "PlayerJoinedListener"
)

if listenerSucceeded then
    print("Listener returned", listenerResult)
else
    print("Listener failed", tostring(listenerError))
end
```

### Example: Store Subscriber

```luau
local subscriberSucceeded = ErrorHandler.Protect(
    function()
        subscriber(newValue, oldValue)
    end,
    "Store",
    "Subscriber",
    storeKey
)

if not subscriberSucceeded then
    print("Subscriber failed but policy allowed execution to continue")
end
```

### Type Inference Notes

`Protect` is generic over the callback result.

```luau
local succeeded, playerName = ErrorHandler.Protect(function()
    return player.Name
end, "Players", "ReadName")
```

Here, Luau can infer `playerName` as `string?` because the callback returns `string` and `Protect` returns `Result?` in the second position.

### Limitation: Single Return Value

The current `Protect` signature is designed for callbacks that return one meaningful result.

If a callback returns multiple values, only the first result is represented by the generic `Result` type. Prefer wrapping multiple values in a table when clarity matters:

```luau
local succeeded, result = ErrorHandler.Protect(function()
    return {
        Player = player,
        Profile = profile,
    }
end, "Profiles", "Load")
```

---

## `ErrorHandler.TakeCollected`

```luau
ErrorHandler.TakeCollected(): { ErrorHandler.ErrorInfo }
```

Returns all currently collected error reports, then clears the internal collection list.

### Parameters

None.

### Returns

| Type | Description |
|---|---|
| `{ ErrorHandler.ErrorInfo }` | The collected error snapshots. |

### Behavior

This function transfers ownership of the current collected list to the caller and resets internal collection to an empty list.

If no errors have been collected, it returns an empty array.

### Example

```luau
ErrorHandler.SetPolicy(ErrorHandler.Policy.Collect)

ErrorHandler.Report({
    Module = "RuleEngine",
    Phase = "Effect",
    Name = "TestRule",
    Error = "Example failure",
})

local collectedErrors = ErrorHandler.TakeCollected()
print(#collectedErrors) -- 1

local collectedAgain = ErrorHandler.TakeCollected()
print(#collectedAgain) -- 0
```

### Recommended Testing Pattern

```luau
ErrorHandler.SetPolicy(ErrorHandler.Policy.Collect)
ErrorHandler.ClearCollected()

runSystemUnderTest()

local collectedErrors = ErrorHandler.TakeCollected()
expect(#collectedErrors).to.equal(1)
expect(collectedErrors[1].Module).to.equal("RuleEngine")
```

---

## `ErrorHandler.ClearCollected`

```luau
ErrorHandler.ClearCollected(): ()
```

Clears the internal collection list without returning its contents.

### Parameters

None.

### Returns

Nothing.

### Behavior

This function is useful before tests, before diagnostic sessions, or when collected errors are no longer relevant.

### Example

```luau
ErrorHandler.SetPolicy(ErrorHandler.Policy.Collect)
ErrorHandler.ClearCollected()
```

---

## `ErrorHandler.RaiseUsageError`

```luau
ErrorHandler.RaiseUsageError(message: string): never
```

Raises a usage error attributed to the first caller outside the CoreAPI kernel.

Use this instead of `error(message, N)` throughout the kernel. This function walks the call stack, skips internal Kernel frames, and raises the error at the first external caller frame — no matter how deep the validation logic is nested.

### Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `message` | `string` | Yes | Human-readable description of the incorrect usage. |

### Returns

`never`. This function always raises and never returns.

### When to Use

Use `RaiseUsageError` when the caller passed an invalid argument, called a method in an invalid state, or violated an API contract.

Do not use it to report runtime callback failures — use `Report` or `Protect` for those.

### Example

```luau
function Records.GetTaskRecord(task: Task<any>, message: string): TaskRecord
    local taskRecord = taskRecords[task]
    if taskRecord == nil then
        return ErrorHandler.RaiseUsageError(message)
    end
    return taskRecord
end
```

---

## `ErrorHandler.ReportWithPolicy`

```luau
ErrorHandler.ReportWithPolicy(errorInfo: ErrorHandler.ErrorInfo, policy: ErrorHandler.Policy): ()
```

Routes a structured error report through the global reporter, then applies a **caller-supplied** policy instead of the global active policy.

### Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `errorInfo` | `ErrorHandler.ErrorInfo` | Yes | Structured description of the failure. |
| `policy` | `ErrorHandler.Policy` | Yes | Policy to apply for this specific report, overriding the global active policy. |

### Returns

Nothing when the supplied `policy` is `Warn`, `Swallow`, or `Collect`.

When the supplied `policy` is `Throw`, this function raises an error and does not return.

### Behavior

Identical to `Report`, except the active global policy is ignored. The caller-supplied `policy` is applied directly.

This allows modules like `Rule` and `FSM` to carry per-instance `ErrorPolicy` configuration. When a rule or FSM has a local `ErrorPolicy` set, its effect errors are routed through `ReportWithPolicy(errorInfo, instancePolicy)` instead of `Report(errorInfo)`.

When `errorPolicy` is `nil` (no local override), callers should use `Report(errorInfo)` instead to apply the global policy.

### Example: Rule-local Error Policy

```luau
local function handleEffectError(ruleName: string, err: unknown, errorPolicy: ErrorHandler.Policy?): ()
    local errorInfo = { Module = "Rule", Phase = "Effect", Name = ruleName, Error = err }
    if errorPolicy ~= nil then
        ErrorHandler.ReportWithPolicy(errorInfo, errorPolicy)
    else
        ErrorHandler.Report(errorInfo)
    end
end
```

---

## Recommended Startup Configuration

### Development

In development, prefer `Throw` so failures are loud and close to the caller.

```luau
ErrorHandler.SetPolicy(ErrorHandler.Policy.Throw)
```

### Production

In production, prefer `Warn` when callback failures should not crash entire systems.

```luau
ErrorHandler.SetPolicy(ErrorHandler.Policy.Warn)
```

### Automated Tests

In tests, prefer `Collect` so assertions can inspect failures deterministically.

```luau
ErrorHandler.SetPolicy(ErrorHandler.Policy.Collect)
ErrorHandler.ClearCollected()
```

### Temporary Suppression

Use `Swallow` sparingly.

```luau
ErrorHandler.SetPolicy(ErrorHandler.Policy.Swallow)
```

This can hide real bugs and should usually be limited to targeted tests or intentionally best-effort cleanup paths.

---

## Stack-Aware Error Attribution

The implementation uses stack inspection to raise errors from the most useful caller-facing location.

This matters because `ErrorHandler` is internally decomposed into validation helpers and policy helpers. A naive implementation using `error(message, 2)` would often point at an internal helper rather than the external call site.

Instead, usage errors and `Throw` policy errors attempt to skip internal `ErrorHandler` frames and attribute the error to the first caller outside the module.

### Practical Result

If external code does this:

```luau
ErrorHandler.SetPolicy("Explode" :: any)
```

The raised error should point near the external call, not deep inside `getValidatedPolicy`.

### Fallback Behavior

If stack inspection cannot find an external frame within the configured inspection limit, the module falls back to a safe helper-level error location.

---

## Reporter Behavior in Complex Cases

### Reporter Runs Before Policy

The reporter always runs before the active policy action.

This means a reporter can observe errors even when the active policy is `Throw`.

```luau
ErrorHandler.SetPolicy(ErrorHandler.Policy.Throw)

ErrorHandler.SetReporter(function(errorInfo)
    print("This runs before the throw")
end)
```

### Reporter Receives a Snapshot

The reporter receives a copied `ErrorInfo` table.

This prevents accidental coupling between the reporter and internal module state.

### Reporter Failure Does Not Recurse

If a reporter throws, the module warns directly and does not call the reporter again for that reporter failure.

This prevents infinite loops such as:

```text
Report error
    ↓
Reporter throws
    ↓
Report reporter error
    ↓
Reporter throws again
    ↓
...
```

### Reporter Failure Does Not Cancel Policy

If a reporter fails, the original error still proceeds to the active policy.

For example, under `Warn`, both of these may happen:

```text
ErrorHandler: reporter failed: <reporter error>
<Module>.<Phase>: <original error>
```

---

## Collection Behavior in Complex Cases

### Collected Values Are Snapshots

Collected errors are snapshots of normalized `ErrorInfo` values.

This means later mutation of the original report table does not affect the collected data.

```luau
local errorInfo = {
    Module = "Signal",
    Phase = "Listener",
    Error = "Original error",
}

ErrorHandler.Report(errorInfo)

errorInfo.Module = "Mutated"

local collectedErrors = ErrorHandler.TakeCollected()
print(collectedErrors[1].Module) -- "Signal"
```

### Collection Can Grow Indefinitely

`Collect` mode stores errors until `TakeCollected` or `ClearCollected` is called.

Use this policy intentionally. Long-running production sessions should not leave `Collect` enabled indefinitely unless another system drains it.

---

## Gotchas

### `Error = nil` Does Not Work

This is the most important gotcha.

In Luau/Lua, assigning `nil` to a table field removes the field.

So this:

```luau
{
    Error = nil,
}
```

is equivalent to this:

```luau
{}
```

Use this instead:

```luau
{
    Error = ErrorHandler.NoError,
}
```

---

### `Message` Replaces the Displayed Error Reason

When `Message` is provided, warnings and thrown report messages use `Message` instead of `tostring(Error)`.

The raw `Error` is still available to reporters and collected errors.

---

### `Swallow` Still Calls the Reporter

`Swallow` means the policy does nothing after reporting. It does not mean reporters are skipped.

This allows systems to log silently while continuing execution.

---

### `Throw` Means `Protect` May Not Return

When `Protect` catches a callback failure under `Throw` policy, it reports the error, and `Report` raises.

Code after `Protect` will not run in that failure case.

---

### Reporter Return Values Are Ignored

A reporter is typed as:

```luau
(errorInfo: ErrorInfo) -> ()
```

It is for observation only. Return values are ignored.

---

### `ReportedError` Is `unknown` by Design

Do not assume the raw error is a string.

Use `tostring` unless you have a stronger invariant in your own code.

---

## Best Practices

### Prefer `Protect` Around User Callbacks

Most framework code should not call `pcall` and `Report` manually.

Prefer:

```luau
ErrorHandler.Protect(callback, "Signal", "Listener", listenerName)
```

Manual reporting is best for cases where you already caught an error or need custom `Message` text.

---

### Keep `Module` Broad

Good:

```luau
Module = "Store"
```

Avoid:

```luau
Module = "PlayerInventoryStoreSubscriberForUser123"
```

---

### Keep `Phase` Action-Oriented

Good:

```luau
Phase = "Subscriber"
Phase = "Effect"
Phase = "EnterCallback"
```

Avoid vague phases:

```luau
Phase = "Error"
Phase = "Thing"
Phase = "Run"
```

---

### Use `Name` for High-Cardinality Detail

Good:

```luau
Module = "RuleEngine",
Phase = "Effect",
Name = "GrantDailyReward",
```

Avoid packing everything into one string:

```luau
Module = "RuleEngine.GrantDailyReward.Effect"
```

---

### Use `Message` for Domain Context

Good:

```luau
Message = "Quest reward effect failed while granting currency"
```

Avoid messages that merely repeat the location:

```luau
Message = "RuleEngine effect failed"
```

The location is already encoded by `Module`, `Phase`, and `Name`.

---

### Reset Global State in Tests

Because policy, reporter, and collected errors are global module state, tests should clean up after themselves.

```luau
local previousPolicy = ErrorHandler.GetPolicy()
local previousReporter = ErrorHandler.GetReporter()

ErrorHandler.SetPolicy(ErrorHandler.Policy.Collect)
ErrorHandler.SetReporter(nil)
ErrorHandler.ClearCollected()

-- test body

ErrorHandler.ClearCollected()
ErrorHandler.SetReporter(previousReporter)
ErrorHandler.SetPolicy(previousPolicy)
```

---

## Full Example: Signal Listener Routing

```luau
local function callListener(listener: (Player) -> (), listenerName: string, player: Player): ()
    ErrorHandler.Protect(function()
        listener(player)
    end, "Signal", "Listener", listenerName)
end
```

If the listener fails under `Warn` policy, output might look like:

```text
Signal.Listener[OnPlayerJoined]: attempt to index nil with 'Name'
```

---

## Full Example: Rule Effect With Custom Context

```luau
local function runRuleEffect(ruleName: string, effect: () -> ()): ()
    local effectSucceeded, effectError = pcall(effect)

    if effectSucceeded then
        return
    end

    ErrorHandler.Report({
        Module = "RuleEngine",
        Phase = "Effect",
        Name = ruleName,
        Message = "Rule effect failed while applying gameplay side effects",
        Error = effectError,
    })
end
```

This preserves the raw caught value while presenting a better human-readable warning.

---

## Full Example: Test Collection

```luau
ErrorHandler.SetPolicy(ErrorHandler.Policy.Collect)
ErrorHandler.ClearCollected()

ErrorHandler.Report({
    Module = "TestModule",
    Phase = "TestPhase",
    Name = "ExampleCase",
    Error = "Expected failure",
})

local collectedErrors = ErrorHandler.TakeCollected()

assert(#collectedErrors == 1)
assert(collectedErrors[1].Module == "TestModule")
assert(collectedErrors[1].Phase == "TestPhase")
assert(collectedErrors[1].Name == "ExampleCase")
assert(collectedErrors[1].Error == "Expected failure")
```

---

## Full Example: Production Reporter

```luau
ErrorHandler.SetPolicy(ErrorHandler.Policy.Warn)

ErrorHandler.SetReporter(function(errorInfo)
    local readableLocation = if errorInfo.Name == nil
        then `{errorInfo.Module}.{errorInfo.Phase}`
        else `{errorInfo.Module}.{errorInfo.Phase}[{errorInfo.Name}]`

    local readableError = if errorInfo.Error == ErrorHandler.NoError
        then "No captured error value"
        else tostring(errorInfo.Error)

    print(`Telemetry Error: {readableLocation} - {readableError}`)
end)
```

---

## Summary

Use `ErrorHandler` when code executes callbacks or user-provided behavior that should not fail inconsistently.

Use:

- `SetPolicy` once at startup;
- `SetReporter` for logging or telemetry;
- `Protect` for most callback execution;
- `Report` when you already have structured failure context;
- `NoError` when absence of a captured error is intentional;
- `TakeCollected` and `ClearCollected` for tests and diagnostics.

The result is a single, predictable, typed, and inspectable error pipeline for the entire shared kernel.
