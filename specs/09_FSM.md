# 09 — FSM Specification

`FSM` owns lifecycle scope and active mode path.

It manages modes, hierarchy, transitions, mode-local context, rules, tasks, guards, update callbacks, active stores, transition events, snapshots, and history.

## Public API

```luau
FSM.New<Ctx>(ctx: Context.Context<Ctx> | Ctx, opts: Policy?): FSM.FSM<Ctx>
FSM.IsFSM(value: unknown): boolean
FSM.IsMode(value: unknown): boolean
FSM.DefaultPolicy(): Policy
FSM.ValidatePolicy(policy: PartialPolicy): (boolean, string?)
FSM.SetTracer(fn: ((TraceEvent) -> ())?): ()
```

## FSM methods

```luau
fsm:Context(): Context.Context<Ctx>
fsm:Mode(name: string, builder: ((mode: FSM.Mode<Ctx>) -> ())?): FSM.Mode<Ctx>
fsm:HasMode(name: string): boolean
fsm:GetMode(name: string): FSM.Mode<Ctx>?
fsm:Start(name: string): ()
fsm:Switch(name: string, opts: SwitchOptions?): ()
fsm:CanSwitch(name: string): boolean
fsm:Current(): string
fsm:IsActive(name: string): boolean
fsm:InMode(name: string): boolean
fsm:Path(): { string }
fsm:History(parentName: string): string?
fsm:SwitchToHistory(parentName: string, opts: SwitchOptions?): ()
fsm:ClearHistory(parentName: string?): ()
fsm:Snapshot(opts: SnapshotOptions?): Snapshot
fsm:Restore(snapshot: Snapshot, opts: SwitchOptions?): ()
fsm:OnTransition(fn: (event: TransitionEvent) -> ()): Connection.Connection
fsm:WaitForTransition(): TransitionEvent
fsm:Policy(opts: PartialPolicy): FSM.FSM<Ctx>
fsm:IsStarted(): boolean
fsm:IsDestroyed(): boolean
fsm:Destroy(): ()
fsm:IsActiveStore(name: string): Store.ReadableStore<boolean>
```

## FSM properties

```luau
fsm.ActiveStore: Store.ReadableStore<string>
fsm.TransitionSignal: Signal.Signal<TransitionEvent>
```

## Mode methods

```luau
mode:Name(): string
mode:Parent(): FSM.Mode<Ctx>?
mode:OnEnter(fn: (ctx: Context.Context<Ctx>, frame: TransitionFrame) -> any): FSM.Mode<Ctx>
mode:OnExit(fn: (ctx: Context.Context<Ctx>, frame: TransitionFrame) -> any): FSM.Mode<Ctx>
mode:OnUpdate(fn: (ctx: Context.Context<Ctx>, dt: number, frame: UpdateFrame) -> ()): FSM.Mode<Ctx>
mode:Add(resource: any): FSM.Mode<Ctx>
mode:Provide(providerOrValues: any): FSM.Mode<Ctx>
mode:Guard(to: string, guard: Guard<Ctx>, opts: GuardOptions?): FSM.Mode<Ctx>
mode:TaskGroup(): Task.TaskGroup
mode:Tag(label: string): FSM.Mode<Ctx>
mode:IsActive(): boolean
mode:IsDestroyed(): boolean
mode:Destroy(): ()
```

## Not implemented

Do not implement:

```luau
FSM.SetScheduler
FSM.Region
```

Use `Scheduler.SetDriver`.

Regions are excluded from this rewrite because the previous semantics were incomplete.

## Policy

```luau
{
    SingleSwitchPerFrame: boolean?,
    CancelTasksOnExit: boolean?,
    ExitOrdering: "LeafFirst" | "ParentFirst"?,
    Deferral: "Queue" | "Drop"?,
    ErrorPolicy: "Throw" | "Warn" | "Swallow" | "Collect"?,
    Trace: boolean?,
    Tag: string?,
}
```

Defaults:

```luau
SingleSwitchPerFrame = true
CancelTasksOnExit = true
ExitOrdering = "LeafFirst"
Deferral = "Queue"
Trace = false
```

Policy validation:

- unknown keys error
- enum strings exact
- booleans are booleans
- Tag string/nil
- ErrorPolicy valid if supplied

Policy cannot change after Start.

Error:

```text
FSM.Policy: cannot change policy after start
```

## Context

`FSM.New` accepts Context or plain record.

If plain record, wrap with `Context.Root`.

FSM stores a Context handle, not raw record.

Callbacks receive context plus frame.

Mode providers create mode-local context layers per activation.

## Events and frames

Transition event:

```luau
{
    From: string,
    To: string,
    Reason: string?,
    Data: unknown?,
}
```

Transition frame:

