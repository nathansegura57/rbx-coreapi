# FSM API Reference

`FSM` is the hierarchical finite-state-machine primitive for CoreAPI.

Place this module at:

```text
ReplicatedStorage/Shared/Kernel/FSM
```

`FSM` exists to model:

- application flow;
- gameplay state;
- AI behavior;
- UI navigation;
- interaction modes;
- nested substates;
- guarded transitions;
- lifecycle ownership;
- scoped resources;
- state-local tasks;
- declarative transition orchestration.

It integrates deeply with the rest of the Kernel:

```text
Connection
Context
ErrorHandler
Rule
Scheduler
Signal
Store
Task
```

---

# Design Goals

`FSM` is designed around one central principle:

> state transitions should be declarative infrastructure, not scattered imperative logic.

Instead of manually coordinating:

- enter callbacks;
- exit callbacks;
- cleanup;
- async cancellation;
- dependency scope;
- transition ordering;
- history;
- guards;
- update loops;

an FSM centralizes those behaviors into one deterministic transition system.

---

# Core Mental Model

An FSM owns:

```text
mode hierarchy
    ↓
transition policy
    ↓
state lifecycle
    ↓
scoped ownership
    ↓
reactive observability
```

Modes are not just names.

Each mode owns:

- lifecycle callbacks;
- scoped dependencies;
- task groups;
- cleanup resources;
- transition guards;
- nested hierarchy.

---

