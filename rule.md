Awesome—here’s the full spec for the rule module, in the same style as sig and store. Still no implementations—only purpose, conceptual use cases, pseudocode examples, parameters, and return semantics for every method/field.

Conventions:

* Signal<T> is from sig.
* RStore<T> / WStore<T> / DStore<T> are from store.
* Task, TaskGroup, Token are from task.
* “Scope” means the thing that owns/activates the rule (often an FSM mode, but could be a global scope object).
* Notifications/effects run in deterministic phases (documented in your engine; examples assume “end-of-frame” effect scheduling).

⸻

What is rule?

rule expresses a single declarative reaction in your game:

When a Signal fires, if a guard (store or predicate) is true, do an effect (sync or Task), under certain policies (priority, cooldown, concurrency, retries, cancellation, tracing). Attach the rule to a scope so it auto-enables/disables with that scope’s lifecycle.

This lets you keep input/UI/AI/gameplay logic as small, testable, self-contained “reaction units.”

⸻

Core Types

type Rule

* Purpose: A configured reaction (on/if/do/policy) bound to a scope.
* Conceptual use case: “On OpenMenu input, if canOpenMenu, switch FSM mode to Inventory.”
* Key instance methods:
    * on(sig: Signal<any>): Rule
    * if(guard: RStore<boolean> | (ctx, payload?) -> boolean): Rule
    * do(effect: (ctx, payload, tools) -> (nil | Task | ()->())): Rule
    * policy(opts: RulePolicy): Rule
    * attach(scope: any): Rule
    * enable(): Rule
    * disable(): Rule
    * dispose(): ()
    * name(): string?

Why these returns? Every method returns the same Rule to enable fluent chaining. dispose() returns nothing because ownership & cleanup are driven by the scope (and you want explicit calls in tests).

⸻

type RulePolicy

* Purpose: Fine-tune how events are admitted, ordered, and executed.
* Fields (all optional):
    * priority: integer — higher runs earlier within the same frame.
    * cooldown: number — minimum seconds between accepted events.
    * debounce: number — delay while events keep arriving; run only the last.
    * throttle: number — emit at most once per window (with implied trailing).
    * once: boolean — auto-disable after first successful effect start.
    * recheckBeforeEffect: boolean — evaluate guard again immediately before running effect.
    * cancelIfGuardFlips: boolean — cancel in-flight Task if guard becomes false.
    * concurrency: "merge" | "switch" | "exhaust" | "concat" — strategy for overlapping events:
        * merge: start every event (up to capacity), run concurrently.
        * switch: cancel current Task, start the new one (Rx “switchMap”).
        * exhaust: ignore events while a Task is running (Rx “exhaustMap”).
        * concat: queue events and run one after another.
    * capacity: integer — max concurrent tasks (only for "merge").
    * queue: "drop" | "latest" | "fifo" — behavior when at capacity (or for "concat" buffer overflow).
    * errors: "propagate" | "swallow" | "retry" — error handling mode.
    * retry: { count: integer, backoff: "fixed" | "expo", base: number, jitter?: number } — retry recipe when errors="retry".
    * trace: boolean — enable dev tracing for this rule (timeline logging).
    * tag: string — name override for inspector/traces.
    * admitPhase: "immediate" | "endOfFrame" — when to admit events (default engine policy is fine; keep override for tools).

Why? Games need explicit control over bursty inputs, long-running effects, cancellations on state changes, and reliable determinism for replays.

⸻

Instance API (complete)

rule(name: string) -> Rule

* Purpose: Construct a rule builder with a debug name.
* Conceptual use case: Unique label for tracing and deterministic ordering.
* Example:

local r = rule("UI.OpenInventory")

* Params:
    * name: human-friendly label (also used for inspector & tie-breakers).
* Returns: a disabled Rule; it won’t listen or run until attached/enabled.

⸻

Rule:on(sig: Signal<any>): Rule

* Purpose: Declare the trigger for this rule.
* Conceptual use case: Key press, swipe, network reply, timer tick.
* Example:

rule("OpenInventory")
  :on(inputs.alias("OpenMenu"))

* Params:
    * sig: any Signal<T> (payload type becomes your effect’s payload).
* Returns: same Rule (for chaining).
* Notes: Chain once per rule; if you need multiple sources, pass a merged signal (sig.merge(a,b,...)) or build a separate rule per source.

⸻

Rule:if(guard: RStore<boolean> | (ctx, payload?) -> boolean): Rule

* Purpose: Provide the guard—the rule only runs when it’s true.
* Conceptual use case: Can only open menu if not in cutscene; can only sprint if stamina > 10.
* Example:

:if(canOpenMenu)     -- store<boolean>
-- or
:if(function(ctx) return ctx.player:IsGrounded() end)

* Params:
    * guard: either a boolean store or a pure predicate function.
* Returns: same Rule.
* Notes:
    * Guard is checked at admission time.
    * If policy.recheckBeforeEffect=true, it’s checked again right before the effect starts.
    * If policy.cancelIfGuardFlips=true, the running Task is cancelled when the guard later turns false.

