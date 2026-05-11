# CoreAPI

A Luau kernel library for Roblox providing reactive, event-driven primitives. CoreAPI gives you composable building blocks — signals, stores, tasks, rules, and finite state machines — that wire together cleanly and handle errors uniformly.

## Modules

| Module | Purpose |
|--------|---------|
| [ErrorHandler](ErrorHandler.md) | Global error routing policy (throw / warn / swallow / collect) |
| [Connection](Connection.md) | Opaque subscription handle returned by `Connect` and `Subscribe` |
| [Scheduler](Scheduler.md) | Time and frame-scheduling abstraction; injectable for testing |
| [Context](Context.md) | Hierarchical dependency-injection container |
| [Signal](Signal.md) | Reactive event stream with 20+ composable operators |
| [Store](Store.md) | Reactive state cell with derived stores and history |
| [Task](Task.md) | Structured async tasks with cancellation tokens |
| [Rule](Rule.md) | Declarative event-driven effect runner with concurrency policy |
| [FSM](FSM.md) | Hierarchical finite state machine with guards, providers, and rules |

## Installation

Copy `src/` into your Roblox project. Each module is a plain `ModuleScript`. Adjust the `require` paths in each file to match your project structure (the default assumes siblings under `script.Parent`).

## Quick Start

```luau
local Signal     = require(path.to.Signal)
local Store      = require(path.to.Store)
local Task       = require(path.to.Task)
local ErrorHandler = require(path.to.ErrorHandler)

-- Route all callback errors to a warn instead of throwing.
ErrorHandler.SetPolicy(ErrorHandler.Policy.Warn)

-- A reactive counter.
local count = Store.Value(0)

-- A signal that fires when something interesting happens.
local onAction = Signal.New()

-- React to the signal.
onAction:Connect(function(payload)
    count:Set(count:Get() + 1)
    print("Action fired:", payload, "total:", count:Get())
end)

-- Fire it.
onAction:Fire("hello")  -- prints: Action fired: hello  total: 1
onAction:Fire("world")  -- prints: Action fired: world  total: 2
```

## Complete Example — A Simple Game Loop

This example ties together every module. It models a game that progresses through `idle → loading → playing → gameover` states, uses a reactive store for the score, runs a background async loading task, and cleans everything up on destroy.

