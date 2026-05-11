# rbx-coreapi Kernel Specification

## Modules

```text
Connection
Scheduler
ErrorHandler
Context
Signal
Store
Task
Rule
FSM
```

## Dependency order

```text
ErrorHandler
Connection
Scheduler
Context
Signal
Store
Task
Rule
FSM
```

Allowed dependencies:

```text
Connection -> ErrorHandler
Scheduler -> Connection, ErrorHandler
Context -> Connection, Scheduler, ErrorHandler
Signal -> Connection, Scheduler, ErrorHandler
Store -> Connection, Signal, Scheduler, ErrorHandler
Task -> Connection, Scheduler, ErrorHandler
Rule -> Signal, Store, Task, Scheduler, ErrorHandler, Context
FSM -> Store, Signal, Rule, Task, Scheduler, ErrorHandler, Context
```

No cyclic `require`s.

## Public API casing

Public API names use PascalCase.

```luau
Signal.New()
signal:Connect()
connection:Disconnect()

Store.Value()
store:Get()
store:Set()

Task.Start()
task:Await()

Rule.New()
rule:When()
rule:Run()

FSM.New()
fsm:Start()
mode:OnEnter()
```

Lowercase aliases are not part of the API.

## Callback shapes

Rule callbacks:

```luau
(ctx, payload, frame)
```

FSM lifecycle callbacks:

```luau
(ctx, frame)
```

FSM update callbacks:

```luau
(ctx, dt, frame)
```

Task callbacks:

```luau
(token)
```

## Runtime boundaries

`Signal` owns synchronous event streams.

`Store` owns reactive state.

`Task` owns cancellable asynchronous work.

`Rule` owns signal-to-effect orchestration.

`FSM` owns lifecycle scope and active mode paths.

`Context` owns scoped capability access.

`frame` owns temporary invocation metadata.

## Error behavior

Invalid API usage errors at the call site.

Runtime callback errors are routed through `ErrorHandler.Report`.

## Scheduler behavior

Only `Scheduler` directly uses Roblox scheduling, timing, cancellation, or frame primitives.

Other modules use:

```luau
Scheduler.Defer(fn)
Scheduler.Delay(seconds, fn)
Scheduler.Cancel(handle)
Scheduler.Now()
Scheduler.OnStep(fn)
```

## Time source

`Scheduler.Now()` defaults to Roblox `time()`.

`time()` is used for gameplay/runtime elapsed time. `os.clock()` is reserved for benchmarking and explicit performance measurement drivers.

## Nil behavior

If an API supports `nil` as a value, it tracks presence separately from value.

A supported nil value is never detected by `value ~= nil`.
