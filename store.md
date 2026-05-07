Awesome—here’s the full spec for the store module in the same style as we did for sig. No implementations—just what it does, why, how you’d use it, and per-API details (purpose, example, params, returns).

Conventions:

* RStore<T> = readable store.
* WStore<T> = writable store.
* DStore<T> = derived (read-only) store.
* Conn = { Connected: boolean, Disconnect: (Conn)->() } (subscription handle).
* Notifications are coalesced and delivered in a deterministic phase (e.g., end-of-frame), so subscribers see a stable wave of changes.

⸻

Core Types (shapes, not code)

type RStore<T>

* Purpose: reactive value you can read and subscribe to.
* Conceptual use case: current stamina, selected tab, camera FOV.
* Instance API:
    * get(): T
    * subscribe(fn: (new: T, old: T?) -> ()): Conn
    * changed(): Signal<{ new: T, old: T? }>
    * equals(eq: (a: T, b: T) -> boolean): RStore<T>
    * name(): string?
    * (sugar) map<U>(pick: (T)->U, ?equals: (U,U)->boolean): DStore<U> — projection

Params/returns (why):

* get() returns the current value synchronously so logic can combine stores imperatively when needed.
* subscribe returns a Conn so callers can stop listening (e.g., on mode exit).
* changed() exposes a Signal for composition with sig operators.
* equals lets you override equality to avoid noisy updates (e.g., deep compare for tables).
* map is convenience to build a derived projection without touching store.derive.

⸻

type WStore<T> (extends RStore<T>)

* Purpose: same as RStore, plus mutation.
* Instance API:
    * set(v: T): ()
    * update(fn: (cur: T) -> T): ()

Why: set is direct assignment; update is safer for “read-modify-write” sequences and composes well inside transactions.

⸻

type DStore<T> (extends RStore<T>)

* Purpose: derived/computed store; read-only with recorded dependencies.
* Instance API:
    * deps(): { RStore<any> } — for introspection/inspector.

Why: tooling and debugging—see what drives a derived value.

⸻

Creation

store.value<T>(init: T, ?opts: { name?: string, equals?: (a:T,b:T)->boolean }) -> WStore<T>

* Purpose: create a mutable store.
* Use case: stamina = 100, menuOpen = false, selectedTab = “Weapons”.
* Example:

local stamina = store.value(100, { name = "player.stamina" })
stamina:set(95)
stamina:update(function(s) return math.min(100, s + 12*dt) end)

* Params:
    * init: initial value.
    * opts.name: debug label for inspector.
    * opts.equals: custom equality; prevent redundant notifications.
* Returns: WStore<T> you can read, set, and subscribe to.

⸻

store.derive<T>(compute: ()->T, deps: { RStore<any> }, ?opts: { name?: string, equals?: (a:T,b:T)->boolean }) -> DStore<T>

* Purpose: computed value from other stores (reactive formula).
* Use case: canSprint = (stamina > 10) and grounded.
* Example:

local canSprint = store.derive(function()
  return stamina:get() > 10 and grounded:get()
end, { stamina, grounded }, { name = "player.canSprint" })

* Params:
    * compute: pure function reading dependencies.
    * deps: explicit list for dependency tracking and cycle detection.
    * opts: name/equality override for the derived output.
* Returns: DStore<T> recomputed when any dep changes (coalesced per frame).

Why explicit deps? Deterministic graph, cycle detection, and reliable invalidation without monkey-patching get() access.

⸻

store.const<T>(v: T) -> RStore<T>

* Purpose: immutable store.
* Use case: design constants, feature flags (baked at runtime).
* Example: local MaxStamina = store.const(100)
* Params: v constant value.
* Returns: RStore<T> that never changes—handy in compositions; zero allocations on subscribe.

⸻

Collection Stores (helpers)

store.table<K,V>() -> { get: ()-> {[K]:V}, setKey: (k:K, v:V)->(), updateKey: (k:K, f:(V?)->V)->(), delKey: (k:K)->(), keys: RStore<{K}>, size: RStore<number>, entries: RStore<{[K]:V}> }

* Purpose: ergonomic wrapper for mutable dictionaries with reactive projections.
* Use case: items by id, entity registry, active buffs.
* Example:

local items = store.table<string, Item>()
items.setKey("sword01", sword)
items.updateKey("sword01", function(prev) return table.freeze({ ...prev, level = prev.level + 1 }) end)
items.delKey("old")
items.size:subscribe(function(n) print("items:", n) end)

* Params: none (creates empty table store).
* Returns: a small API + reactive keys, size, entries—so UIs can bind to lists without manual folds.

store.set<T>() and store.map<K,V>()

* Purpose: specialized collection stores for mathematical sets and maps.
* Use case: in-range entity IDs, status effects.
* Example:

