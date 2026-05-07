Awesome—here’s the full spec for the task module, matching the depth/style of sig, store, and fsm/rule. Still no implementations—this is contracts, rationale, and usage pseudocode only.

Conventions:

* Task, TaskGroup, and Token are the core async primitives.
* Tasks are cancellable async jobs (often implemented with coroutines + a scheduler).
* The engine has a deterministic scheduler (frame/heartbeat phases). Exact phase names are up to your runtime, but examples assume a standard “end-of-frame” effect phase.
* Tasks integrate with rule (for concurrency policies) and fsm (mode-scoped cancellation).

⸻

What is task?

A unified, cancellable async layer that:

* Starts jobs (task.start, task.chain) that can yield/await and cancel.
* Wraps jobs with timeouts and retries.
* Manages sets of jobs via TaskGroups (auto-cancel on FSM mode exit).
* Provides Tokens to propagate cancellation into your job code.
* Offers helpers for delays, scheduling, races, and joining.

⸻

Core Types (shapes, not code)

type Token

* Purpose: Cancellation signal + reason propagation into running jobs.
* Instance API:
    * cancelled(): boolean — true if cancellation requested.
    * reason(): string? — human-readable reason (e.g., "ModeExit", "Timeout").
    * onCancel(fn: (reason?: string) -> ()): Conn — subscribe to cancellation.
* Conceptual use case: Inside a long loop, periodically check token.cancelled() to bail early.

Why: Gives the job control over graceful shutdown, and allows the engine to cancel uniformly.

⸻

type Task

* Purpose: Handle representing a running (or completed) async job.
* Instance API:
    * token(): Token — the task’s token.
    * cancel(reason?: string): () — request cancellation (idempotent).
    * status(): "pending" | "fulfilled" | "cancelled" | "error" — current state.
    * finally(fn: (status, err?) -> ()): Task — register a completion handler.
    * result<T>(): T? (optional for your impl) — last successful value (if any).
    * error(): any? (optional) — last error (if any).
    * name(): string? — debug label.

Why: You can cancel, observe completion, and inspect state in tools/tests.

⸻

type TaskGroup

* Purpose: Aggregate and control multiple tasks as a unit.
* Instance API:
    * add(t: Task): TaskGroup — attach an existing task.
    * start(fn, opts?): Task — start a task directly into this group.
    * cancelAll(reason?: string): ()
    * joinAll(): Task — a Task that completes when all current tasks complete.
    * race(): Task — completes when any current task completes (mirrors Promise.race).
    * size(): number — number of active tasks.
    * name(): string? — label for inspector.

Why: FSM modes own a group so everything under that mode cancels on exit.

⸻

Cancellation Reasons (recommended)

Use canonical strings so logs/inspector are consistent:

* "ModeExit" — FSM mode ended.
* "GuardFlipped" — a rule guard turned false.
* "Superseded" — concurrency policy switched to a new job.
* "Timeout" — wrapper cancelled after deadline.
* "User" — explicit user action cancel.
* "Shutdown" — app teardown.
* "Capacity" — dropped due to capacity/queue policy.

⸻

Scheduler Concepts

* Phases: Your engine has a driving clock. Common phases:
    * Frame / Heartbeat / Stepped ticks.
    * An effect phase where rule effects and task continuations run.
* Consistency: All task continuations should run on a documented phase (e.g., end-of-frame). This keeps determinism with rules/stores.

⸻

Creation & Control (static API)

task.start(fn: (token: Token) -> (any?), opts?: { name?: string, scheduler?: "Frame" | "Heartbeat" | "Stepped" | any }) -> Task

* Purpose: Start a cancellable async job.
* Conceptual use case: Play an animation, stream assets, poll a server, run a cutscene.
* Example:

local t = task.start(function(tok)
  -- stream until done or cancelled
  while not tok.cancelled() do
    stream:step()              -- may yield internally
    -- cooperative check
  end
  -- optional cleanup on cancel: tok:onCancel(...)
end, { name = "StreamChunk" })

* Params:
    * fn(token): your job; yield/await as needed; check token.
    * opts.name: debug label.
    * opts.scheduler: which run loop phase to schedule continuations on (optional).
* Returns: Task—you can cancel, finally, and inspect status.
* Why these shapes: Token allows cooperative cancellation; scheduler enables tests or special pipelines.

⸻

task.chain(fn: (token: Token) -> (any?)) -> Task

* Purpose: Syntactic sugar for “start a job that’s a sequence of awaits”, often used in rule:do(...).
* Conceptual use case: “Call network → await → update UI → await animation → done”.
* Example:

return task.chain(function(tok)
  local ok, res = net.fetchProfile(userId):await(tok)
  if not ok then error(res) end
  ui.Profile.show(res)
  anim.tween(Panel, {GroupTransparency=0}, {time=0.2}):await(tok)
end)

* Params:
    * fn(token) as above.
* Returns: Task.
* Why: Compact authoring for linear flows.

