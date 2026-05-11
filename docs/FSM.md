# FSM

## Purpose

`FSM` manages a hierarchical state machine. It owns lifecycle scope, mode transitions, mode-local context, attached rules and tasks, guard evaluation, update callbacks, active stores, transition events, history, snapshots, and destruction.

## Import

```luau
local FSM = require(path.to.FSM)
```

## Public API reference

```luau
FSM.New<Ctx>(ctx: Context.Context<Ctx> | Ctx, opts: PartialPolicy?): FSM.FSM<Ctx>
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
fsm.ActiveStore: Store.ReadableStore<string>
fsm.TransitionSignal: Signal.Signal<TransitionEvent>
```

## Mode methods

```luau
mode:Name(): string
mode:Parent(): FSM.Mode<Ctx>?
mode:OnEnter(fn): FSM.Mode<Ctx>
mode:OnExit(fn): FSM.Mode<Ctx>
mode:OnUpdate(fn): FSM.Mode<Ctx>
mode:Add(resource: any): FSM.Mode<Ctx>
mode:Provide(providerOrValues: any): FSM.Mode<Ctx>
mode:Guard(to: string, guard: any, opts: GuardOptions?): FSM.Mode<Ctx>
mode:TaskGroup(): Task.TaskGroup
mode:Tag(label: string): FSM.Mode<Ctx>
mode:IsActive(): boolean
mode:IsDestroyed(): boolean
mode:Destroy(): ()
```

## Types

```luau
export type TransitionEvent = {
    From: string,
    To: string,
    Reason: string?,
    Data: unknown?,
}

export type TransitionFrame = {
    From: string,
    To: string,
    Reason: string?,
    Data: unknown?,
    StartedAt: number,
    Immediate: boolean,
}

export type UpdateFrame = {
    Mode: string,
    StartedAt: number,
}

export type SwitchOptions = {
    Immediate: boolean?,
    Reason: string?,
    Data: unknown?,
}

export type Snapshot = {
    ActivePath: { string },
    History: { [string]: string },
}

export type GuardOptions = {
    Priority: number?,
    Reason: string?,
    Defer: boolean?,
    Data: unknown?,
}

export type Policy = {
    SingleSwitchPerFrame: boolean,
    CancelTasksOnExit: boolean,
    ExitOrdering: "LeafFirst" | "ParentFirst",
    Deferral: "Queue" | "Drop",
    ErrorPolicy: string?,
    Trace: boolean,
    Tag: string?,
}
```

## `FSM.New(ctx, opts?)`

Creates a new FSM.

**Parameters**

- `ctx` — a plain table (wrapped with `Context.Root`) or an existing `Context`.
- `opts` — optional partial policy.

**Behavior**

- Creates an internal writable `ActiveStore` initialized to `""`.
- Exposes a read-only `ActiveStore` on the FSM handle.
- Creates `TransitionSignal`.

## Policy defaults

| Field | Default |
|---|---|
| `SingleSwitchPerFrame` | `true` |
| `CancelTasksOnExit` | `true` |
| `ExitOrdering` | `"LeafFirst"` |
| `Deferral` | `"Queue"` |
| `Trace` | `false` |

## `FSM.IsFSM(value)` / `FSM.IsMode(value)`

Return `true` for handles created by this module, including destroyed ones.

## `FSM.SetTracer(fn?)`

Installs a global tracer. Tracer errors route through `ErrorHandler` phase `"Trace"`.

## `fsm:Context()`

Returns the FSM's context handle.

**Error behavior**

```text
FSM.Context: FSM is destroyed
```

## `fsm:Mode(name, builder?)`

Gets or creates a mode by name. If a builder is supplied, calls it with the mode handle.

Builder errors throw directly as construction errors, not through `ErrorHandler`.

**Error behavior**

```text
FSM.Mode: FSM is destroyed
FSM.Mode: name must be a non-empty string
```

## `fsm:HasMode(name)` / `fsm:GetMode(name)`

Check or retrieve a registered mode by name.

## `fsm:Start(name)`

Starts the FSM in the named mode.

**Error behavior**

```text
FSM.Start: FSM is destroyed
FSM.Start: already started
FSM.Start: mode '<name>' not registered
```

