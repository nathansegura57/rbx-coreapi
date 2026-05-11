# FSM

A hierarchical finite state machine. An FSM organizes behavior into named modes. Entering a mode runs `OnEnter`; leaving runs `OnExit`. Modes can have parent modes (forming a tree), guards that trigger automatic transitions, providers that inject values into a mode-scoped `Context` layer, and attached `Rule`s that enable and disable with the mode.

---

## Enum Tables

### `FSM.ExitOrdering`

```luau
FSM.ExitOrdering.LeafFirst   -- (default) exit child modes before parents
FSM.ExitOrdering.ParentFirst -- exit parent modes before children
```

### `FSM.Deferral`

Controls behavior when `Switch` is called during an in-progress transition:

```luau
FSM.Deferral.Queue  -- (default) queue the switch; drain after transition completes
FSM.Deferral.Drop   -- discard the switch if a transition is in progress
```

---

## API Reference

### `FSM.New(ctx, opts?)`

Creates a new FSM. `ctx` may be a plain table (wrapped into `Context.Root` automatically) or an existing `Context`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `ctx` | `Context \| { [any]: any }` | Shared context or initial values table |
| `opts` | `PartialPolicy?` | Optional policy overrides |

**Returns:** `FSM<Ctx>`

**Errors:**
- `FSM.New: ctx must be a table or Context`
- `FSM.New: {policy validation message}`

---

### `FSM.IsFSM(value)` / `FSM.IsMode(value)`

Return `true` if `value` is a valid FSM or Mode handle.

---

### `FSM.DefaultPolicy()`

Returns a copy of the default policy.

**Returns:** `Policy`

---

### `FSM.ValidatePolicy(policy)`

Validates a partial policy without applying it.

**Returns:** `(boolean, string?)`

---

### `FSM.SetTracer(fn?)`

Installs a global FSM tracer. Pass `nil` to remove.

| Parameter | Type | Description |
|-----------|------|-------------|
| `fn` | `((TraceEvent) -> ())?` | Receives a trace payload table |

Trace events: `FSM.Start`, `FSM.Transition`, `FSM.Destroy`. The payload always includes `Event` and `Tag` (if set), plus `From`/`To` for transitions.

---

### FSM Policy

Set via `fsm:Policy(opts)` or the second argument to `FSM.New`. All fields are optional and merge into defaults.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `SingleSwitchPerFrame` | `boolean?` | `true` | Coalesce multiple `Switch` calls per frame into the last one |
| `CancelTasksOnExit` | `boolean?` | `true` | Cancel the mode's task group on exit |
| `ExitOrdering` | `string?` | `"LeafFirst"` | Use `FSM.ExitOrdering.*` |
| `Deferral` | `string?` | `"Queue"` | Use `FSM.Deferral.*` |
| `ErrorPolicy` | `string?` | `nil` | Override global error policy for `Enter`/`Exit` errors |
| `Trace` | `boolean?` | `false` | Enable tracing |
| `Tag` | `string?` | `nil` | Label for traces |

**Validation errors:**
- `FSM.New: policy must be a table`
- `FSM.New: unknown policy key: {k}`
- `FSM.New: SingleSwitchPerFrame must be a boolean`
- `FSM.New: CancelTasksOnExit must be a boolean`
- `FSM.New: ExitOrdering must be 'LeafFirst' or 'ParentFirst'`
- `FSM.New: Deferral must be 'Queue' or 'Drop'`
- `FSM.New: ErrorPolicy must be 'Throw', 'Warn', 'Swallow', or 'Collect'`
- `FSM.New: Trace must be a boolean`
- `FSM.New: Tag must be a string`

---

### FSM Instance Methods

#### `fsm:Context()`

Returns the FSM's root context.

**Returns:** `Context`

**Errors:** `FSM.Context: FSM is destroyed`

---

#### `fsm:Mode(name, builder?)`

Gets or creates a mode. If `name` already exists, returns the existing mode. If `builder` is provided, calls `builder(mode)` before returning.

Dot-notation names (`"parent.child"`) establish implicit parent relationships if `"parent"` is registered.

| Parameter | Type | Description |
|-----------|------|-------------|
| `name` | `string` | Non-empty mode name; may use dot notation |
| `builder` | `((mode: Mode) -> ())?` | Optional configuration callback |

**Returns:** `Mode<Ctx>`

**Errors:**
- `FSM.Mode: FSM is destroyed`
- `FSM.Mode: name must be a non-empty string`
- `FSM.Mode: builder must be a function or nil`

---

