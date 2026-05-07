Awesome—here’s the full spec for the fsm module, matching the depth/style of sig, store, and rule. Still no implementations—this is contracts, rationale, and usage pseudocode only.

Conventions:

* Signal<T> from sig
* RStore<T> from store
* Rule, Task, TaskGroup from rule/task
* “Scope” = lifecycle container. Each Mode is a scope that auto-enables attached Rules and auto-cancels Tasks on exit.
* Engine runs with a deterministic frame scheduler (enter/exit/effect phases are well-defined).

⸻

What is fsm?

A Hierarchical State Machine runtime that:

* Organizes gameplay/UI into Modes (states), optionally hierarchical and/or parallel.
* Provides lifecycles (onEnter/onExit/onUpdate) to mount/unmount logic safely.
* Scopes Rules and Tasks to Modes (auto-enable/disable; auto-cancel on exit).
* Supports programmatic and guarded transitions with deterministic ordering.
* Offers history (return to last sub-state), queued transitions, and deferrals.

⸻

Core Types (shapes, not code)

type ModeHandle

A builder/handle for a single Mode (state) in the machine.

Instance API

* name(): string
* parent(): ModeHandle?
* onEnter(fn: (ctx, from?: string) -> (nil | Task | ()->())): ModeHandle
* onExit(fn: (ctx, to?: string) -> (nil | Task | ()->())): ModeHandle
* onUpdate(fn: (ctx, dt: number) -> ()): ModeHandle (optional)
* add(x: Rule | Task | ModeHandle | ()->Task | ()->(()->())): ModeHandle
* guard(to: string, when: RStore<boolean> | (ctx)->boolean, opts?: GuardOpts): ModeHandle
* taskGroup(): TaskGroup
* tag(label: string): ModeHandle

Why these returns? Chainable fluent API; attaching returns the same handle.

⸻

type GuardOpts

* priority?: integer — order when multiple guarded transitions are true.
* defer?: boolean — if true, do not transition while mid-enter/exit; queue to next frame.
* reason?: string — transition reason label for inspector.

⸻

type FSM

The state machine controller.

Instance API

* context(): any
* mode(name: string, builder?: (m: ModeHandle)->()): ModeHandle
* region(name: string, builder: (r: FSM)->()): ModeHandle (orthogonal; optional feature)
* start(name: string): ()
* switch(name: string, opts?: { immediate?: boolean, reason?: string }): ()
* current(): string
* isActive(name: string): boolean (exact path match or subtree—see note)
* inMode(name: string): boolean (alias for subtree membership)
* path(): { string } (stack from root → leaf)
* history(parentName: string): string?
* snapshot(): table
* restore(snap: table): ()
* onTransition(fn: (from: string, to: string, reason?: string) -> ()): Conn
* policy(opts: FSMPipelinePolicy): FSM
* dispose(): ()

⸻

type FSMPipelinePolicy

* singleSwitchPerFrame?: boolean (default: true) — coalesce multiple switch requests; only last one is taken this frame; others queue.
* cancelTasksOnExit?: boolean (default: true) — cancel Mode TaskGroup on exit.
* ordering?: "exitParentsFirst" | "exitSelfFirst" (default: “exitSelfFirst”) — defines enter/exit call order for nested states.
* deferral?: "drop" | "queue" (default: “queue”) — what to do if a switch is requested during enter/exit.
* trace?: boolean — enable built-in transition tracing.
* tag?: string — debug label for this FSM.

Why: These cover determinism, teardown safety, and re-entrancy behavior.

⸻

Creation & Topology

fsm.new(ctx: any, ?opts: FSMPipelinePolicy) -> FSM

* Purpose: create a state machine with a shared context object (exposed to modes and rules).
* Use case: { player, services, cameras }.
* Example:

local sm = fsm.new({ player = player, services = S }, { singleSwitchPerFrame = true })

* Params:
    * ctx: any table with pointers to domain objects; immutable reference during FSM lifetime.
    * opts: pipeline policy knobs.
* Returns: FSM.