**Behavior** (in order)

1. Mark started.
2. Compute path to `name`.
3. Set active path and `ActiveStore`.
4. Update `IsActiveStore` caches.
5. Create frame `{ From = "", To = name, Reason = "Start", StartedAt = now, Immediate = true }`.
6. Enter modes from root to leaf.
7. Fire `TransitionSignal`.
8. Emit trace `FSM.Start`.

## `fsm:Switch(name, opts?)`

Requests a transition to `name`.

**Options**

```luau
{ Immediate: boolean?, Reason: string?, Data: unknown? }
```

**Error behavior**

```text
FSM.Switch: FSM is destroyed
FSM.Switch: FSM has not started
FSM.Switch: mode '<name>' not registered
```

**Behavior**

- No-op if `name` is already current.
- If transitioning: `Deferral = "Queue"` enqueues; `Deferral = "Drop"` discards.
- `Immediate = true` and not transitioning: executes the transition synchronously.
- Not immediate, `SingleSwitchPerFrame = true`: stores the latest pending request; schedules one `Scheduler.Defer`.
- Not immediate, `SingleSwitchPerFrame = false`: schedules a `Scheduler.Defer` per call.

## Transition execution (in order)

1. Mark transitioning.
2. Compute from-path and to-path.
3. Find lowest common ancestor.
4. Create transition frame.
5. Exit modes below LCA per `ExitOrdering`.
6. Update history.
7. Set active path and `ActiveStore`.
8. Update `IsActiveStore` caches.
9. Enter modes below LCA (parent → leaf).
10. Fire `TransitionSignal`.
11. Mark not transitioning.
12. Drain queued transitions.

## Exit behavior per mode (in order)

1. Disconnect update connections.
2. Disconnect guard watchers.
3. Run `OnExit` callbacks.
   - Function return → called immediately as disposer through `ErrorHandler`.
   - Task return → reported through `ErrorHandler` phase `"ExitTaskIgnored"`.
4. Run active disposers.
5. Disable attached rules.
6. Cancel task group if `CancelTasksOnExit`.
7. Destroy mode context layer.

## Enter behavior per mode (in order)

1. Create mode context layer from providers.
2. Run `OnEnter` callbacks.
3. Collect function returns as disposers.
4. Add Task returns to the mode task group.
5. Enable attached rules with mode context.
6. Connect update callbacks via `Scheduler.OnStep`.
7. Activate store guards (subscribe for future `true` values).
8. Evaluate function guards by priority (descending), stable by insertion order. First passing guard triggers switch.

## `fsm:CanSwitch(name)`

Returns `true` if started, live, `name` exists, and `name` is not current. Does not evaluate guards.

## `fsm:Current()`

Returns the leaf of the active path (current mode name), or `""` if not started.

## `fsm:IsActive(name)`

Returns `true` if `name` appears anywhere in the active path.

## `fsm:InMode(name)`

Returns `true` if the current leaf mode is exactly `name`.

## `fsm:Path()`

Returns a clone of the full active path (root → leaf).

## `fsm:History(parentName)`

Returns the last child mode that was active under `parentName`, or `nil`.

## `fsm:SwitchToHistory(parentName, opts?)`

Switches to the recorded history child for `parentName`. No-op if no history.

## `fsm:ClearHistory(parentName?)`

Clears history for `parentName`, or entire history if `nil`.

## `fsm.ActiveStore`

Read-only `Store.ReadableStore<string>` reflecting the current mode name. Consumers cannot `Set` or `Update` it.

## `fsm:IsActiveStore(name)`

Returns a read-only `Store.ReadableStore<boolean>` that is `true` when `name` is in the active path. Stores are lazily created and cached per name.

## `fsm:Snapshot(opts?)`

Returns `{ ActivePath = clone, History = clone }`. Does not capture context values, provider state, tasks, rules, or metrics.

## `fsm:Restore(snapshot, opts?)`

Restores history from the snapshot, then switches to the snapshot's leaf mode with `Reason = "Restore"` and `Data = snapshot`.

## `fsm:OnTransition(fn)`

Subscribes to `TransitionSignal`. Returns a `Connection`.

## `fsm:WaitForTransition()`

Yields until the next transition. Returns a `TransitionEvent`.