local inRange = store.set<number>()
inRange.add(123); inRange.remove(123)
inRange.has:map(function(id) ... end) -- pseudo: you’d expose has/get stores

* Params/Returns: Shapes mirror table<K,V> but expose set/map semantic operations (add/remove/has). Helpful to keep code expressive.

⸻

Composition

store.all(stores: { RStore<any> }) -> RStore<any>

* Purpose: combine many stores.
* Two behaviors:
    1. If all inputs are booleans, returns RStore<boolean> = logical AND.
    2. Otherwise, returns RStore<tuple> (or a record) aggregating current values in order.
* Use case:
    * Guards: canJump = store.all({ grounded, staminaOk })
    * Grouped bind: vec2 = store.all({ x, y })
* Example:

local canJump = store.all({ grounded, stamina:map(function(s) return s > 10 end) })
local pos = store.all({ x, y }):map(function(t) return Vector2.new(t[1], t[2]) end)

* Params: stores to combine.
* Returns: RStore<boolean> or RStore<{...}> depending on inputs (documented for clarity).

⸻

store.any(stores: { RStore<boolean> }) -> RStore<boolean>

* Purpose: boolean OR across inputs.
* Use case: “can open” if any sub-guard is true.
* Example: local canOpen = store.any({ isMobile, hasController })
* Params: boolean stores only.
* Returns: RStore<boolean>.

⸻

store.match<S, T>(source: RStore<S>, cases: { [S]: RStore<T>, _?: RStore<T> }) -> RStore<T>

* Purpose: branch by a key (like a switch) producing a store.
* Use case: device-specific rules; layout per platform.
* Example:

local canOpenMenu = store.match(device, {
  PC = store.select(mouseLocked, function(b) return not b end),
  _  = store.const(true),
})

* Params:
    * source: key store.
    * cases: mapping from key ➜ store; _ default.
* Returns: RStore<T> that mirrors whichever case is active.

⸻

store.select<T,R>(source: RStore<T>, pick: (T)->R, ?equals: (R,R)->boolean) -> DStore<R>

* Purpose: project a store to a derived value (distinct by default).
* Use case: from player profile pick displayName; from vector pick .X.
* Example:

local healthPct = store.select(health, function(h) return h / maxHealth:get() end)

* Params:
    * source: input store,
    * pick: projection function,
    * equals (optional): equality on R.
* Returns: DStore<R> auto-recomputed when source changes.

Instance sugar: source:map(pick, equals) is equivalent.

⸻

store.tween<T>(source: RStore<T>, opts: { time?: number, easing?: string, delay?: number }) -> RStore<T>

* Purpose: smooth value changes over time (non-physical).
* Use case: UI alpha fades, slider indicator, tab underline motion.
* Example:

local fovTarget = store.value(70)
local fovSmooth = store.tween(fovTarget, { time = 0.25, easing = "quadOut" })
camera.bindFOV(fovSmooth)

* Params:
    * source: target values to follow,
    * time, easing, delay: curve config.
* Returns: RStore<T> that tracks source along a tween curve—subscribers get many intermediate values between steps.

⸻

store.spring<T>(source: RStore<T>, opts: { stiffness?: number, damping?: number, mass?: number, clamp?: boolean }) -> RStore<T>

* Purpose: smooth changes using a physical spring model.
* Use case: elastic camera moves, overshooting tab slider, buttery UI.
* Example:

local sliderTargetX = store.value(0)
local sliderX = store.spring(sliderTargetX, { stiffness = 380, damping = 28 })
ui.bindPositionX(TabSlider, sliderX)

* Params:
    * source: target values,
    * opts: spring params.
* Returns: RStore<T> generating a continuous motion profile—great “feel” out-of-the-box.

⸻

Transactions & Scheduling

store.transaction(block: ()->()) -> ()

* Purpose: batch many mutations so subscribers see one consolidated change wave.
* Use case: apply multiple profile updates atomically (gold, xp, inventory) to avoid intermediate UI flicker.
* Example:

store.transaction(function()
  gold:set(gold:get() + reward.gold)
  xp:set(xp:get() + reward.xp)
  items.setKey(reward.item.id, reward.item)
end)

* Params: block mutates any number of stores.
* Returns: (); effect is in the scheduling of notifications (coalesced end-of-frame flush).

Why: determinism and performance—subscribers compute once with consistent inputs.

⸻

store.batch(block: ()->()) -> ()

* Purpose: like transaction, but may flush immediately in the current phase (implementation-defined; document your policy). Useful in tools.
* Use case: editor sliders driving many properties in a single pass.
* Params/Returns: same shape as transaction.

Use transaction for game logic (frame-coalesced). Keep batch for explicit immediate recalcs when needed (e.g., offline editors/debug tools).

⸻