⸻

fsm:mode(name: string, builder?: (m: ModeHandle)->()) -> ModeHandle

* Purpose: define or get a named Mode. If builder provided, configure it immediately.
* Use case: Exploration, Inventory, Settings, Combat, etc.
* Example:

local Explore = sm:mode("Exploration", function(M)
  M:onEnter(function(ctx) camera.to("ThirdPerson"); move.enable(ctx.player) end)
  M:onExit(function(ctx) move.disable(ctx.player) end)
end)

* Params:
    * name: unique within the FSM (hierarchy uses / or . by naming convention if desired).
    * builder: optional configurator callback.
* Returns: ModeHandle.

Return rationale: You often chain :add(rule(...)) immediately.

⸻

fsm:region(name: string, builder: (r: FSM)->()) -> ModeHandle (optional feature)

* Purpose: create an orthogonal region (parallel FSM) under the current machine—for advanced cases (e.g., “UI overlays” region running alongside “Game” region).
* Use case: Keep HUD/Overlay modes independent of gameplay modes.
* Example:

sm:region("Overlay", function(uiSm)
  uiSm:mode("HUD", function(M) ... end)
  uiSm:mode("PhotoMode", function(M) ... end)
  uiSm:start("HUD")
end)

* Params:
    * name: region label,
    * builder: defines modes for the sub-FSM.
* Returns: a synthetic ModeHandle representing the region (useful for tagging/inspector).

Why optional: Many teams won’t need true orthogonal regions at first.

⸻

Starting & Switching

fsm:start(name: string) -> ()

* Purpose: enter the initial mode.
* Use case: sm:start("Exploration") after bootstrap.
* Example:

sm:start("Exploration")

* Params:
    * name: existing mode name.
* Returns: ().

Behavior: Calls onEnter chain for the mode (and parents in order defined by ordering).

⸻

fsm:switch(name: string, opts?: { immediate?: boolean, reason?: string }) -> ()

* Purpose: request a transition to name.
* Use case: Called from Rules, UI, or program logic.
* Example:

sm:switch("Inventory", { reason = "OpenMenuInput" })

* Params:
    * name: target mode.
    * opts.immediate: if true, perform transition right now (use sparingly—tooling).
    * opts.reason: debug label for the transition.
* Returns: ().

Behavior:

* If singleSwitchPerFrame=true, subsequent calls in the same frame collapse to the last request.
* If called during enter/exit, behavior follows deferral policy (default: queue).

⸻

Introspection

fsm:current() -> string

* Purpose: current leaf mode name.
* Use case: Debugging, asserts, UI indicators.

fsm:isActive(name: string) -> boolean

* Purpose: true if the given mode is currently on the active path (parent or leaf).
* Example: if sm:isActive("Exploration") then ... end

fsm:inMode(name: string) -> boolean

* Purpose: alias of isActive, kept for readability.

fsm:path() -> { string }

* Purpose: current full path from root → leaf, e.g., { "Game", "Exploration" }.

fsm:history(parentName: string) -> string?

* Purpose: last active child mode under a parent (for history transitions).
* Use case: Return to last Inventory sub-tab mode, etc.

fsm:snapshot() -> table / fsm:restore(snap: table) -> ()

* Purpose: serialize/restore active path (and optionally sub-FSMs) for save/replay.
* Use case: save-scumming, QA repros.

fsm:onTransition(fn: (from: string, to: string, reason?: string) -> ()) -> Conn

* Purpose: subscribe to transitions (dev tools, analytics).
* Example:

sm:onTransition(function(from, to, why) print(from, "→", to, why) end)

fsm:policy(opts: FSMPipelinePolicy) -> FSM

* Purpose: adjust runtime policy after construction (dev toggles).

fsm:dispose() -> ()

* Purpose: tear down the FSM (disconnects, cancels tasks, clears modes).

⸻

Mode Lifecycle

ModeHandle:onEnter(fn: (ctx, from?: string) -> (nil | Task | ()->())) -> ModeHandle