⸻

Rule:do(effect: (ctx, payload, tools) -> (nil | Task | ()->())): Rule

* Purpose: Declare the effect to run when admitted.
* Conceptual use case: Switch FSM mode, start an animation, fire an ability, request to server and show UI on reply.
* Example (sync):

:do(function(ctx) ctx.sm:switch("Inventory") end)

* Example (Task):

:do(function(ctx, payload)
  return task.start(function(tok)
    anim.tween(Panel, {GroupTransparency=0}, {time=0.2}):await(tok)
  end, {name="OpenPanel"})
end)

* Example (disposer):

:do(function(ctx)
  ui.attachTooltip(Button)
  return function() ui.detachTooltip(Button) end
end)

* Params:
    * ctx: context object from scope (FSM or app root; your choice).
    * payload: data from the Signal event.
    * tools: optional helpers injected by the engine (e.g., { start=task.start, now=clock.now, emit=sigEmit }).
* Returns:
    * nil for synchronous quick effects,
    * Task if it’s long-running/awaitable/cancellable,
    * () -> () disposer to run when rule is disabled or scope exits.
* Why: These three cover all lifecycles you need—instant actions, cancellable jobs, and reversible one-off mounts.

⸻

Rule:policy(opts: RulePolicy): Rule

* Purpose: Configure admission, execution, concurrency, and error behavior.
* Conceptual use case:
    * “Open once every 0.2s” (cooldown).
    * “Cancel previous cast if user recasts” (concurrency="switch").
    * “Ignore spam while busy” (concurrency="exhaust").
    * “Retry RPC up to 3 times with exponential backoff” (errors="retry").
* Example:

:policy({
  priority = 10,
  cooldown = 0.2,
  recheckBeforeEffect = true,
  cancelIfGuardFlips = true,
  concurrency = "switch",
  errors = "retry",
  retry = { count = 3, backoff = "expo", base = 0.5, jitter = 0.1 },
  trace = true,
  tag = "UI.Open",
})

* Params:
    * opts: see RulePolicy above.
* Returns: same Rule.

⸻

Rule:attach(scope: any): Rule

* Purpose: Bind the rule to a lifecycle (e.g., an FSM mode).
* Conceptual use case: The rule auto-enables when mode enters, auto-disables on exit, and any running Task is cancelled.
* Example:

rule("CloseInventory")
  :on(inputs.alias("Back"))
  :do(function() sm:switch("Exploration") end)
  :attach(sm.mode("Inventory"))

* Params:
    * scope: an object that supports your engine’s rule lifecycle hooks (e.g., ModeHandle).
* Returns: same Rule.
* Notes:
    * Attaching doesn’t immediately enable if the scope isn’t active yet.
    * Disposers/Tasks are cleaned up automatically when the scope deactivates.

⸻

Rule:enable(): Rule

* Purpose: Manually enable the rule (for global rules or test harnesses).
* Use case: A rule not tied to FSM but active during the whole session.
* Example:

rule("AutoSave"):on(timers.Every60s):do(saveProfile):enable()

* Returns: same Rule.

⸻

Rule:disable(): Rule

* Purpose: Manually disable (but keep configuration; can re-enable).
* Use case: Temporarily suspend a rule during a cutscene.
* Returns: same Rule.

⸻

Rule:dispose(): ()

* Purpose: Permanently tear down the rule; disconnects listeners, cancels Tasks, runs disposer if any.
* Use case: During teardown or test cleanup.

⸻

Rule:name(): string?

* Purpose: Retrieve the configured name (or tag) for tooling.

⸻

Behavior & Scheduling (guarantees)

* Admission phase: When the Signal fires, the rule considers: cooldown/debounce/throttle → guard → concurrency/capacity.
* Effect scheduling: Accepted events are queued to the engine’s effect phase (e.g., end-of-frame) unless admitPhase="immediate".
* Ordering: Within the same frame and scope:
    1. priority (higher first),
    2. creation order (earlier first),
    3. name/tag lexicographic (tie-breaker).
* Recheck: If recheckBeforeEffect, the guard is evaluated again right before the effect runs. If it fails, the effect is skipped.
* Cancellation:
    * Scope exit → running Tasks for rules in that scope receive Token.cancel("ModeExit").
    * concurrency="switch" → cancel previous Task with reason "Superseded".
    * cancelIfGuardFlips → cancel with reason "GuardFlipped".
    * task.timeout(...) or retries → cancel with "Timeout" if exceeded.
* Errors:
    * errors="propagate" → surface to engine error handler (crash guard/inspector).
    * errors="swallow" → record and continue.
    * errors="retry" → apply retry recipe around the effect (if it yields/throws).

⸻

Conceptual Patterns (with examples)

1) Simple mode switch (cooldown + recheck)

rule("OpenInventory")
  :on(inputs.alias("OpenMenu"))
  :if(canOpenMenu)                          -- RStore<boolean>
  :do(function(ctx) ctx.sm:switch("Inventory") end)
  :policy({ cooldown = 0.2, recheckBeforeEffect = true })
  :attach(sm.mode("Exploration"))

