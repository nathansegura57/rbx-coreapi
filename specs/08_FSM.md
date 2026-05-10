# 08 — FSM

FSM owns lifecycle scope and active mode path.

## Public API

```luau
FSM.New(ctx: Context.Context<Ctx> | Ctx, opts?): FSM<Ctx>
FSM.IsFSM(value: unknown): boolean
FSM.IsMode(value: unknown): boolean
FSM.DefaultPolicy(): Policy
FSM.ValidatePolicy(policy): (boolean, string?)
FSM.SetTracer(fn?): ()
FSM.SetScheduler(driver): ()
```

FSM methods:

```luau
fsm:Context(): Ctx
fsm:Mode(name: string, builder: ((mode: Mode<Ctx>) -> ())?): Mode<Ctx>
fsm:HasMode(name: string): boolean
fsm:GetMode(name: string): Mode<Ctx>?
fsm:Region(name: string, builder): Mode<Ctx> -- only if fully implemented
fsm:Start(name: string): ()
fsm:Switch(name: string, opts?): ()
fsm:CanSwitch(name: string): boolean
fsm:Current(): string
fsm:IsActive(name: string): boolean
fsm:InMode(name: string): boolean
fsm:Path(): { string }
fsm:History(parentName: string): string?
fsm:SwitchToHistory(parentName: string, opts?): ()
fsm:ClearHistory(parentName: string?): ()
fsm:Snapshot(opts?): Snapshot
fsm:Restore(snapshot, opts?): ()
fsm:OnTransition(fn): Connection
fsm:WaitForTransition(): TransitionEvent
fsm:Policy(opts): FSM<Ctx>
fsm:IsStarted(): boolean
fsm:IsDestroyed(): boolean
fsm:Destroy(): ()
fsm:IsActiveStore(name: string): Store.Readable<boolean>
```

Properties:

```luau
fsm.ActiveStore: Store.Readable<string>
fsm.TransitionSignal: Signal<TransitionEvent>
```

Mode methods:

```luau
mode:Name(): string
mode:Parent(): Mode<Ctx>?
mode:OnEnter(fn): Mode<Ctx>
mode:OnExit(fn): Mode<Ctx>
mode:OnUpdate(fn): Mode<Ctx>
mode:Add(resource): Mode<Ctx>
mode:Provide(providerOrValues): Mode<Ctx>
mode:Guard(to: string, guard, opts?): Mode<Ctx>
mode:TaskGroup(): Task.TaskGroup
mode:Tag(label: string): Mode<Ctx>
mode:IsActive(): boolean
mode:IsDestroyed(): boolean
mode:Destroy(): ()
```

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

Validate all fields. Unknown keys error.

Policy cannot change after Start. If you need live policy mutation later, it must be explicit and defined. For now: reject after start.

## Context

FSM accepts a Context or plain record.

If plain record is provided, wrap with `Context.Root`.

FSM callbacks receive context view plus frame.

Mode providers create mode-local context layers.

## Transition event

```luau
{
    From: string,
    To: string,
    Reason: string?,
    Data: unknown?,
}
```

Transition frame extends event:

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

## `Mode`

Gets existing mode or creates new.

- Duplicate name returns existing mode.
- Builder called with mode.
- Mode names must be non-empty strings.
- Builder errors route through ErrorHandler or throw based policy. Since construction is user API, prefer throw.

## `HasMode` / `GetMode`

Lookup without creating.

## Parent hierarchy

Support explicit parent via `parent:Add(childMode)`.

Support dot-name inference only if no explicit parent exists.

Prevent parent cycles.

Reject re-parenting unless explicit policy added. Preferred: error.

## `Start`

Requires:

- not destroyed
- not already started
- target mode exists

Behavior:

1. mark started
2. compute path to target
3. set active path
4. set ActiveStore
5. update IsActiveStore caches
6. enter modes parent-to-leaf
7. fire TransitionSignal with From="", To=target, Reason="Start"
8. emit trace

If enter callback switches, transition scheduling applies normally.

## `Switch`

Requires FSM started. Pre-start switch errors.

Options:

```luau
{
    Immediate: boolean?,
    Reason: string?,
    Data: unknown?,
}
```