```luau
{
    From: string,
    To: string,
    Reason: string?,
    Data: unknown?,
    StartedAt: number,
    Immediate: boolean,
}
```

Update frame:

```luau
{
    Mode: string,
    StartedAt: number,
}
```

Timing uses `Scheduler.Now()`.

## `FSM.New(ctx, opts?)`

### Validation

- ctx table or Context
- opts table/nil and valid policy fields

### Behavior

- create FSM record
- wrap plain ctx with Context.Root
- create writable internal active store initialized `""`
- expose readonly ActiveStore
- create TransitionSignal
- policy = defaults merged with opts
- no modes
- not started
- not destroyed

## `FSM.IsFSM(value)` / `FSM.IsMode(value)`

Return true for handles created by this module.

Destroyed handles still return true.

## `FSM.DefaultPolicy()`

Return clone of default policy.

## `FSM.ValidatePolicy(policy)`

Return `(true, nil)` or `(false, message)`.

## `FSM.SetTracer(fn?)`

Install global tracer.

Tracer errors route through ErrorHandler phase `"Trace"`.

## `fsm:Context()`

Returns FSM context.

Destroyed FSM errors:

```text
FSM.Context: FSM is destroyed
```

## `fsm:Mode(name, builder?)`

Gets existing mode or creates new.

### Validation

- FSM live
- name non-empty string
- builder function/nil

### Behavior

- Existing mode returned.
- If builder supplied, call builder with mode.
- New mode registered by name.
- Builder errors throw directly as construction errors, not ErrorHandler runtime errors.

## `fsm:HasMode(name)`

Returns whether registered mode exists.

Validates name non-empty string.

## `fsm:GetMode(name)`

Returns mode or nil.

Does not create.

## Parent hierarchy

Explicit parent via `parent:Add(childMode)`.

Dot-name inference only if no explicit parent exists.

Prevent cycles.

Reject re-parenting.

Child must belong to same FSM.

## `fsm:Start(name)`

### Validation

- FSM live
- not already started
- target exists
- validates all guards target existing modes
- validates parent graph no cycles

Errors:

```text
FSM.Start: FSM is destroyed
FSM.Start: already started
FSM.Start: mode '<name>' not registered
```

### Behavior order

1. mark started
2. compute path to target
3. set active path
4. set ActiveStore
5. update IsActiveStore caches
6. create frame `{ From = "", To = name, Reason = "Start", StartedAt = Scheduler.Now(), Immediate = true }`
7. enter modes parent-to-leaf
8. fire TransitionSignal with event
9. trace FSM.Start

If enter callback switches, normal scheduling applies.

## `fsm:Switch(name, opts?)`

### Validation

- FSM live
- started
- target exists
- opts table/nil
- opts fields valid

Errors:

```text
FSM.Switch: FSM is destroyed
FSM.Switch: FSM has not started
FSM.Switch: mode '<name>' not registered
```

Options:

```luau
{
    Immediate: boolean?,
    Reason: string?,
    Data: unknown?,
}
```

### No-op

If target is current, no-op and no transition event.

### Scheduling

- Immediate bypasses frame coalescing but still respects transition reentrancy.
- If currently transitioning:
  - Deferral Drop: drop request
  - Deferral Queue: enqueue request
- If not transitioning and Immediate: execute transition now.
- If not transitioning, not Immediate, SingleSwitchPerFrame true: store latest pending request and schedule one Scheduler.Defer.
- If not transitioning, not Immediate, SingleSwitchPerFrame false: schedule each request through Scheduler.Defer.

Immediate switch while transitioning never recursively executes transition. It is queued or dropped.

## Transition execution

1. mark transitioning
2. compute from path and to path
3. find lowest common ancestor
4. create frame
5. exit modes below LCA using ExitOrdering
6. update history
7. set active path
8. set ActiveStore
9. update IsActiveStore caches
10. enter modes below LCA parent-to-leaf
11. fire TransitionSignal
12. mark not transitioning
13. drain queued transitions

## Exit behavior per mode

Order:

1. disconnect update connection
2. disconnect guard watchers
3. run OnExit callbacks
4. run active disposers
5. disable attached rules
6. cancel task group if CancelTasksOnExit
7. destroy mode context layer for this activation

OnExit return handling:

- function return is called immediately as disposer through ErrorHandler
- Task return is ignored and reported through ErrorHandler phase `"ExitTaskIgnored"`
- nil ignored
- other values ignored

Async OnExit tasks are not supported.

## Enter behavior per mode

Order:

1. create mode context layer from providers
2. run OnEnter callbacks
3. collect disposer returns
4. add Task returns to task group
5. enable attached rules with mode context
6. connect update callbacks if any
7. activate guards
8. evaluate immediate guards by priority