* Purpose: work to do when this Mode becomes active.
* Conceptual use case: Enable movement, switch camera, show UI, start background tasks.
* Examples:

Explore:onEnter(function(ctx)
  camera.to("ThirdPerson")
  move.enable(ctx.player)
end)
Inventory:onEnter(function(ctx)
  ui.Inventory.open()
  return anim.timeline(...):play()     -- returns Task; auto-cancel on exit
end)

* Params:
    * fn(ctx, from): from is previous leaf mode name if any.
* Returns: same ModeHandle.
* Effect return:
    * nil: one-off sync setup.
    * Task: long-running operation automatically joined to mode’s TaskGroup (cancelled on exit).
    * () -> (): disposer to run on exit (unmount patterns).

⸻

ModeHandle:onExit(fn: (ctx, to?: string) -> (nil | Task | ()->())) -> ModeHandle

* Purpose: work to do just before the mode is deactivated.
* Use case: Save UI scroll, stop music layer, disable input, flush telemetry.
* Examples:

Inventory:onExit(function(ctx, to)
  ui.Inventory.close()
end)

* Params:
    * fn(ctx, to): to is target leaf mode name if known.
* Return/behavior: same semantics as onEnter.

Ordering: Determined by FSM ordering policy (default “exitSelfFirst”: exit child, then parent; on enter, enter parent, then child).

⸻

ModeHandle:onUpdate(fn: (ctx, dt: number) -> ()) -> ModeHandle (optional)

* Purpose: per-frame update while mode is active.
* Use case: Lightweight polling or camera smoothing tied to this mode.
* Notes: Prefer Rules + Signals for most logic; onUpdate is for special cases.

⸻

ModeHandle:add(x: Rule | Task | ModeHandle | ()->Task | ()->(()->())) -> ModeHandle

* Purpose: attach work to this Mode’s lifecycle.
* Conceptual use cases:
    * Add a Rule that only runs in this mode.
    * Spawn a Task that cancels on exit.
    * Attach a child Mode (hierarchy).
    * Provide a function that returns a Task (started on enter).
    * Provide a function that returns a disposer (cleanup on exit).
* Examples:

Explore:add(rule("OpenInventory")
  :on(inputs.alias("OpenMenu"))
  :do(function(ctx) ctx.sm:switch("Inventory") end))
Explore:add(function()
  return task.start(function(tok) -- heartbeat sampling
    -- loop with tok checks
  end)
end)

* Params:
    * x: one of the supported attachables.
* Returns: same ModeHandle.
* Why: One API to register everything that should live and die with the mode.

⸻

ModeHandle:guard(to: string, when: RStore<boolean> | (ctx)->boolean, opts?: GuardOpts) -> ModeHandle

* Purpose: declare a guarded transition that fires automatically when a condition becomes true.
* Conceptual use case: Auto-close Inventory if player enters combat; switch to Death screen when health ≤ 0.
* Examples:

Inventory:guard("Exploration", store.select(inCombat, function(b) return b end), { reason = "CombatStarted" })
Combat:guard("Death", store.select(health, function(h) return h <= 0 end), { priority = 10 })

* Params:
    * to: target mode,
    * when: boolean store or predicate evaluated each change,
    * opts.priority: disambiguate when multiple guards are true.
    * opts.defer: queue until next tick if entering/exiting.
    * opts.reason: label for inspector.
* Returns: same ModeHandle.

Behavior: Evaluated on relevant changes; when true, schedules a switch respecting FSM policies.

⸻

ModeHandle:taskGroup() -> TaskGroup

* Purpose: access this mode’s dedicated TaskGroup (in case you need finer control).
* Use case: Manually add tasks, cancel subset, await group completion in a tool.

⸻

ModeHandle:tag(label: string) -> ModeHandle

* Purpose: label a mode for the inspector (e.g., “Menu/Inventory”).

⸻

Scheduling & Ordering Guarantees