If target missing, error. Do not warn and continue.

If target is current, no-op unless Data/Reason should still emit; preferred no-op.

Scheduling:

- Immediate still respects transition reentrancy. It may bypass frame coalescing but must not recursively corrupt active path.
- If transitioning:
  - Deferral Drop: drop
  - Deferral Queue: queue
- If not transitioning:
  - SingleSwitchPerFrame true: coalesce deferred requests to latest
  - false: schedule each request

Use Scheduler.Defer.

## Transition execution

1. compute from path and to path
2. find lowest common ancestor
3. exit modes below LCA using ExitOrdering
4. update history
5. set active path
6. set ActiveStore
7. update IsActiveStore caches
8. enter modes below LCA parent-to-leaf
9. fire TransitionSignal
10. drain queued transitions

## Exit behavior

For each exited mode:

1. disconnect update connection
2. disconnect guard watchers
3. run OnExit callbacks
4. run active disposers
5. disable attached rules
6. cancel task group if CancelTasksOnExit
7. destroy mode context layer for this activation

Define exit task behavior clearly. Preferred: tasks returned by OnExit are not added to the same mode task group that is immediately cancelled. Either reject async OnExit task returns or run them as fire-and-forget through ErrorHandler. Simpler: OnExit return values are treated like disposers only; Task returns are ignored with ErrorHandler warning.

## Enter behavior

For each entered mode:

1. create mode context layer from providers
2. run OnEnter callbacks
3. collect disposer returns
4. add Task returns to task group
5. enable attached rules with mode context
6. connect update callbacks if any
7. activate guards
8. evaluate immediate guards by priority

OnEnter errors route through ErrorHandler.

## `Provide`

Mode-local context.

Accepted:

```luau
mode:Provide({
    Key = value,
})
```

or:

```luau
mode:Provide(function(ctx, frame)
    return values, cleanup
end)
```

Behavior:

- provider runs each time mode enters
- returned values create a context layer for that activation
- cleanup runs on exit
- provider errors route through ErrorHandler and mode still continues unless policy throws

## `Add`

Accepts only:

- Rule
- Task
- Mode
- function factory

Invalid resource errors.

Rule:

- stored
- enabled on enter
- disabled on exit
- if mode active, enable immediately

Task:

- added to mode task group immediately
- if mode exits and CancelTasksOnExit, task cancelled

Mode:

- sets explicit parent
- child must belong to same FSM
- reject cycles/re-parenting

Function factory:

- runs on enter with `(ctx, frame)`
- if mode active, run immediately
- function return may be disposer or Task
- errors route through ErrorHandler

## `Guard`

Guard types:

- Store.Readable<boolean>
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
- store guard watches Changed and triggers when New == true
- function guard evaluated on enter only
- immediate true guards sorted by Priority descending
- tie order should be stable by insertion index
- Defer true schedules switch through Scheduler.Defer

## `OnUpdate`

Callbacks run while mode active.

Do not directly call RunService from FSM if avoidable. Use Scheduler/update driver if available. If no update driver exists in kernel, keep OnUpdate implemented with a driver passed through Scheduler or FSM.SetScheduler.

Callback signature:

```luau
(ctx, dt, frame)
```

Errors route through ErrorHandler.

## `Destroy`

Behavior:

1. if already destroyed, no-op
2. mark disposing, not destroyed
3. exit active modes while active path still observable
4. clear active path
5. update ActiveStore and caches
6. dispose rules/modes/regions
7. destroy TransitionSignal
8. destroy ActiveStore and IsActiveStore caches or document final-live behavior. Preferred: destroy them.
9. mark destroyed

Do not mark destroyed before exit callbacks.

## Active stores

`ActiveStore` and `IsActiveStore` must be read-only Store views.

Consumers cannot Set/Update them.

## Region

Only implement Region if it has real lifecycle behavior.

Minimum acceptable region semantics:

- entering synthetic region mode starts/resumes sub-FSM
- exiting synthetic region mode destroys or suspends sub-FSM according to documented policy
- parent Destroy destroys region FSM

If not implementing that, omit Region from public API for now.