```luau
local Context      = require(path.to.Context)
local ErrorHandler = require(path.to.ErrorHandler)
local FSM          = require(path.to.FSM)
local Rule         = require(path.to.Rule)
local Signal       = require(path.to.Signal)
local Store        = require(path.to.Store)
local Task         = require(path.to.Task)

-- ── 1. Configure error handling ─────────────────────────────────────────────
-- Warn on errors from listeners/callbacks so the game never hard-crashes.
ErrorHandler.SetPolicy(ErrorHandler.Policy.Warn)

-- ── 2. Create shared signals and stores ─────────────────────────────────────
local onEnemyKilled = Signal.New()
local score         = Store.Value(0)
local highScore     = Store.Value(0)

-- ── 3. Create the context the FSM and rules will share ──────────────────────
local gameContext = Context.Root({
    Score    = score,
    HighScore = highScore,
})

-- ── 4. Build the FSM ─────────────────────────────────────────────────────────
local game = FSM.New(gameContext, {
    SingleSwitchPerFrame = true,
    CancelTasksOnExit    = true,
})

-- Idle mode: waiting for the player to press start.
local idle = game:Mode("idle")
idle:OnEnter(function(ctx, frame)
    print("Game idle. Press start!")
    -- Reset score each time we return to idle.
    score:Set(0)
end)

-- Loading mode: simulate async asset loading.
local loading = game:Mode("loading")
loading:OnEnter(function(ctx, frame)
    print("Loading…")
    -- Return a Task — the FSM's task group tracks it.
    return Task.Start(function(token)
        local ok = Task.Sleep(2, token)  -- 2-second simulated load
        if not ok then return end        -- cancelled during load
        print("Load complete!")
        game:Switch("playing")
    end)
end)
loading:Guard("idle", function(ctx, frame)
    -- If loading is taking too long (>5s), fall back to idle.
    return frame.StartedAt ~= nil and (os.clock() - frame.StartedAt) > 5
end, { Defer = true })

-- Playing mode: score accumulates.
local playing = game:Mode("playing")
playing:OnEnter(function(ctx, frame)
    print("Game started! Defeat enemies!")
end)
playing:OnExit(function(ctx, frame)
    -- Update high score when leaving the playing state.
    local current = score:Get()
    if current > highScore:Get() then
        highScore:Set(current)
    end
    print("Final score:", current, "| High score:", highScore:Get())
end)

-- Game-over mode.
local gameover = game:Mode("gameover")
gameover:OnEnter(function(ctx, frame)
    print("Game over! Reason:", frame.Reason)
end)
gameover:Guard("idle", Store.Value(false))  -- placeholder; replaced by timer

-- ── 5. Attach a Rule that responds to enemy kills while playing ──────────────
local killRule = Rule.New("ScoreOnKill")
    :On(onEnemyKilled)
    :Run(function(ctx, payload, frame)
        local points = payload.Points or 10
        score:Set(score:Get() + points)
        print("Kill! +" .. points .. "  Score:", score:Get())
        if score:Get() >= 100 then
            game:Switch("gameover", { Reason = "Score limit reached" })
        end
    end)
    :Policy({ Concurrency = Rule.Concurrency.Merge })

-- Attach to the playing mode so it's enabled/disabled automatically.
playing:Add(killRule)

-- ── 6. Start the FSM ─────────────────────────────────────────────────────────
game:Start("idle")

-- ── 7. Drive the game ────────────────────────────────────────────────────────
game:Switch("loading")          -- kicks off the 2-second load

-- (In a real game the scheduler would advance time; here we illustrate intent.)
-- After loading completes automatically, playing begins.

onEnemyKilled:Fire({ Points = 50 })   -- Score: 50
onEnemyKilled:Fire({ Points = 60 })   -- Score: 110 → triggers gameover

-- ── 8. Subscribe to score changes ───────────────────────────────────────────
local scoreConn = score:Subscribe(function(newScore, oldScore)
    -- fires immediately with current value, then on every change
    print(string.format("Score changed: %d → %d", oldScore or 0, newScore))
end)

-- ── 9. Cleanup ───────────────────────────────────────────────────────────────
-- Disconnecting a connection from the outside.
scoreConn:Disconnect()

-- Destroying the FSM exits all active modes and cancels all tasks.
game:Destroy()
-- The FSM destroys its stores, signal, and runs OnExit for active modes.
```

## Error Handling

CoreAPI uses a single global error-routing policy set via `ErrorHandler.SetPolicy`. All callback errors (listeners, subscribers, guards, effects, etc.) flow through `ErrorHandler.Report` and obey this policy.

```luau
local ErrorHandler = require(path.to.ErrorHandler)

-- During development: throw so you see errors immediately.
ErrorHandler.SetPolicy(ErrorHandler.Policy.Throw)   -- default

-- In production: warn so the game keeps running.
ErrorHandler.SetPolicy(ErrorHandler.Policy.Warn)

-- Collect errors for later inspection (useful in tests).
ErrorHandler.SetPolicy(ErrorHandler.Policy.Collect)
local errors = ErrorHandler.TakeCollected()

-- Attach a custom reporter (e.g. send to a logging service).
ErrorHandler.SetReporter(function(info)
    print(string.format("[%s.%s] %s", info.Module, info.Phase, tostring(info.Error)))
end)
```

## Testing

Every module that touches time uses `Scheduler` exclusively. Tests replace the driver with `MockScheduler` to control time and flush deferred callbacks synchronously:

```luau
local Scheduler   = require(path.to.Scheduler)
local TestKit     = require(path.to.tests.TestKit)

local suite = TestKit.Suite("My tests")

suite:Test("score increments on kill", function(ctx)
    ctx.Mock:Flush()   -- flush any deferred setup callbacks

    onEnemyKilled:Fire({ Points = 10 })
    ctx.Mock:Flush()   -- drain the deferred queue

    ctx:Expect(score:Get()):ToBe(10)
end)

local report = suite:Run()
```

See [Scheduler](Scheduler.md) for the full driver API.