* Single switch per frame (default): if multiple switch requests arrive, the FSM transitions once to the last requested target for determinism. You can override via policy.singleSwitchPerFrame=false.
* Enter/Exit order:
    * exitSelfFirst (default): exit child → exit parent; enter parent → enter child.
    * exitParentsFirst: exit parent chain outwards; then enter new parent chain inwards; finally enter leaf.
* Mode scoping:
    * Rules attached to a Mode are enabled on enter and disabled on exit.
    * Tasks started from onEnter or via add(Task) are cancelled on exit (if cancelTasksOnExit=true).
* Deferrals: Switches requested during enter/exit follow deferral policy (queue by default). This avoids re-entrancy bugs.
* History: The FSM records last active child for each parent; history(parent) returns it.

⸻

Diagnostics & Tooling Hooks

* Transition stream: fsm:onTransition notifies (from, to, reason).
* Tracing (if policy.trace=true):
    * FSM.SwitchRequested(from, to, reason)
    * FSM.Exit(name), FSM.Enter(name)
    * FSM.TasksCancelled(name, count)
* Inspector can read:
    * Active path,
    * Rules enabled per Mode,
    * Tasks in each Mode’s group,
    * Guarded transitions pending/fired.

⸻

End-to-End Usage Pseudocode

Basic machine with Inventory and Settings

local ctx = { player = player, services = S }
local sm  = fsm.new(ctx)
local Explore = sm:mode("Exploration", function(M)
  M:onEnter(function() camera.to("ThirdPerson"); move.enable(ctx.player) end)
  M:onExit (function() move.disable(ctx.player) end)
  M:add(rule("OpenInventory")
    :on(inputs.alias("OpenMenu"))
    :do(function() sm:switch("Inventory", { reason = "MenuInput" }) end))
  -- Auto-close Inventory if combat starts (guard declared on Inventory)
end)
local Inventory = sm:mode("Inventory", function(M)
  M:onEnter(function() ui.Inventory.open(); camera.to("UI") end)
  M:onExit (function() ui.Inventory.close() end)
  M:add(rule("CloseInventory")
    :on(inputs.alias("Back"))
    :do(function() sm:switch("Exploration", { reason = "BackInput" }) end))
end)
-- Guard: if combat starts while in Inventory, pop back to Exploration
Inventory:guard("Exploration", inCombat, { reason = "CombatStarted", priority = 10 })
sm:start("Exploration")

Hierarchy with a sub-mode and history

local Menu = sm:mode("Menu", function(M)
  local Inv = sm:mode("Menu.Inventory", function(S) ... end)
  local Settings = sm:mode("Menu.Settings", function(S) ... end)
  -- Back goes to last visited child under Menu (history)
  rule("Menu.Back")
    :on(inputs.alias("Back"))
    :do(function()
      local last = sm:history("Menu") or "Menu.Inventory"
      sm:switch(last)
    end)
    :attach(M)
end)

Parallel region (orthogonal UI overlay)

sm:region("Overlay", function(uiSm)
  uiSm:mode("HUD", function(M)
    M:onEnter(function() ui.HUD.show(true) end)
    M:onExit (function() ui.HUD.show(false) end)
  end)
  uiSm:mode("PhotoMode", function(M) ... end)
  uiSm:start("HUD")
end)
-- Gameplay modes continue independently of Overlay region.

⸻

Parameter / Return Rationale

* Context object: avoids global lookups; gives every lifecycle hook and Rule effect a stable reference to game services and actors.
* Fluent Mode builder: encourages collocating lifecycle code and attached Rules; improves readability/testing.
* Tasks & disposers in onEnter/onExit: unify long-running jobs and reversible mounts with deterministic cleanup.
* Guarded transitions: declarative auto-switch logic keyed to Stores; avoids scattering “if X then switch” checks in Rules.
* History queries: substates often need “return to last”; providing this primitive simplifies UX flows.
* Switch policy knobs: eliminates heisenbugs from rapid re-entrancy; gives replay-deterministic behavior.

⸻

If this spec hits the mark, I can finish the engine with task next (cancellable async jobs, tokens, groups, timeouts, retries) in the same exhaustive format.