⸻

task.timeout(inner: Task | (() -> Task), seconds: number, reason?: string) -> Task

* Purpose: Cancel a task if it doesn’t finish in time.
* Conceptual use case: Guard network requests; prevent stuck transitions.
* Example:

local guarded = task.timeout(function()
  return net.loadDungeon(dungeonId)
end, 5.0, "Timeout:LoadDungeon")

* Params:
    * inner: existing Task or a thunk to create it (so the timeout owns it).
    * seconds: deadline.
    * reason: cancellation reason label (defaults to "Timeout").
* Returns: Task that resolves/cancels/error depending on inner + timeout.
* Why: Centralized deadline enforcement; emits a consistent reason.

⸻

task.retry(makeTask: (token: Token) -> (any?), opts: { count: integer, backoff: "fixed" | "expo", base: number, jitter?: number }) -> Task

* Purpose: Run a job; on error, retry with backoff.
* Conceptual use case: Flaky RPCs, content fetches.
* Example:

local t = task.retry(function(tok)
  return net.gacha.pull(userId, 10):await(tok)
end, { count = 3, backoff = "expo", base = 0.4, jitter = 0.25 })

* Params:
    * makeTask(token): job body (may error/throw or return error tuple—your wrapper decides).
    * opts.count: max retries.
    * opts.backoff: "fixed" or "expo".
    * opts.base: base delay seconds.
    * opts.jitter (optional): randomize delay to prevent thundering herds.
* Returns: Task that succeeds or ends in error/cancelled.
* Why: Encapsulates a common resilience pattern with auditable parameters.

⸻

task.delay(seconds: number, fn?: () -> ()) -> Task

* Purpose: Fire a callback after delay, cancellably; or serve as a sleep primitive (await it).
* Conceptual use case: Small UI delays, timers inside chain flows.
* Example:

-- sleep
task.delay(0.2):finally(function() print("waited") end)
-- or with callback
task.delay(1.0, function() sfx:Play("Ding") end)

* Params:
    * seconds: time to wait.
    * fn (optional): callback to run at the end.
* Returns: Task that cancels with reason "Timeout" or "User" (implementation-defined).
* Why: Ubiquitous building block; pairs well with await(tok) inside chains.

⸻

task.scheduler(phase: "Frame" | "Heartbeat" | "Stepped" | any) -> ()

* Purpose: Globally set the default continuation phase (advanced/testing).
* Conceptual use case: In tests, switch to a deterministic fake scheduler.
* Params:
    * phase: which loop to bind to.
* Returns: ().

⸻

Group Management

task.group(opts?: { name?: string }) -> TaskGroup

* Purpose: Create a container to manage many tasks.
* Conceptual use case: FSM Mode owns one; also handy for “projectile system jobs”.
* Example:

local g = task.group({ name = "ExplorationGroup" })
local t1 = g:start(streamAmbientAudio)
local t2 = g:start(trackNearbyEntities)

* Params:
    * name (optional): debug label.
* Returns: TaskGroup.

⸻

TaskGroup:add(t: Task) -> TaskGroup

* Purpose: Attach an existing Task to the group.
* Use case: When a rule returns a Task, the FSM Mode may add() it explicitly (usually done automatically by Mode:add semantics).
* Example: Explore:taskGroup():add(t)

⸻

TaskGroup:start(fn, opts?) -> Task

* Purpose: Start a new Task that is automatically scoped to the group.
* Example:

local g = Explore:taskGroup()
g:start(function(tok)
  while not tok.cancelled() do
    scanArea()
    task.delay(0.5):await(tok)
  end
end, { name = "Scanner" })

⸻

TaskGroup:cancelAll(reason?: string) -> ()

* Purpose: Cancel every active task in the group.
* Conceptual use case: On FSM mode exit, stop everything at once.
* Example: Explore:taskGroup():cancelAll("ModeExit")

⸻

TaskGroup:joinAll() -> Task

* Purpose: A Task that resolves when all current tasks finish (new tasks after calling are not included—document this).
* Use case: Tools that need to “await stabilization” before snapshotting.
* Example:

local settle = Explore:taskGroup():joinAll()
settle:finally(function() print("Exploration quiescent") end)

⸻

TaskGroup:race() -> Task

* Purpose: A Task that completes when any task in the group finishes (first finisher).
* Use case: Whichever stream (cache/network) returns first unlocks UI; others can be cancelled or continue—your policy.
* Example: Explore:taskGroup():race():finally(...)

⸻

TaskGroup:size() -> number / TaskGroup:name() -> string?

* Purpose: Introspection for HUDs/tools.

⸻

Additional Utilities (optional but recommended)

task.all(tasks: { Task }) -> Task

* Purpose: Complete when all given tasks succeed/cancel (choose your semantics on error—fail fast vs gather).
* Use case: Preload multiple bundles before enabling a scene.

task.any(tasks: { Task }) -> Task

