# Runtime Error Semantics

The Kernel distinguishes usage errors from runtime failures.

## Usage errors

Usage errors are developer mistakes.

Examples:

- invalid argument type;
- using a destroyed handle;
- forged receiver;
- invalid policy value;
- missing required configuration;
- illegal mutation of readonly handle.

Usage errors raise immediately.

Good:

```luau
error("Signal.Connect: listener must be a function", 2)
```

Usage errors do not route through `ErrorHandler`.

## Runtime failures

Runtime failures come from user-provided callbacks or external runtime behavior.

Examples:

- signal listener throws;
- store subscriber throws;
- connection cleanup throws;
- scheduler callback throws;
- rule effect throws;
- FSM guard throws;
- tracer callback throws.

Runtime callback failures route through `ErrorHandler`, unless the module's domain explicitly models failure as state.

Examples:

- `Task` task body failures settle as `Errored`.
- `ErrorHandler.Protect` implements protected execution.
- `Connection` cleanup failures route through `ErrorHandler.Protect`.
- `Scheduler` callbacks route through `ErrorHandler`.
- `Signal` listener/operator callback failures route through `ErrorHandler`.
- `Store` subscriber/updater/equality/derive failures route through `ErrorHandler`.
- `Rule` effect/tracer failures route through `ErrorHandler` or rule-local policy.
- `FSM` enter/exit/guard/tracer failures route through `ErrorHandler` or FSM-local policy.

Do not create parallel runtime error systems.

## `pcall`

`pcall` is allowed only with clear domain meaning.

Allowed:

1. implementing `ErrorHandler.Protect`;
2. capturing task body failure to settle a task as `Errored`;
3. try/finally restoration followed by `ErrorHandler.Report` or documented rethrow;
4. protecting reporter/tracer/finalizer callbacks before routing failures.

Suspicious:

```luau
local ok, err = pcall(callback)

if not ok then
    warn(err)
end
```

This bypasses `ErrorHandler`.

Try/finally pattern:

```luau
local blockSucceeded, blockError = pcall(block)

restoreBatchingState()
flushPendingNotifications()

if not blockSucceeded then
    ErrorHandler.Report({
        Module = "Store",
        Phase = "Batch",
        Error = blockError,
    })
end
```

The error must not disappear into an ad-hoc path.

## Sentinel absence

Do not rely on `nil` to mean a table field exists.

Lua/Luau tables cannot store `nil` fields.

If absence is meaningful, use a sentinel.

Good:

```luau
Error = ErrorHandler.NoError
```

Bad:

```luau
Error = nil
```

Sentinels should be frozen, unique, readable, and typed.