#### `fsm:HasMode(name)` / `fsm:GetMode(name)`

Check or retrieve a registered mode by name. `GetMode` returns `nil` if not found.

---

#### `fsm:Start(name)`

Enters the initial mode. Must be called exactly once.

| Parameter | Type | Description |
|-----------|------|-------------|
| `name` | `string` | The initial mode; must be registered |

**Errors:**
- `FSM.Start: FSM is destroyed`
- `FSM.Start: already started`
- `FSM.Start: mode '{name}' not registered`
- `FSM.Start: guard in mode '{m}' targets unregistered mode '{to}'`

---

#### `fsm:Switch(name, opts?)`

Requests a transition to `name`. By default, deferred to next frame (controlled by `SingleSwitchPerFrame`). Immediate transitions may be requested via `opts.Immediate = true`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `name` | `string` | Target mode; must be registered |
| `opts` | `SwitchOptions?` | Optional options |

**`SwitchOptions` fields:**

| Field | Type | Description |
|-------|------|-------------|
| `Immediate` | `boolean?` | Execute transition synchronously |
| `Reason` | `string?` | Stored in `TransitionFrame.Reason` |
| `Data` | `unknown?` | Stored in `TransitionFrame.Data` |

**Errors:**
- `FSM.Switch: FSM is destroyed`
- `FSM.Switch: FSM has not started`
- `FSM.Switch: mode '{name}' not registered`
- `FSM.Switch: opts must be a table or nil`

---

#### `fsm:CanSwitch(name)`

Returns `true` if switching to `name` is currently possible (FSM is started, not destroyed, mode exists, and `name` differs from the current leaf).

**Returns:** `boolean`

---

#### `fsm:Current()`

Returns the name of the current leaf mode, or `""` if not started.

**Returns:** `string`

---

#### `fsm:IsActive(name)`

Returns `true` if `name` is anywhere in the active path (including parent modes).

**Returns:** `boolean`

---

#### `fsm:InMode(name)`

Returns `true` if `name` is the current leaf mode.

**Returns:** `boolean`

---

#### `fsm:Path()`

Returns a clone of the active mode path from root to leaf.

**Returns:** `{ string }`

```luau
-- For FSM in mode "game.playing.combat":
fsm:Path()  -- { "game", "game.playing", "game.playing.combat" }
```

---

#### `fsm:History(parentName)`

Returns the name of the last active child mode under `parentName`, or `nil` if none.

---

#### `fsm:SwitchToHistory(parentName, opts?)`

Switches to the last active child mode of `parentName` if history exists. No-op if no history is recorded for that parent.

---

#### `fsm:ClearHistory(parentName?)`

Clears history for `parentName`, or all history if `parentName` is `nil`.

---

#### `fsm:Snapshot(opts?)`

Captures the current active path and history map.

**Returns:** `Snapshot` — `{ ActivePath: { string }, History: { [string]: string } }`

---

#### `fsm:Restore(snapshot, opts?)`

Switches to the leaf mode from `snapshot.ActivePath` and restores the history map. The transition uses `Reason = "Restore"` and `Data = snapshot`.

**Errors:**
- `FSM.Restore: FSM is destroyed`
- `FSM.Restore: FSM has not started`

---

#### `fsm:OnTransition(fn)`

Subscribes to all transition events. Called after every mode switch.

| Parameter | Type | Description |
|-----------|------|-------------|
| `fn` | `(event: TransitionEvent) -> ()` | Receives a `TransitionEvent` |

**Returns:** `Connection.Connection`

**`TransitionEvent` fields:**

| Field | Type | Description |
|-------|------|-------------|
| `From` | `string` | Previous leaf mode name (empty string on start) |
| `To` | `string` | New leaf mode name |
| `Reason` | `string?` | Transition reason, if provided |
| `Data` | `unknown?` | Transition data, if provided |

---

#### `fsm:WaitForTransition()`

Yields until the next transition, then returns the `TransitionEvent`. Must be called from a yieldable coroutine.

**Returns:** `TransitionEvent`

**Errors:**
- `FSM.WaitForTransition: FSM destroyed`

---

#### `fsm:Policy(opts)`

Updates the FSM policy. Cannot be called after `Start`.

**Returns:** `self`

**Errors:**
- `FSM.Policy: FSM is destroyed`
- `FSM.Policy: cannot change policy after start`
- `FSM.Policy: {validation message}`

---

#### `fsm:IsStarted()` / `fsm:IsDestroyed()`

**Returns:** `boolean`

---