Why these params/returns:

* Cooldown: prevents double-open if the input device repeats.
* Recheck: if something changed (e.g., cutscene started) between admission and effect, skip cleanly.

⸻

2) Long action that cancels on re-cast (switch)

rule("ChargeAttack")
  :on(inputs.Key.hold(Enum.KeyCode.MouseButton1, 0.6))
  :if(player.canAct)
  :do(function(ctx)
    return abilities.cast(ctx.actor, "Charged")  -- returns Task
  end)
  :policy({
    concurrency = "switch",           -- latest wins
    cancelIfGuardFlips = true,        -- stop if player can’t act anymore
  })
  :attach(sm.mode("Combat"))

Why:

* Returning a Task lets the rule manage cancellation on mode exit or new events.
* switch matches “latest command wins” UX.

⸻

3) Ignore while busy (exhaust)

rule("TalkToNPC")
  :on(inputs.alias("Interact"))
  :if(player.nearNPC)
  :do(function(ctx, payload)
    return dialogue.play(ctx, payload.npc)      -- Task
  end)
  :policy({ concurrency = "exhaust" })          -- ignore spam taps during dialogue
  :attach(sm.mode("Exploration"))

⸻

4) Queue sequentially (concat)

rule("CraftQueue")
  :on(ui.Craft.onClick)                         -- Signal<CraftRequest>
  :if(inWorkshop)
  :do(function(ctx, req) return crafting.perform(req) end)  -- Task
  :policy({ concurrency = "concat", queue = "fifo" })
  :attach(sm.mode("Workshop"))

⸻

5) Retry an RPC with exponential backoff

rule("GachaPull")
  :on(ui.Pull10.onClick)
  :do(function(ctx)
    return task.chain(function(tok)
      local ok, res = net.gacha.pull(ctx.user, 10):await(tok)
      if not ok then error(res) end
      ui.showResults(res)
    end)
  end)
  :policy({
    errors = "retry",
    retry = { count = 3, backoff = "expo", base = 0.4, jitter = 0.25 },
  })
  :attach(globalScope)

⸻

6) Disposable mount

rule("HoverHint")
  :on(ui.Button.onHover)
  :do(function()
    ui.mountHint("Press E to interact")
    return function() ui.unmountHint() end       -- disposer runs when rule disables/scope exits
  end)
  :attach(sm.mode("Exploration"))

⸻

Parameter/Return Rationale (why these shapes?)

* Signal in on(...): unifies everything (input, UI, timers, net) as events—composable with sig.
* Guard as Store<boolean> or predicate: allows both reactive guards (auto-cancel when flipping) and quick predicate checks.
* Effect returning Task | nil | disposer: covers long-running work (with explicit cancellation), one-shot side effects, and reversible mounts—all with a single contract.
* RulePolicy knobs: gameplay needs control over spamming, concurrency semantics, and reliability (retries); exposing these avoids bespoke per-rule plumbing.
* Attach/enable/disable/dispose: precise lifecycle control aligned to FSM modes or global scopes; essential for predictable teardown.

⸻

Diagnostics & Tooling Hooks

* Tracing: if policy.trace=true, the engine emits a timeline:
    * Rule.Admit(name, payloadSummary)
    * Rule.Skip(name, reason) (cooldown, guard false, capacity, etc.)
    * Rule.Start(name, taskId?)
    * Rule.Cancel(name, reason)
    * Rule.Error(name, err)
    * Rule.Done(name)
* Metrics API (optional): rule.metrics(rule) → { runs, skipped, errors, avgMs }.
* Inspector: shows active rules per scope, policies, last payload, last error, tasks in-flight.

⸻

End-to-End Mini Scenario

-- Context & FSM
local ctx = { player = player, services = { ... }, sm = sm }
local Explore = sm.mode("Exploration")
-- Open inventory
rule("OpenInv"):on(inputs.alias("OpenMenu"))
  :if(canOpenMenu)
  :do(function(ctx) ctx.sm:switch("Inventory") end)
  :policy({ cooldown=0.2, recheckBeforeEffect=true })
  :attach(Explore)
-- Sprint hold (cancel if stamina drops)
rule("SprintHold"):on(inputs.alias("SprintHold"))
  :if(canSprint)                                   -- store<bool>
  :do(function(ctx)
    move.sprint(ctx.player, true)
    return task.start(function(tok)
      sig.timer.after(8):await(tok)                -- hard cap 8s
    end)
  end)
  :policy({ cancelIfGuardFlips = true, concurrency = "switch" })
  :attach(Explore)
-- Back action works in multiple modes (attach twice)
rule("Back"):on(inputs.alias("Back"))
  :do(function(ctx) ctx.sm:switch("Exploration") end)
  :attach(sm.mode("Inventory"))
  :attach(sm.mode("Settings"))

⸻

If this matches the depth you want, I can move on to fsm next, in the same exhaustive, spec-first style.