OnEnter errors route through ErrorHandler.

If ErrorPolicy not Throw, continue entering.

## `mode:Provide(providerOrValues)`

Mode-local context provider.

Accepted:

```luau
mode:Provide({ Key = value })
```

or:

```luau
mode:Provide(function(ctx, frame)
    return values, cleanup
end)
```

### Behavior

- providers run each time mode enters
- returned values create context layer for that activation
- cleanup runs on exit
- provider errors route through ErrorHandler phase `"Provide"`
- if policy not Throw, mode continues entering without that provider

## `mode:Add(resource)`

Accepts only:

- Rule
- Task
- Mode
- function factory

Invalid resource errors:

```text
Mode.Add: expected Rule, Task, Mode, or function
```

### Rule

- stored
- enabled on enter with mode context
- disabled on exit
- if mode active, enable immediately

Duplicate rules error.

### Task

- added to mode task group immediately
- cancelled on exit if CancelTasksOnExit

### Mode

- set explicit parent
- child must belong same FSM
- reject cycles
- reject re-parenting

### Function factory

- runs on enter with `(ctx, frame)`
- if mode active, run immediately
- function return may be disposer or Task
- errors route through ErrorHandler phase `"Factory"`

## `mode:Guard(to, guard, opts?)`

Guard types:

- `Store.ReadableStore<boolean>`
- function `(ctx, frame) -> boolean`

Options:

```luau
{
    Priority: number?,
    Reason: string?,
    Defer: boolean?,
    Data: unknown?,
}
```

Behavior:

- target must exist by Start validation
- guard passes only exactly true
- store guard watches Changed and triggers when `New == true`
- function guard evaluated on enter only
- immediate true guards sorted by Priority descending, stable by insertion index
- Defer true schedules Switch through Scheduler.Defer

## `mode:OnEnter(fn)`

Registers enter callback.

Validation fn function.

May be called before or after start. If mode already active, callback does not run until future enter.

Return handling:
- function -> active disposer
- Task -> add to task group
- other -> ignored

## `mode:OnExit(fn)`

Registers exit callback.

Same validation.

Async Task returns ignored/reported as above.

## `mode:OnUpdate(fn)`

Registers update callback.

When mode active, update callbacks run through `Scheduler.OnStep`.

Signature:

```luau
(ctx, dt, frame)
```

Errors route ErrorHandler phase `"Update"`.

If no update driver, entering mode with update callbacks reports:

```text
FSM.OnUpdate: no update driver available
```

## `mode:TaskGroup()`

Returns mode task group.

## `mode:Tag(label)`

Sets display label.

Does not affect registry name or transition target.

## `mode:IsActive()`

Returns owning FSM `IsActive(mode registry name)`.

## `mode:Destroy()`

Destroys mode if inactive.

If active, error:

```text
Mode.Destroy: cannot destroy active mode
```

Behavior:
- remove from registry
- destroy/disable rules
- cancel task group
- clear callbacks/guards/providers
- mark destroyed

## Active stores

`fsm.ActiveStore` and `fsm:IsActiveStore(name)` return readonly Store views.

Consumers cannot Set/Update them.

Internal writable stores remain private.

## `fsm:Snapshot(opts?)`

Snapshot includes:

- active path
- history map

Does not include context values, provider values, tasks, rules, metrics, queues.

## `fsm:Restore(snapshot, opts?)`

Requires started FSM.

Switches to snapshot leaf.

Merge opts with:

```luau
Reason = "Restore"
Data = snapshot
```

## `fsm:WaitForTransition()`

Uses `TransitionSignal:Wait()`.

If FSM destroyed while waiting, raises:

```text
FSM.WaitForTransition: FSM destroyed
```

## `fsm:Destroy()`

Behavior:

1. if already destroyed, return
2. mark disposing, not destroyed
3. exit active modes while active path remains observable
4. clear active path
5. update ActiveStore and IsActiveStore caches
6. dispose rules/modes
7. destroy TransitionSignal
8. destroy internal ActiveStore and IsActiveStore stores
9. mark destroyed

Do not mark destroyed before exit callbacks.

## `fsm:CanSwitch(name)`

Returns true if:

- FSM live
- started
- target exists
- target not current

Does not evaluate guards.

## `fsm:SwitchToHistory(parentName, opts?)`

Switches to last recorded child for parent.

If no history exists, no-op.

Requires started/live.

## `fsm:ClearHistory(parentName?)`

If parentName supplied, clear that entry.

If nil, clear entire history.

## `fsm:OnTransition(fn)`

Subscribes to TransitionSignal.

Listener receives full TransitionEvent.

## `fsm:Policy(opts)`

Allowed only before Start.

Validate and merge current policy with opts.

Return fsm.