#### `fsm:IsActiveStore(name)`

Returns a `ReadableStore<boolean>` that is `true` while `name` is in the active path. Created lazily and cached.

| Parameter | Type | Description |
|-----------|------|-------------|
| `name` | `string` | Non-empty mode name |

**Returns:** `ReadableStore<boolean>`

**Errors:**
- `FSM.IsActiveStore: invalid FSM handle`
- `FSM.IsActiveStore: name must be a non-empty string`

```luau
local isPlaying = fsm:IsActiveStore("playing")
isPlaying:Subscribe(function(active)
    hud:SetVisible(active)
end)
```

---

#### `fsm.ActiveStore`

A `ReadableStore<string>` that always holds the current leaf mode name. Updated on every transition.

```luau
fsm.ActiveStore:Subscribe(function(mode)
    print("now in:", mode)
end)
```

---

#### `fsm.TransitionSignal`

A `Signal<TransitionEvent>` that fires on every transition. Equivalent to `fsm:OnTransition(fn)` but exposes the raw signal for composing with operators.

---

#### `fsm:Destroy()`

Exits all active modes (running `OnExit`), cancels all task groups, destroys the `TransitionSignal`, and tears down internal stores. Idempotent.

---

### Mode Instance Methods

#### `mode:Name()`

Returns the mode's registered name.

**Returns:** `string`

---

#### `mode:Parent()`

Returns the parent Mode handle, or `nil`.

---

#### `mode:OnEnter(fn)`

Registers a callback called when this mode is entered.

| Parameter | Type | Description |
|-----------|------|-------------|
| `fn` | `(ctx: Context, frame: TransitionFrame) -> any` | May return a cleanup `() -> ()` or a `Task` |

**Returns:** `self`

**`TransitionFrame` fields:**

| Field | Type | Description |
|-------|------|-------------|
| `From` | `string` | Previous leaf mode |
| `To` | `string` | New leaf mode |
| `Reason` | `string?` | Provided reason |
| `Data` | `unknown?` | Provided data |
| `StartedAt` | `number` | `Scheduler.Now()` at transition start |
| `Immediate` | `boolean` | Whether this was an immediate transition |

**Return value behavior:**
- `() -> ()` — registered as an active disposer; called on exit
- `Task.Task<any>` — added to the mode's task group (cancelled on exit if `CancelTasksOnExit`)
- `nil` — no additional cleanup

**Errors:**
- `Mode.OnEnter: mode is destroyed`
- `Mode.OnEnter: fn must be a function`

---

#### `mode:OnExit(fn)`

Registers a callback called when this mode is exited. Same signature and return-value behavior as `OnEnter`.

> **Note:** Async exits are not supported. If `fn` returns a `Task`, a warning is routed through `ErrorHandler` and the task is ignored.

**Errors:**
- `Mode.OnExit: mode is destroyed`
- `Mode.OnExit: fn must be a function`

---

#### `mode:OnUpdate(fn)`

Registers a per-frame callback connected to `Scheduler.OnStep` while the mode is active.

| Parameter | Type | Description |
|-----------|------|-------------|
| `fn` | `(ctx: Context, dt: number, frame: UpdateFrame) -> ()` | Called every frame |

**`UpdateFrame` fields:**

| Field | Type | Description |
|-------|------|-------------|
| `Mode` | `string` | Mode name |
| `StartedAt` | `number` | Time the mode was entered |

**Errors:**
- `Mode.OnUpdate: mode is destroyed`
- `Mode.OnUpdate: fn must be a function`

---

#### `mode:Add(resource)`

Attaches a resource to this mode:

- **`Rule`** — enabled on mode enter, disabled on mode exit
- **`Task`** — added to the mode's task group
- **`Mode`** — establishes explicit parent relationship (alternative to dot-naming)
- **`function(ctx, frame) -> any`** — factory; runs on enter, return value treated like `OnEnter` return

**Errors:**
- `Mode.Add: mode is destroyed`
- `Mode.Add: duplicate rule`
- `Mode.Add: invalid mode handle`
- `Mode.Add: child mode must belong to the same FSM`
- `Mode.Add: mode already has a parent (re-parenting is not allowed)`
- `Mode.Add: cycle detected in parent hierarchy`
- `Mode.Add: expected Rule, Task, Mode, or function`

---

#### `mode:Provide(providerOrValues)`

Injects values into the mode's context layer.

| Parameter | Type | Description |
|-----------|------|-------------|
| `providerOrValues` | `(ctx, frame) -> (table, cleanup?)  \| table` | Function or table of key→value pairs |