# Importing

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FSM = require(ReplicatedStorage.Shared.Kernel.FSM)
```

---

# Relationship to Other Kernel Modules

# Relationship to `Context`

Each mode owns a scoped `Context`.

Dependencies provided inside a mode become active only while that mode is active.

This allows:

- hierarchical dependency injection;
- state-local services;
- scoped cleanup ownership.

---

# Relationship to `Task`

Each mode owns a `Task.TaskGroup`.

Tasks started within a mode can automatically cancel on exit.

---

# Relationship to `Rule`

Rules naturally compose with FSM transitions.

Common patterns include:

- guarded transitions;
- cooldown transitions;
- async transition orchestration;
- serialized actions.

---

# Relationship to `Signal`

FSM exposes lifecycle signals:

- transitions;
- active mode changes;
- updates.

These integrate naturally with reactive systems.

---

# Relationship to `Store`

FSM exposes reactive stores representing:

- active state;
- mode activity;
- transition state.

---

# Relationship to `ErrorHandler`

Lifecycle callback failures route through `ErrorHandler`.

This includes:

- enter callbacks;
- exit callbacks;
- update callbacks;
- guard callbacks;
- tracer callbacks.

Usage errors still raise immediately.

---

# Exported Types

# `FSM.FSM<ContextValue>`

```luau
type FSM<ContextValue> = opaque
```

Primary finite-state-machine handle.

Owns:

- mode graph;
- transition policy;
- active path;
- lifecycle;
- scoped resources;
- guards;
- history;
- tracing;
- destruction.

---

# `FSM.Mode<ContextValue>`

```luau
type Mode<ContextValue> = opaque
```

Represents one state node.

Modes may be:

- root modes;
- nested child modes;
- active;
- inactive;
- destroyed.

---

# `FSM.Policy`

```luau
type Policy = {
    SingleSwitchPerFrame: boolean,
    CancelTasksOnExit: boolean,
    ExitOrdering: FSM.ExitOrdering,
    Deferral: FSM.Deferral,
    ErrorPolicy: string?,
    Trace: boolean,
    Tag: string?,
}
```

Defines transition behavior.

---

# `FSM.PartialPolicy`

```luau
type PartialPolicy = {
    SingleSwitchPerFrame: boolean?,
    CancelTasksOnExit: boolean?,
    ExitOrdering: FSM.ExitOrdering?,
    Deferral: FSM.Deferral?,
    ErrorPolicy: string?,
    Trace: boolean?,
    Tag: string?,
}
```

Used for partial updates.

---

# `FSM.ExitOrdering`

```luau
FSM.ExitOrdering.LeafFirst
FSM.ExitOrdering.ParentFirst
```

Controls hierarchical exit ordering.

---

# `FSM.Deferral`

```luau
FSM.Deferral.Queue
FSM.Deferral.Drop
```

Controls transition deferral semantics.

---

# `FSM.SwitchOptions`

```luau
type SwitchOptions = {
    Immediate: boolean?,
    Reason: string?,
    Data: unknown?,
}
```

Transition options.

---

# `FSM.Snapshot`

```luau
type Snapshot = {
    ActivePath: { string },
    History: { [string]: string },
}
```

Serializable FSM snapshot.

---

# `FSM.TransitionFrame`

```luau
type TransitionFrame = {
    From: string,
    To: string,
    Reason: string?,
    Data: unknown?,
    StartedAt: number,
    Immediate: boolean,
}
```

Represents one active transition execution.

---

# `FSM.TransitionEvent`

```luau
type TransitionEvent = {
    From: string,
    To: string,
    Reason: string?,
    Data: unknown?,
}
```

Transition signal payload.

---

# `FSM.TraceEvent`

```luau
type TraceEvent = {
    Event: string,
    Tag: string?,
    From: string?,
    To: string?,
}
```

Tracing payload.

---

# `FSM.GuardOptions`

```luau
type GuardOptions = {
    Priority: number?,
    Reason: string?,
    Data: unknown?,
    Defer: boolean?,
}
```

Guard configuration.

---

# `FSM.UpdateFrame`

```luau
type UpdateFrame = {
    Mode: string,
    StartedAt: number,
}
```

Per-update lifecycle payload.

---

# Public Constants

# `FSM.ExitOrdering`

Controls hierarchical exit ordering.

| Value | Meaning |
|---|---|
| `LeafFirst` | Exit deepest active child first. |
| `ParentFirst` | Exit parent before children. |

---

# `FSM.Deferral`

Controls transition conflict behavior.

| Value | Meaning |
|---|---|
| `Queue` | Queue transition requests. |
| `Drop` | Ignore conflicting transition requests. |

---

# Constructors

# `FSM.New`

```luau
FSM.New<ContextValue>(
    contextOrValues: ContextValue,
    policyOverrides: FSM.PartialPolicy?
): FSM.FSM<ContextValue>
```

Creates a new finite-state-machine.

## Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `contextOrValues` | `ContextValue` | Yes | Root context values. |
| `policyOverrides` | `FSM.PartialPolicy?` | No | Optional policy overrides. |

## Returns

| Type | Description |
|---|---|
| `FSM.FSM<ContextValue>` | New FSM instance. |

## Example

```luau
local machine = FSM.New({
    Player = player,
})
```

---

# `FSM.IsFSM`

```luau
FSM.IsFSM(value: unknown): boolean
```

Returns whether a value is a live FSM handle.

---

# `FSM.IsMode`

```luau
FSM.IsMode(value: unknown): boolean
```

Returns whether a value is a live mode handle.

---

# `FSM.DefaultPolicy`

```luau
FSM.DefaultPolicy(): FSM.Policy
```

Returns a fresh default policy snapshot.

## Default Values

```luau
{
    SingleSwitchPerFrame = true,
    CancelTasksOnExit = true,
    ExitOrdering = FSM.ExitOrdering.LeafFirst,
    Deferral = FSM.Deferral.Queue,
    ErrorPolicy = nil,
    Trace = false,
    Tag = nil,
}
```

---

# `FSM.ValidatePolicy`

```luau
FSM.ValidatePolicy(
    policy: FSM.PartialPolicy
): (boolean, string?)
```

Validates policy structure.

Returns:

```luau
(valid, message)
```

---

# `FSM.SetTracer`

```luau
FSM.SetTracer(
    tracer: ((FSM.TraceEvent) -> ())?
): ()
```

Sets the global tracing callback.

Passing `nil` disables tracing.

Tracer failures route through `ErrorHandler`.

---

# Mode Construction

# `fsm:Mode`

```luau
fsm:Mode(
    name: string,
    builder: ((FSM.Mode<ContextValue>) -> ())?
): FSM.Mode<ContextValue>
```

Creates or retrieves a mode.

## Parameters

| Parameter | Type | Required | Description |
|---|---:|---:|---|
| `name` | `string` | Yes | Mode name. |
| `builder` | `((Mode) -> ())?` | No | Declarative mode builder. |

## Example

```luau
fsm:Mode("Idle", function(mode)
    mode:OnEnter(function(context)
        print("entered idle")
    end)
end)
```

---

# `fsm:HasMode`

```luau
fsm:HasMode(name: string): boolean
```

Returns whether the mode exists.

---

# `fsm:GetMode`

```luau
fsm:GetMode(name: string): FSM.Mode<ContextValue>?
```

Returns a mode by name.

---

# Mode APIs

# `mode:Name`

```luau
mode:Name(): string
```

Returns the mode name.

---

# `mode:Parent`

```luau
mode:Parent(): FSM.Mode<ContextValue>?
```

Returns the parent mode.

---

# `mode:OnEnter`

```luau
mode:OnEnter(
    callback: (
        Context.Context<any>,
        FSM.TransitionFrame
    ) -> unknown
): FSM.Mode<ContextValue>
```

Registers enter callback.

## Runtime Error Behavior

Callback failures route through `ErrorHandler`.

---

# `mode:OnExit`

```luau
mode:OnExit(
    callback: (
        Context.Context<any>,
        FSM.TransitionFrame
    ) -> unknown
): FSM.Mode<ContextValue>
```

Registers exit callback.

---

# `mode:OnUpdate`

```luau
mode:OnUpdate(
    callback: (
        Context.Context<any>,
        number,
        FSM.UpdateFrame
    ) -> ()
): FSM.Mode<ContextValue>
```

Registers update callback.

Update callbacks typically run from heartbeat/update integration.

---

# `mode:Add`

```luau
mode:Add(resource: unknown): FSM.Mode<ContextValue>
```

Adds cleanup-owned resource.

Resources are destroyed/disconnected on mode exit.

---

# `mode:Provide`

```luau
mode:Provide(
    providerOrValues: unknown
): FSM.Mode<ContextValue>
```

Adds scoped context values/providers.

---

# `mode:Guard`

```luau
mode:Guard(
    to: string,
    guard: Store.ReadableStore<boolean>
        | ((Context.Context<any>, FSM.TransitionFrame) -> boolean),
    options: FSM.GuardOptions?
): FSM.Mode<ContextValue>
```

Adds transition guard.

## Guard Semantics

Guards may be:

- reactive stores;
- callback predicates.

False guards block transitions.

Guard failures route through `ErrorHandler`.

---

# `mode:TaskGroup`

```luau
mode:TaskGroup(): Task.TaskGroup
```

Returns the mode-owned task group.

---

# `mode:Tag`

```luau
mode:Tag(label: string): FSM.Mode<ContextValue>
```

Attaches metadata label.

---

# `mode:IsActive`

```luau
mode:IsActive(): boolean
```

Returns whether the mode is active.

---

# `mode:IsDestroyed`

```luau
mode:IsDestroyed(): boolean
```

Returns whether the mode is destroyed.

---

# `mode:Destroy`

```luau
mode:Destroy(): ()
```

Destroys the mode.

Destroying an active mode exits it first.

---

# Transition APIs

# `fsm:Start`

```luau
fsm:Start(name: string): ()
```

Starts the FSM in the specified mode.

May only be called once.

---

# `fsm:Switch`

```luau
fsm:Switch(
    name: string,
    options: FSM.SwitchOptions?
): ()
```

Transitions to another mode.

## Behavior

Transitions:

1. validate guards;
2. compute exit path;
3. execute exits;
4. execute enters;
5. update active path;
6. fire transition signals.

---

# `fsm:CanSwitch`

```luau
fsm:CanSwitch(name: string): boolean
```

Returns whether transition is currently allowed.

---

# `fsm:Current`

```luau
fsm:Current(): string
```

Returns current active leaf mode.

---

# `fsm:IsActive`

```luau
fsm:IsActive(name: string): boolean
```

Returns whether a mode is currently active.

---

# `fsm:InMode`

```luau
fsm:InMode(name: string): boolean
```

Alias for `IsActive`.

---

# `fsm:Path`

```luau
fsm:Path(): { string }
```

Returns current active hierarchical path.

---

# History APIs

# `fsm:History`

```luau
fsm:History(parentName: string): string?
```

Returns remembered child history for parent mode.

---

# `fsm:SwitchToHistory`

```luau
fsm:SwitchToHistory(
    parentName: string,
    options: FSM.SwitchOptions?
): ()
```

Transitions to remembered child history.

---

# `fsm:ClearHistory`

```luau
fsm:ClearHistory(parentName: string?): ()
```

Clears transition history.

---

# Snapshot APIs

# `fsm:Snapshot`

```luau
fsm:Snapshot(options: unknown?): FSM.Snapshot
```

Captures current FSM state.

Includes:

- active path;
- transition history.

---

# `fsm:Restore`

```luau
fsm:Restore(
    snapshot: FSM.Snapshot,
    options: FSM.SwitchOptions?
): ()
```

Restores FSM state from snapshot.

---

# Reactive APIs

# `fsm:OnTransition`

```luau
fsm:OnTransition(
    callback: (FSM.TransitionEvent) -> ()
): Connection.Connection
```

Subscribes to transition events.

---

# `fsm:WaitForTransition`

```luau
fsm:WaitForTransition(): FSM.TransitionEvent
```

Yields until next transition occurs.

---

# `fsm:IsActiveStore`

```luau
fsm:IsActiveStore(
    name: string
): Store.ReadableStore<boolean>
```

Returns reactive activity store for a mode.

---

# `fsm.ActiveStore`

```luau
fsm.ActiveStore
```

Reactive store of current active leaf mode.

---

# `fsm.TransitionSignal`

```luau
fsm.TransitionSignal
```

Reactive transition signal.

---

# Policy APIs

# `fsm:Policy`

```luau
fsm:Policy(
    policy: FSM.PartialPolicy
): FSM.FSM<ContextValue>
```

Applies policy updates.

Returns self for chaining.

---

# Lifecycle APIs

# `fsm:IsStarted`

```luau
fsm:IsStarted(): boolean
```

Returns whether FSM has started.

---

# `fsm:IsDestroyed`

```luau
fsm:IsDestroyed(): boolean
```

Returns whether FSM has been destroyed.

---

# `fsm:Destroy`

```luau
fsm:Destroy(): ()
```

Destroys the FSM.

## Behavior

Destroying an FSM:

1. exits active modes;
2. cancels mode task groups;
3. disconnects signals;
4. destroys contexts;
5. clears guards;
6. clears history;
7. destroys owned resources.

Destruction is idempotent.

---

# Transition Semantics

This is one of the most important FSM behaviors.

# Hierarchical Exit Ordering

Transitions compute the divergence point between:

- current path;
- target path.

Only necessary exits and enters occur.

---

# LeafFirst

```luau
FSM.ExitOrdering.LeafFirst
```

Deepest child exits first.

Typical hierarchical behavior.

---

# ParentFirst

```luau
FSM.ExitOrdering.ParentFirst
```

Parents exit before descendants.

Useful for some teardown systems.

---

# Transition Deferral

Conflicting transitions may:

- queue;
- drop.

depending on policy.

---

# Single Switch Per Frame

When enabled:

```luau
SingleSwitchPerFrame = true
```

only one transition may occur per frame.

This prevents recursive transition storms.

---

# Task Cancellation Semantics

When:

```luau
CancelTasksOnExit = true
```

mode-owned tasks cancel automatically on exit.

This is extremely important for async correctness.

---

# Runtime Error Semantics

# Usage Errors

Usage errors raise immediately.

Examples:

- unknown mode;
- duplicate mode;
- invalid policy;
- invalid transition target;
- destroyed FSM usage.

---

# Runtime Failures

Lifecycle callback failures route through `ErrorHandler`.

This includes:

- enter callbacks;
- exit callbacks;
- update callbacks;
- guards;
- tracers.

One failing callback does not corrupt transition state.

---

# Tracing

Tracing is optional and global.

Trace events include:

- event kind;
- source mode;
- target mode;
- metadata tag.

Tracer failures route through `ErrorHandler`.

---

# Gotchas

# Modes Are Hierarchical

Transitions may affect multiple modes simultaneously.

---

# Enter/Exit Order Matters

Nested modes may rely on deterministic ordering.

Choose policy intentionally.

---

# Guards Should Be Pure

Guards should not mutate FSM state.

---

# Async Tasks Must Be Owned

Prefer mode-owned task groups instead of unmanaged async work.

---

# Destroying FSM Cancels Mode Resources

Do not keep stale references to destroyed mode-owned resources.

---

# Best Practices

# Prefer Declarative Builders

Good:

```luau
fsm:Mode("Combat", function(mode)
    mode:OnEnter(...)
    mode:OnExit(...)
end)
```

Avoid scattered imperative registration.

---

# Prefer Hierarchical Modes

Good hierarchy:

```text
Gameplay
├─ Combat
├─ Inventory
└─ Dialogue
```

Avoid flat giant state lists.

---

# Use Guards For Admission Logic

Good:

```luau
mode:Guard("Combat", staminaStore)
```

Avoid manual transition checks everywhere.

---

# Use Context For Scoped Dependencies

Modes should provide dependencies locally when possible.

---

# Use Task Groups For Async Lifecycle Ownership

Mode-owned async work should cancel automatically on exit.

---

# Full Example: Basic FSM

```luau
local machine = FSM.New({})