* Purpose: Complete when any given task completes (mirror of race() without a group).

task.wrapRBX(signal: RBXScriptSignal, until?: RBXScriptSignal) -> Task

* Purpose: Turn “fires once” RBX event into a Task (e.g., ContentProvider:PreloadAsync callback model scenarios).
* Use case: Await a specific event in a chain.

(These can be omitted if you prefer keeping the surface minimal; sig already covers most event conversions.)

⸻

Interop with rule and fsm

* rule:do(...) may return a Task. The rule will:
    * Apply concurrency policy (merge/switch/exhaust/concat).
    * Cancel tasks when guard flips (if cancelIfGuardFlips).
    * Cancel tasks on scope exit with reason "ModeExit".
* fsm Modes own a TaskGroup; onEnter/onExit returning a Task or disposer participates in the mode group automatically.

⸻

Usage Patterns (pseudocode)

1) Animation timeline guarded by timeout

local OpenPanel = task.timeout(function()
  return task.chain(function(tok)
    anim.tween(Panel, {GroupTransparency=0}, {time=0.18}):await(tok)
    anim.tween(Panel, {Size=UDim2.fromScale(1,1)}, {time=0.12}):await(tok)
  end)
end, 0.5, "OpenPanelTimeout")

2) Streaming loop with cooperative cancellation

local StreamVFX = task.start(function(tok)
  while not tok.cancelled() do
    vfx:tick()                  -- advances emitters
    -- yield to next frame (implementation decides: delay(0) or scheduler frame await)
    task.delay(0):await(tok)
  end
end, { name = "VFXStream" })

3) Retrying RPC with exponential backoff and jitter

local Pull10 = task.retry(function(tok)
  local ok, res = net.gacha.pull(userId, 10):await(tok)
  if not ok then error(res) end
  return res
end, { count = 3, backoff = "expo", base = 0.4, jitter = 0.25 })

4) Group-scoped tasks in an FSM mode

Explore:onEnter(function(ctx)
  local g = Explore:taskGroup()
  g:start(trackMinimap, { name = "Minimap" })
  g:start(streamAmbience, { name = "Ambience" })
end)
Explore:onExit(function()
  Explore:taskGroup():cancelAll("ModeExit")
end)

5) Rule effect using switch concurrency

rule("AimPreview")
  :on(inputs.Mouse.move)
  :do(function(ctx, delta)
    return task.start(function(tok)
      -- compute expensive aim preview
      local pre = physics:raycastPreview(ctx.player, delta):await(tok)
      ui.AimPreview:render(pre)
    end, { name = "AimPreview" })
  end)
  :policy({ concurrency = "switch" })   -- cancel previous preview job on new move
  :attach(sm.mode("Combat"))

⸻

Parameter/Return Rationale

* fn(token): Cooperative cancellation is explicit and predictable; jobs can clean up and exit deterministically.
* Task handle: Needed to cancel, observe, and aggregate (groups, races, joins).
* timeout/retry: These cross-cutting concerns shouldn’t be re-implemented per feature; centralizing them produces consistent logs and behavior.
* TaskGroup: Matches real game lifecycles (modes, scenes, systems). “Cancel everything now” is a first-class operation, not ad-hoc.
* delay: Ubiquitous building block for pacing flows and cooperative sleeps.

⸻

Diagnostics & Inspector Hooks

* Each Task should emit lifecycle breadcrumbs (if dev tracing enabled):
    * Task.Start(name, id)
    * Task.Cancel(name, id, reason)
    * Task.Error(name, id, err)
    * Task.Done(name, id)
* TaskGroup shows:
    * Active tasks (names/ids),
    * Count,
    * Last cancel reason,
    * Longest-running task.
* Integrate with rule/fsm traces so you can see: Rule.Start -> Task.Start -> (Cancel: GuardFlipped) -> Task.Cancel.

⸻

Minimal End-to-End (with rule and fsm)

local Explore = sm:mode("Exploration")
-- Smooth camera task, cancelled on exit
Explore:onEnter(function(ctx)
  return task.start(function(tok)
    while not tok.cancelled() do
      camera:updateSmoothing()
      task.delay(0):await(tok)
    end
  end, { name = "CamSmooth" })
end)
-- Fire an ability with timeout and switch policy
rule("ChargeShot")
  :on(inputs.Key.hold(Enum.KeyCode.MouseButton1, 0.6))
  :do(function(ctx)
    local cast = task.timeout(function()
      return abilities.cast(ctx.actor, "ChargeShot")
    end, 3.0, "ChargeTimeout")
    return cast
  end)
  :policy({ concurrency = "switch", cancelIfGuardFlips = true })
  :attach(Explore)
sm:start("Exploration")

⸻

That’s the complete task spec.
If you’d like, I can now provide a one-page Engine Contracts Recap (sig/store/rule/fsm/task) or move on to stubbing module headers (empty functions/types) you can paste into Studio to start TDD’ing implementations against this spec.