When a **function** is provided:
- Called with `(parentCtx, frame)` on mode enter
- First return value must be a table of key→value pairs
- Second return value (optional) is a cleanup function called when the mode context layer is destroyed

When a **table** is provided:
- Values are merged directly into the mode context layer on enter

**Errors:**
- `Mode.Provide: mode is destroyed`
- `Mode.Provide: providerOrValues must be a function or table`

```luau
-- Table form: static values.
mode:Provide({ RoundId = os.time() })

-- Function form: dynamic values + cleanup.
mode:Provide(function(ctx, frame)
    local svc = MyService.New()
    return { Service = svc }, function()
        svc:Cleanup()
    end
end)
```

---

#### `mode:Guard(to, guard, opts?)`

Registers an automatic transition from this mode to `to` when `guard` passes.

| Parameter | Type | Description |
|-----------|------|-------------|
| `to` | `string` | Target mode name; validated on `fsm:Start` |
| `guard` | `Store.ReadableStore<boolean> \| (ctx, frame) -> boolean` | Store or function |
| `opts` | `GuardOptions?` | Optional options |

**`GuardOptions` fields:**

| Field | Type | Description |
|-------|------|-------------|
| `Priority` | `number?` | Higher priority guards are evaluated first (default `0`) |
| `Reason` | `string?` | Passed as `TransitionFrame.Reason` |
| `Data` | `unknown?` | Passed as `TransitionFrame.Data` |
| `Defer` | `boolean?` | If `true`, deferred-switch; otherwise immediate (default `false`) |

**Store guards** — subscribed (without immediate fire) while the mode is active. When the store becomes `true`, the switch is triggered.

**Function guards** — evaluated once on mode enter, sorted by priority descending. If any guard returns `true`, the corresponding switch fires (deferred if `Defer = true`, immediate otherwise). Only the first matching guard fires.

**Errors:**
- `Mode.Guard: mode is destroyed`
- `Mode.Guard: to must be a non-empty string`
- `Mode.Guard: guard must be a Store or function`
- `FSM.Start: guard in mode '{m}' targets unregistered mode '{to}'`

```luau
-- Store guard: auto-switch to "gameover" when health hits zero.
local isDead = Store.Derive(function() return health:Get() <= 0 end, { health })
playing:Guard("gameover", isDead, { Reason = "Death" })

-- Function guard: auto-switch to "idle" if loading takes too long.
loading:Guard("idle", function(ctx, frame)
    return (Scheduler.Now() - frame.StartedAt) > 10
end, { Defer = true })
```

---

#### `mode:TaskGroup()`

Returns (or lazily creates) the mode's `TaskGroup`. Use this to track tasks that should be cancelled when the mode exits.

**Returns:** `Task.TaskGroup`

**Errors:** `Mode.TaskGroup: invalid mode handle`

---

#### `mode:Tag(label)`

Sets a display label for the mode (used in tracing).

**Returns:** `self`

---

#### `mode:IsActive()`

Returns `true` if this mode is currently in the FSM's active path.

**Returns:** `boolean`

---

#### `mode:IsDestroyed()`

Returns `true` if this mode has been destroyed.

---

#### `mode:Destroy()`

Removes the mode from the FSM, destroys its attached rules, and clears its task group. Cannot be called while the mode is active.

**Errors:** `Mode.Destroy: cannot destroy active mode`

---

## Hierarchical Modes

Modes can be nested in a tree. The active path is the sequence of modes from the tree root to the current leaf.

**Dot notation (implicit parenting):**
```luau
local game    = fsm:Mode("game")
local playing = fsm:Mode("game.playing")  -- parent is "game"
local combat  = fsm:Mode("game.playing.combat")
```

**Explicit parenting via `Add`:**
```luau
local game    = fsm:Mode("game")
local playing = fsm:Mode("playing")
game:Add(playing)  -- establishes game as playing's parent
```

**Transition mechanics:**
- Only modes that are _different_ between the from-path and to-path are exited/entered.
- The LCA (Lowest Common Ancestor) is preserved — modes shared by both paths are not re-entered.
- `ExitOrdering.LeafFirst` exits in `[leaf, ..., lca+1]` order (default).
- `ExitOrdering.ParentFirst` exits in `[lca+1, ..., leaf]` order.

---

## Gotchas