machine:Mode("Idle", function(mode)
    mode:OnEnter(function()
        print("entered idle")
    end)
end)

machine:Mode("Combat", function(mode)
    mode:OnEnter(function()
        print("entered combat")
    end)
end)

machine:Start("Idle")
machine:Switch("Combat")
```

---

# Full Example: Hierarchical Modes

```text
Gameplay
├─ Exploration
└─ Combat
    ├─ Melee
    └─ Ranged
```

Transitions only enter/exit affected branches.

---

# Full Example: Guarded Transition

```luau
combatMode:Guard("Inventory", function(context)
    return not context:Get("InDanger")
end)
```

---

# Full Example: Reactive Activity

```luau
local combatActive = machine:IsActiveStore("Combat")

combatActive:Subscribe(function(active)
    print(active)
end)
```

---

# Full Example: Mode-Owned Tasks

```luau
mode:OnEnter(function(context)
    local taskGroup = mode:TaskGroup()

    taskGroup:Spawn(function()
        while true do
            task.wait(1)
        end
    end)
end)
```

The task cancels automatically on exit.

---

# Full Example: Snapshot/Restore

```luau
local snapshot = machine:Snapshot()

machine:Restore(snapshot)
```

---

# Summary

Use `FSM` whenever systems need deterministic hierarchical state orchestration.

Use:

- modes for lifecycle ownership;
- guards for admission control;
- contexts for scoped dependency injection;
- task groups for async ownership;
- stores/signals for reactive observation;
- snapshots/history for restoration flows.

The result is a declarative hierarchical state-machine infrastructure integrated with the entire Kernel architecture.
