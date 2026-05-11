# ErrorHandler

## Purpose

`ErrorHandler` is the single sink for runtime callback errors across all kernel modules. It supports configurable policies, custom reporters, and error collection for testing.

## Import

```luau
local ErrorHandler = require(path.to.ErrorHandler)
```

## Public API reference

```luau
ErrorHandler.SetPolicy(policy: string): ()
ErrorHandler.GetPolicy(): string
ErrorHandler.Report(info: ErrorInfo): ()
ErrorHandler.SetReporter(fn: ((ErrorInfo) -> ())?): ()
ErrorHandler.TakeCollected(): { ErrorInfo }
```

## Types

```luau
export type ErrorInfo = {
    Module: string,
    Phase: string,
    Name: string?,
    Error: unknown,
}
```

## Policies

```luau
"Throw"   -- re-throw the error after reporting
"Warn"    -- call warn() with error info
"Swallow" -- silently discard
"Collect" -- accumulate for TakeCollected (default)
```

## `ErrorHandler.SetPolicy(policy)`

Sets the active error policy.

**Error behavior**

```text
ErrorHandler.SetPolicy: policy must be one of 'Throw', 'Warn', 'Swallow', 'Collect'
```

## `ErrorHandler.GetPolicy()`

Returns the current policy string.

## `ErrorHandler.Report(info)`

Reports a runtime callback error.

**Behavior**

1. If a custom reporter is installed, call it with `info`.
   - If the reporter errors, the reporter error is silently discarded to prevent recursion.
2. Apply active policy:
   - `"Throw"` — re-throw `info.Error`.
   - `"Warn"` — call `warn()` with formatted message.
   - `"Swallow"` — discard.
   - `"Collect"` — append `info` to internal collection.

**Error behavior**

`Report` does not validate `info` fields. Callers must supply at minimum `Module`, `Phase`, and `Error`.

## `ErrorHandler.SetReporter(fn?)`

Installs a custom reporter function, or removes it with `nil`.

**Error behavior**

```text
ErrorHandler.SetReporter: fn must be a function or nil
```

## `ErrorHandler.TakeCollected()`

Returns all collected `ErrorInfo` entries since the last call and clears the collection.

Returns `{}` if no errors were collected or policy is not `"Collect"`.

## Lifecycle behavior

The default policy is `"Collect"`. The collection is not bounded.

## Not implemented

`ErrorHandler` does not filter, deduplicate, or limit collected errors.
