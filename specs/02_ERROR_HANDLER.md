# 02 — ErrorHandler Specification

`ErrorHandler` centralizes runtime callback error reporting.

It is not used for invalid API usage. Invalid API usage should error directly at the call site.

## Public API

```luau
ErrorHandler.SetPolicy(policy: Policy): ()
ErrorHandler.GetPolicy(): Policy
ErrorHandler.Report(info: ErrorInfo): ()
ErrorHandler.SetReporter(fn: ((ErrorInfo) -> ())?): ()
ErrorHandler.TakeCollected(): { ErrorInfo }
```

## Types

```luau
export type Policy = "Throw" | "Warn" | "Swallow" | "Collect"

export type ErrorInfo = {
    Phase: string,
    Module: string,
    Name: string?,
    Message: string?,
    Error: unknown,
}
```

## Default state

Default policy:

```luau
"Throw"
```

Default reporter:

```luau
nil
```

Collected error array starts empty.

## `ErrorHandler.SetPolicy(policy)`

Sets the global error policy.

### Validation

`policy` must be one of:

```text
Throw
Warn
Swallow
Collect
```

Invalid policy errors:

```text
ErrorHandler.SetPolicy: invalid policy '<value>'
```

### Behavior

- Store the policy globally for this module instance.
- Does not clear collected errors.
- Does not call reporter.

## `ErrorHandler.GetPolicy()`

Returns the current policy.

### Returns

```luau
Policy
```

No errors.

## `ErrorHandler.SetReporter(fn?)`

Installs or clears an optional reporter.

### Parameters

```luau
fn: ((ErrorInfo) -> ())?
```

### Validation

If `fn` is neither `nil` nor a function, error:

```text
ErrorHandler.SetReporter: reporter must be a function or nil
```

### Behavior

- If `fn` is a function, store it.
- If `fn` is `nil`, clear the reporter.

The reporter is called by `Report` before the policy action.

## `ErrorHandler.Report(info)`

Reports a runtime callback failure.

### Validation

`info` must be a table.

Required fields:

```luau
info.Phase: string
info.Module: string
info.Error: unknown
```

Optional fields:

```luau
info.Name: string?
info.Message: string?
```

Validation errors inside `Report` itself throw immediately. Do not report validation errors through `Report`.

Error messages:

```text
ErrorHandler.Report: info must be a table
ErrorHandler.Report: Phase must be a string
ErrorHandler.Report: Module must be a string
ErrorHandler.Report: Error is required
ErrorHandler.Report: Name must be a string or nil
ErrorHandler.Report: Message must be a string or nil
```

### Behavior order

1. Validate `info`.
2. If reporter exists, call reporter with `info`.
3. If reporter errors:
   - call `warn(...)` exactly once describing the reporter failure
   - do not recursively report the reporter error
   - continue to apply the active policy to the original `info`
4. Apply current policy.

### Policy behavior

#### `"Throw"`

Raise an error.

The error string must include:

- module
- phase
- optional name
- message or stringified error

Format:

```text
<Module>.<Phase>[<Name>]: <message/error>
```

If `Name` is nil, omit `[<Name>]`.

#### `"Warn"`

Call `warn(...)` with the formatted error string.

Do not throw.

#### `"Swallow"`

Do nothing after reporter handling.

#### `"Collect"`

Append `info` to internal collected array.

Do not throw.

## `ErrorHandler.TakeCollected()`

Returns collected error infos and clears the internal array.

### Returns

```luau
{ ErrorInfo }
```

### Behavior

- Return an array containing all collected infos in insertion order.
- Clear the internal collection.
- The returned array is a shallow copy or the old collected array detached from internal storage.
- Does not change policy.

## Reentrancy

`Report` may be called while already reporting another error.

Reporter failures must not recursively call the reporter.

If policy is `"Throw"`, nested reports may throw normally.