If the FSM is destroyed while waiting, errors:

```text
FSM.WaitForTransition: FSM destroyed
```

## `fsm:Policy(opts)`

Validates and merges `opts` into the current policy. Cannot be called after `Start`.

**Error behavior**

```text
FSM.Policy: cannot change policy after start
```

## `fsm:Destroy()`

Destroys the FSM.

**Behavior** (in order)

1. No-op if already destroyed.
2. Mark disposing (not yet destroyed, so exit callbacks observe live state).
3. Exit active modes leaf-first.
4. Clear active path.
5. Update `ActiveStore` and `IsActiveStore` caches.
6. Mark all mode records destroyed and cancel their task groups.
7. Destroy `TransitionSignal`.
8. Destroy internal stores.
9. Mark destroyed.

## Mode: `mode:Add(resource)`

Accepts: `Rule`, `Task`, `Mode`, or `function`.

**Rule**

- Enabled on mode enter with mode context; disabled on mode exit.
- If mode is currently active, enabled immediately.
- Duplicate rules error.

**Task**

- Added to mode task group immediately.

**Mode**

- Sets explicit parent. Child must belong to the same FSM.
- Cycles error. Re-parenting errors.

**function**

- Called on enter with `(ctx, frame)`.
- If mode is currently active, called immediately.
- Function return may be a disposer or a Task.

**Error behavior**

```text
Mode.Add: expected Rule, Task, Mode, or function
```

## Mode: `mode:Provide(providerOrValues)`

Registers a context provider for this mode.

**Accepted forms**

```luau
mode:Provide({ Key = value })
```

```luau
mode:Provide(function(ctx, frame)
    return values, cleanup
end)
```

**Behavior**

- Providers run each time the mode enters.
- Their values create the mode-local context layer for that activation.
- Cleanups run when the context layer is destroyed on exit.
- Provider errors route through `ErrorHandler` phase `"Provide"`.

## Mode: `mode:Guard(to, guard, opts?)`

Registers a transition guard.

**Guard types**

- `Store.ReadableStore<boolean>` — watched reactively; switches when value becomes `true`.
- `function(ctx, frame) -> boolean` — evaluated on enter; passes only exactly `true`.

**Options**

```luau
{
    Priority: number?,   -- higher runs first (default 0)
    Reason: string?,
    Defer: boolean?,     -- schedules switch via Scheduler.Defer
    Data: unknown?,
}
```

## Mode: `mode:OnEnter(fn)` / `mode:OnExit(fn)`

Registers lifecycle callbacks.

**OnEnter** return handling: function → disposer; Task → added to task group.

**OnExit** return handling: function → called as disposer; Task → reported through `ErrorHandler` phase `"ExitTaskIgnored"`.

## Mode: `mode:OnUpdate(fn)`

Registers a per-frame callback via `Scheduler.OnStep`.

**Signature:** `(ctx, dt, frame) -> ()`

Errors route through `ErrorHandler` phase `"Update"`.

If no step driver is available: reports an error at enter time.

## Mode: `mode:TaskGroup()`

Returns the mode's task group (lazily created).

## Mode: `mode:Destroy()`

Destroys the mode if it is not active. Errors if active.

**Error behavior**

```text
Mode.Destroy: cannot destroy active mode
```

## Parent hierarchy

Modes may have an explicit parent via `parent:Add(childMode)`.

If no explicit parent exists, parent is inferred from the last dot segment of the mode name if a matching mode exists (e.g. `"A.B"` infers parent `"A"`).

Cycles error. Re-parenting errors.

## Lifecycle behavior

An FSM starts disabled. `Start` is called once. `Policy` may only be changed before `Start`. `Destroy` exits all active modes before marking itself destroyed, ensuring callbacks observe a live FSM.

## Scheduler behavior

Non-immediate switches are scheduled via `Scheduler.Defer`. Guard deferred switches use `Scheduler.Defer`. Update callbacks use `Scheduler.OnStep`. `StartedAt` fields use `Scheduler.Now()`.

## Not implemented

`FSM.SetScheduler` and `FSM.Region` are not implemented. Use `Scheduler.SetDriver` for scheduling overrides. Regions are excluded from this version.