Snapshots, History, Persistence Hooks

store.snapshot(...stores: { RStore<any> }) -> { [string]: any }

* Purpose: capture values for save/load, undo/redo, or replay.
* Use case: save settings, take a pre-quest checkpoint.
* Example:

local snap = store.snapshot(volume, brightness, keybinds)
-- later:
store.restore(snap)

* Params: list of stores to read; names should derive from store.name() if available (implementation chooses keys).
* Returns: plain table of values.

⸻

store.restore(snapshot: { [string]: any }) -> ()

* Purpose: write a snapshot back into matching writable stores.
* Use case: load settings on boot; dev tool’s state restore.
* Example: as above.
* Params: snapshot table.
* Returns: ().

Why: consistent mechanism to serialize/deserialize reactive state.

⸻

store.history<T>(s: WStore<T>, limit?: number) -> { undo: ()->boolean, redo: ()->boolean, clear: ()->(), canUndo: RStore<boolean>, canRedo: RStore<boolean> }

* Purpose: per-store undo/redo with reactive availability flags.
* Use case: UI editors (keymapping, layout), build mode, dialogue graph tool.
* Example:

local title = store.value("Hello")
local hist = store.history(title, 50)
title:set("Hello, Traveler")
hist.undo() -- revert

* Params:
    * s: the store to track,
    * limit (optional): max entries to buffer.
* Returns: imperative actions (undo/redo/clear) + reactive guards (canUndo/canRedo).

Why: quality-of-life for any authoring or option-heavy UI with minimal glue code.

⸻

Instance Methods (expanded)

Some of these were listed under the type; here are full docs with examples.

rstore:get() -> T

* Purpose: read current value synchronously.
* Use case: compute a derived value outside of a reactive context (e.g., in a rule effect).
* Example: if stamina:get() > 10 then sprint() end

rstore:subscribe(fn: (new:T, old:T?)->()) -> Conn

* Purpose: react to changes; runs during the store notification phase.
* Use case: update a UI label whenever text changes.
* Example:

nameStore:subscribe(function(n) NameLabel.Text = n end)

rstore:changed() -> Signal<{new:T, old:T?}>

* Purpose: use store changes in signal pipelines.
* Use case: selectedItem:changed():connect(playOpenAnim)

rstore:equals(eq: (a:T,b:T)->boolean) -> RStore<T>

* Purpose: wrap with a comparator to suppress redundant emissions.
* Use case: ignore small float jitter (abs(a-b) < 1e-3).

rstore:name() -> string?

* Purpose: debugging/inspector labeling.

rstore:map<U>(pick: (T)->U, ?equals: (U,U)->boolean) -> DStore<U>

* Purpose: projection sugar (same as store.select(r, pick)).
* Use case: health:map(function(h) return h/max end)

wstore:set(v: T) -> () / wstore:update(fn: (T)->T) -> ()

* Purpose: mutate value; coalesced notifications.
* Use case: volume:set(0.8); xp:update(function(x) return x + delta end)

dstore:deps() -> { RStore<any> }

* Purpose: introspection of dependent graph (for tools/inspector).

⸻

Design Notes (behavioral guarantees)

* Single wave: Within a frame, any number of set/update calls across stores result in one subscriber notification wave (unless batch explicitly flushes earlier).
* Order: When multiple derived stores depend on the same inputs, recompute order is deterministic (topological); in ties, creation order (or name) wins—document your rule for replayability.
* Cycles: store.derive with cyclic dependencies must error in dev builds with a helpful path trace.
* Equality: All stores apply distinct-until-changed semantics by default (shallow for primitives; reference compare for objects) unless a custom equals is supplied.
* GC & leaks: subscribe returns Conn; rules and FSM modes must hold and Disconnect on exit.

⸻

End-to-End Pseudocode (glueing it together)

-- Domain stores
local stamina     = store.value(100, { name = "player.stamina" })
local grounded    = store.value(true,  { name = "player.grounded" })
local maxStamina  = store.const(100)
-- Guards
local staminaOk   = stamina:map(function(s) return s > 10 end)
local canSprint   = store.all({ grounded, staminaOk })   -- boolean AND
-- UI smoothing
local staminaPct  = store.select(stamina, function(s) return s / maxStamina:get() end)
local uiStamina   = store.spring(staminaPct, { stiffness = 300, damping = 28 })
-- Bind (outside store module; shown for context)
ui.bindProgress(StaminaBar, uiStamina)
-- Transactional update (e.g., after taking damage)
store.transaction(function()
  stamina:update(function(s) return math.max(0, s - 18) end)
  grounded:set(false)
end)
-- React in a signal pipeline
canSprint:changed():connect(function(p) print("canSprint:", p.new) end)

⸻

If this matches the depth you want, I can continue with rule next in the same exhaustive format.