- **`Switch` is deferred by default.** With `SingleSwitchPerFrame = true` (the default), multiple `Switch` calls in the same frame coalesce into the last one. Use `opts.Immediate = true` to bypass this.
- **OnExit cannot be async.** If an `OnExit` callback returns a Task, a route error is reported and the task is ignored. Run cleanup synchronously or pre-cancel the task before exit.
- **Guard function evaluation is one-shot on enter.** Function guards (unlike Store guards) are evaluated once when the mode is entered. If you need continuous evaluation, use a Store guard.
- **Guard targets are validated on `Start`.** If any guard targets a mode that has not been registered, `fsm:Start` throws. Register all modes before starting.
- **Provider errors route through `handleFSMError`.** Provider function errors are reported per the FSM's `ErrorPolicy`, not the global policy. Provider cleanup errors go through `ErrorHandler`.
- **`CancelTasksOnExit = true` cancels with `Task.Reason.ModeExit`.** Tasks returned from `OnEnter` are tracked in the mode's task group. When the mode exits, the group is cancelled.
- **`IsActiveStore` and `ActiveStore` update during transitions.** They are set before `OnEnter` runs for entering modes, so guards and `OnEnter` callbacks can read them.
- **Re-parenting is not allowed.** Once a mode has been added to a parent via `mode:Add(child)` or dot notation, it cannot be moved. Attempting to re-parent throws.

---

## Complete Example

```luau
local Context = require(path.to.Context)
local FSM     = require(path.to.FSM)
local Rule    = require(path.to.Rule)
local Signal  = require(path.to.Signal)
local Store   = require(path.to.Store)
local Task    = require(path.to.Task)

-- Shared state
local score   = Store.Value(0)
local health  = Store.Value(100)

-- FSM with a shared context
local game = FSM.New({ Score = score, Health = health }, {
    SingleSwitchPerFrame = true,
    CancelTasksOnExit    = true,
})

-- ── Modes ────────────────────────────────────────────────────────────────────

local idle = game:Mode("idle")
idle:OnEnter(function(ctx, frame)
    print("idle — waiting for player")
    score:Set(0)
    health:Set(100)
end)

local loading = game:Mode("loading")
loading:OnEnter(function(ctx, frame)
    return Task.Start(function(token)
        local ok = Task.Sleep(2, token)
        if not ok then return end
        game:Switch("playing")
    end)
end)
-- Fall back to idle if loading takes > 5 seconds.
loading:Guard("idle", function(ctx, frame)
    return (Scheduler.Now() - frame.StartedAt) > 5
end, { Defer = true, Reason = "LoadTimeout" })

local playing = game:Mode("playing")

-- Provider: inject a per-round signal into the mode context.
local onEnemyKilled = Signal.New()
playing:Provide({ EnemyKilledSignal = onEnemyKilled })

playing:OnEnter(function(ctx, frame)
    print("playing! from:", frame.From)
end)
playing:OnExit(function(ctx, frame)
    print("exiting playing, score:", score:Get())
end)

-- Auto-switch to gameover when health hits zero.
local isDead = Store.Derive(function() return health:Get() <= 0 end, { health })
playing:Guard("gameover", isDead, { Reason = "Death" })

-- Attached rule: score on kill.
local killRule = Rule.New("ScoreOnKill")
    :On(onEnemyKilled)
    :Run(function(ctx, payload, frame)
        score:Update(function(n) return n + (payload.Points or 10) end)
        if score:Get() >= 100 then
            game:Switch("gameover", { Reason = "ScoreLimit" })
        end
    end)
    :Policy({ Concurrency = Rule.Concurrency.Merge })

playing:Add(killRule)

local gameover = game:Mode("gameover")
gameover:OnEnter(function(ctx, frame)
    print("game over! reason:", frame.Reason, "score:", score:Get())
end)
-- Return to idle after 3 seconds.
gameover:Guard("idle", Store.Value(false))  -- replaced by Timer below
gameover:OnEnter(function(ctx, frame)
    return Task.Delay(3, function()
        game:Switch("idle")
    end)
end)

-- ── Start ─────────────────────────────────────────────────────────────────────

game:Start("idle")

-- ── React to mode changes ─────────────────────────────────────────────────────

game.ActiveStore:Subscribe(function(mode)
    print("→ mode:", mode)
end, { Immediate = false })

-- ── Drive the game ─────────────────────────────────────────────────────────────

game:Switch("loading")           -- triggers 2-second async load
-- (after load) game auto-switches to "playing"
onEnemyKilled:Fire({ Points = 60 })
onEnemyKilled:Fire({ Points = 50 }) -- score hits 110 → gameover

-- ── Cleanup ───────────────────────────────────────────────────────────────────

game:Destroy()
```
