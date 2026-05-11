--!strict

local ErrorHandler = require(script.Parent.Parent.Parent.src.ErrorHandler)
local Rule = require(script.Parent.Parent.Parent.src.Rule)
local Signal = require(script.Parent.Parent.Parent.src.Signal)
local Store = require(script.Parent.Parent.Parent.src.Store)
local Task = require(script.Parent.Parent.Parent.src.Task)
local TestKit = require(script.Parent.Parent.TestKit)

local suite = TestKit.Suite("Rule")

suite:AfterEach(function(_ctx)
	ErrorHandler.SetPolicy("Throw")
	Rule.SetTracer(nil)
end)

-- ── Handle model ──────────────────────────────────────────────────────────────

suite:Test("Rule handle: getmetatable returns 'Rule'", function(ctx)
	local rule = Rule.New("test")
	ctx:Expect(getmetatable(rule :: any)):ToBe("Rule")
end)

suite:Test("Rule handle: assigning a field errors", function(ctx)
	local rule = Rule.New("test")
	ctx:Expect(function()
		(rule :: any).Field = true
	end):ToThrow("read-only")
end)

-- ── Rule.New ──────────────────────────────────────────────────────────────────

suite:Test("Rule.New creates a disabled non-destroyed rule", function(ctx)
	local rule = Rule.New("MyRule")
	ctx:Expect(rule:IsEnabled()):ToBe(false)
	ctx:Expect(rule:IsDestroyed()):ToBe(false)
end)

suite:Test("Rule.New: empty name throws", function(ctx)
	ctx:Expect(function()
		Rule.New("")
	end):ToThrow("name must be a non-empty string")
end)

suite:Test("Rule.New: non-string name throws", function(ctx)
	ctx:Expect(function()
		Rule.New(42 :: any)
	end):ToThrow("name must be a non-empty string")
end)

-- ── Rule.IsRule ───────────────────────────────────────────────────────────────

suite:Test("IsRule returns true for rule handles", function(ctx)
	local rule = Rule.New("r")
	ctx:Expect(Rule.IsRule(rule)):ToBe(true)
end)

suite:Test("IsRule returns false for non-rules", function(ctx)
	ctx:Expect(Rule.IsRule({})):ToBe(false)
	ctx:Expect(Rule.IsRule(nil)):ToBe(false)
end)

-- ── Rule.DefaultPolicy ────────────────────────────────────────────────────────

suite:Test("DefaultPolicy returns expected defaults", function(ctx)
	local policy = Rule.DefaultPolicy()
	ctx:Expect((policy :: any).Concurrency):ToBe("Exhaust")
	ctx:Expect((policy :: any).Schedule):ToBe("Deferred")
	ctx:Expect((policy :: any).Once):ToBe(false)
end)

-- ── Rule.ValidatePolicy ───────────────────────────────────────────────────────

suite:Test("ValidatePolicy returns (true, nil) for valid policy", function(ctx)
	local ok, msg = Rule.ValidatePolicy({ Concurrency = "Merge" })
	ctx:Expect(ok):ToBe(true)
	ctx:Expect(msg):ToBe(nil)
end)

suite:Test("ValidatePolicy returns (false, message) for unknown key", function(ctx)
	local ok, msg = Rule.ValidatePolicy({ UnknownField = true } :: any)
	ctx:Expect(ok):ToBe(false)
	ctx:Expect(msg):ToSatisfy(function(m) return type(m) == "string" end)
end)

suite:Test("ValidatePolicy returns (false, message) for invalid Concurrency", function(ctx)
	local ok, _ = Rule.ValidatePolicy({ Concurrency = "Parallel" } :: any)
	ctx:Expect(ok):ToBe(false)
end)

suite:Test("ValidatePolicy: Merge concurrency requires Overflow=Drop", function(ctx)
	local ok, _ = Rule.ValidatePolicy({ Concurrency = "Merge", Overflow = "Fifo" })
	ctx:Expect(ok):ToBe(false)
end)

suite:Test("ValidatePolicy: Throttle must be > 0", function(ctx)
	local ok, _ = Rule.ValidatePolicy({ Throttle = 0 })
	ctx:Expect(ok):ToBe(false)
end)

-- ── Configuration methods ─────────────────────────────────────────────────────

suite:Test("On sets signal; cannot configure while enabled", function(ctx)
	local sig = Signal.New()
	local rule = Rule.New("r")
	ctx:Expect(function()
		rule:On(sig)
	end):ToNotThrow()
	rule:On(sig):Run(function(_ctx, _payload, _frame) end):Enable()
	ctx:Expect(function()
		rule:On(Signal.New())
	end):ToThrow("cannot configure while enabled")
	rule:Disable()
	sig:Destroy()
end)

suite:Test("On: dead signal throws", function(ctx)
	local sig = Signal.New()
	sig:Destroy()
	local rule = Rule.New("r")
	ctx:Expect(function()
		rule:On(sig)
	end):ToThrow("signal must be a live Signal")
end)

suite:Test("When: non-Store non-function throws", function(ctx)
	local rule = Rule.New("r")
	ctx:Expect(function()
		rule:When(42 :: any)
	end):ToThrow("guard must be a Store or function")
end)

suite:Test("Run: non-function throws", function(ctx)
	local rule = Rule.New("r")
	ctx:Expect(function()
		rule:Run(42 :: any)
	end):ToThrow("effect must be a function")
end)

suite:Test("Policy: unknown key throws", function(ctx)
	local rule = Rule.New("r")
	ctx:Expect(function()
		rule:Policy({ UnknownKey = true } :: any)
	end):ToThrow("unknown policy key")
end)

-- ── Enable / Disable ──────────────────────────────────────────────────────────

suite:Test("Enable: requires signal and effect", function(ctx)
	local rule = Rule.New("r")
	ctx:Expect(function()
		rule:Enable()
	end):ToThrow("signal is not configured")
	local sig = Signal.New()
	rule:On(sig)
	ctx:Expect(function()
		rule:Enable()
	end):ToThrow("effect is not configured")
	sig:Destroy()
end)

suite:Test("Enable marks rule enabled and returns same rule", function(ctx)
	local sig = Signal.New()
	local rule = Rule.New("r")
	rule:On(sig):Run(function(_c, _p, _f) end)
	local result = rule:Enable()
	ctx:Expect(rule:IsEnabled()):ToBe(true)
	ctx:Expect(result):ToBe(rule)
	rule:Disable()
	sig:Destroy()
end)

suite:Test("Disable marks rule disabled", function(ctx)
	local sig = Signal.New()
	local rule = Rule.New("r")
	rule:On(sig):Run(function(_c, _p, _f) end):Enable()
	rule:Disable()
	ctx:Expect(rule:IsEnabled()):ToBe(false)
	sig:Destroy()
end)

suite:Test("Enable is ref-counted", function(ctx)
	local sig = Signal.New()
	local rule = Rule.New("r")
	rule:On(sig):Run(function(_c, _p, _f) end)
	rule:Enable()
	rule:Enable()
	rule:Disable()
	ctx:Expect(rule:IsEnabled()):ToBe(true)
	rule:Disable()
	ctx:Expect(rule:IsEnabled()):ToBe(false)
	sig:Destroy()
end)

-- ── Destroy ───────────────────────────────────────────────────────────────────

suite:Test("Destroy marks rule destroyed", function(ctx)
	local rule = Rule.New("r")
	rule:Destroy()
	ctx:Expect(rule:IsDestroyed()):ToBe(true)
end)

suite:Test("Destroy is idempotent", function(ctx)
	local rule = Rule.New("r")
	rule:Destroy()
	ctx:Expect(function()
		rule:Destroy()
	end):ToNotThrow()
end)

-- ── Effect execution ──────────────────────────────────────────────────────────

suite:Test("Effect runs when signal fires", function(ctx)
	local ran = false
	local sig = Signal.New()
	local rule = Rule.New("r")
	rule:On(sig):Run(function(_c, _p, _f) ran = true end):Enable()
	sig:Fire(nil)
	ctx.Mock:Flush()
	ctx:Expect(ran):ToBe(true)
	rule:Disable()
	sig:Destroy()
end)

suite:Test("Effect receives payload", function(ctx)
	local received: any = "sentinel"
	local sig = Signal.New()
	local rule = Rule.New("r")
	rule:On(sig):Run(function(_c, payload, _f) received = payload end):Enable()
	sig:Fire("hello")
	ctx.Mock:Flush()
	ctx:Expect(received):ToBe("hello")
	rule:Disable()
	sig:Destroy()
end)

suite:Test("Effect does not run when rule is disabled", function(ctx)
	local ran = false
	local sig = Signal.New()
	local rule = Rule.New("r")
	rule:On(sig):Run(function(_c, _p, _f) ran = true end):Enable():Disable()
	sig:Fire(nil)
	ctx.Mock:Flush()
	ctx:Expect(ran):ToBe(false)
	sig:Destroy()
end)

-- ── Metrics ───────────────────────────────────────────────────────────────────

suite:Test("Metrics.Runs increments on each effect run", function(ctx)
	local sig = Signal.New()
	local rule = Rule.New("r")
	rule:On(sig):Run(function(_c, _p, _f) end):Enable()
	sig:Fire(nil)
	sig:Fire(nil)
	ctx.Mock:Flush()
	ctx:Expect(rule:Metrics().Runs):ToBe(2)
	rule:Disable()
	sig:Destroy()
end)

suite:Test("Metrics.Skipped increments when guard fails", function(ctx)
	local sig = Signal.New()
	local rule = Rule.New("r")
	rule:On(sig):When(function(_c, _p, _f) return false end):Run(function(_c, _p, _f) end):Enable()
	sig:Fire(nil)
	ctx.Mock:Flush()
	ctx:Expect(rule:Metrics().Skipped):ToBe(1)
	rule:Disable()
	sig:Destroy()
end)

suite:Test("Metrics.Errors increments on effect error", function(ctx)
	ErrorHandler.SetPolicy("Swallow")
	local sig = Signal.New()
	local rule = Rule.New("r")
	rule:On(sig):Run(function(_c, _p, _f) error("effect boom") end):Enable()
	sig:Fire(nil)
	ctx.Mock:Flush()
	ctx:Expect(rule:Metrics().Errors):ToBe(1)
	rule:Disable()
	sig:Destroy()
end)

suite:Test("ResetMetrics zeros all counters", function(ctx)
	local sig = Signal.New()
	local rule = Rule.New("r")
	rule:On(sig):Run(function(_c, _p, _f) end):Enable()
	sig:Fire(nil)
	ctx.Mock:Flush()
	rule:ResetMetrics()
	local metrics = rule:Metrics()
	ctx:Expect(metrics.Runs):ToBe(0)
	ctx:Expect(metrics.Skipped):ToBe(0)
	ctx:Expect(metrics.Errors):ToBe(0)
	rule:Disable()
	sig:Destroy()
end)

-- ── Guard ─────────────────────────────────────────────────────────────────────

suite:Test("Function guard: truthy non-true does not pass", function(ctx)
	local ran = false
	local sig = Signal.New()
	local rule = Rule.New("r")
	rule:On(sig):When(function(_c, _p, _f) return 1 :: any end):Run(function(_c, _p, _f) ran = true end):Enable()
	sig:Fire(nil)
	ctx.Mock:Flush()
	ctx:Expect(ran):ToBe(false)
	rule:Disable()
	sig:Destroy()
end)

suite:Test("Store guard: passes when store value is true", function(ctx)
	local ran = false
	local guardStore = Store.Value(true)
	local sig = Signal.New()
	local rule = Rule.New("r")
	rule:On(sig):When(guardStore):Run(function(_c, _p, _f) ran = true end):Enable()
	sig:Fire(nil)
	ctx.Mock:Flush()
	ctx:Expect(ran):ToBe(true)
	rule:Disable()
	sig:Destroy()
	guardStore:Destroy()
end)

suite:Test("Store guard: blocks when store value is false", function(ctx)
	local ran = false
	local guardStore = Store.Value(false)
	local sig = Signal.New()
	local rule = Rule.New("r")
	rule:On(sig):When(guardStore):Run(function(_c, _p, _f) ran = true end):Enable()
	sig:Fire(nil)
	ctx.Mock:Flush()
	ctx:Expect(ran):ToBe(false)
	rule:Disable()
	sig:Destroy()
	guardStore:Destroy()
end)

-- ── ErrorPolicy ───────────────────────────────────────────────────────────────

suite:Test("ErrorPolicy=Swallow silently ignores effect errors", function(ctx)
	local sig = Signal.New()
	local rule = Rule.New("r")
	rule:On(sig):Policy({ ErrorPolicy = "Swallow" }):Run(function(_c, _p, _f) error("boom") end):Enable()
	ctx:Expect(function()
		sig:Fire(nil)
		ctx.Mock:Flush()
	end):ToNotThrow()
	rule:Disable()
	sig:Destroy()
end)

suite:Test("ErrorPolicy=Collect accumulates errors in Metrics.CollectedErrors", function(ctx)
	local sig = Signal.New()
	local rule = Rule.New("r")
	rule:On(sig):Policy({ ErrorPolicy = "Collect", Schedule = "Immediate" }):Run(function(_c, _p, _f)
		error("collected error")
	end):Enable()
	sig:Fire(nil)
	local collected = rule:Metrics().CollectedErrors
	ctx:Expect(#collected):ToBe(1)
	rule:Disable()
	sig:Destroy()
end)

suite:Test("ErrorPolicy=nil delegates to global ErrorHandler", function(ctx)
	local errors = ctx:CaptureErrors()
	local sig = Signal.New()
	local rule = Rule.New("r")
	rule:On(sig):Run(function(_c, _p, _f) error("global error") end):Enable()
	sig:Fire(nil)
	ctx.Mock:Flush()
	ctx:Expect(errors:HasModule("Rule")):ToBe(true)
	ctx:Expect(errors:HasPhase("Effect")):ToBe(true)
	errors:Uninstall()
	rule:Disable()
	sig:Destroy()
end)

-- ── Concurrency: Exhaust ──────────────────────────────────────────────────────

suite:Test("Exhaust: skips while task in flight", function(ctx)
	local runCount = 0
	local sig = Signal.New()
	local rule = Rule.New("r")
	rule:On(sig)
		:Policy({ Schedule = "Immediate" })
		:Run(function(_c, _p, _f)
			runCount += 1
			return Task.Delay(10)
		end)
		:Enable()
	sig:Fire(nil)
	sig:Fire(nil)
	ctx:Expect(runCount):ToBe(1)
	ctx:Expect(rule:Metrics().Skipped):ToBe(1)
	rule:Disable()
	sig:Destroy()
end)

-- ── Concurrency: Switch ───────────────────────────────────────────────────────

suite:Test("Switch: cancels in-flight task on new signal", function(ctx)
	local firstTask: any = nil
	local sig = Signal.New()
	local rule = Rule.New("r")
	rule:On(sig)
		:Policy({ Concurrency = "Switch", Schedule = "Immediate" })
		:Run(function(_c, _p, _f)
			local t = Task.Delay(10)
			if firstTask == nil then firstTask = t end
			return t
		end)
		:Enable()
	sig:Fire(nil)
	sig:Fire(nil)
	ctx:Expect(firstTask:IsCancelled()):ToBe(true)
	rule:Disable()
	sig:Destroy()
end)

-- ── Debounce ──────────────────────────────────────────────────────────────────

suite:Test("Debounce delays effect until quiet period", function(ctx)
	local ran = false
	local sig = Signal.New()
	local rule = Rule.New("r")
	rule:On(sig):Policy({ Debounce = 1 }):Run(function(_c, _p, _f) ran = true end):Enable()
	sig:Fire(nil)
	sig:Fire(nil)
	ctx:Expect(ran):ToBe(false)
	ctx.Mock:Advance(1)
	ctx.Mock:Flush()
	ctx:Expect(ran):ToBe(true)
	ctx:Expect(rule:Metrics().Runs):ToBe(1)
	rule:Disable()
	sig:Destroy()
end)

-- ── Throttle ──────────────────────────────────────────────────────────────────

suite:Test("Throttle leading: fires immediately then blocks", function(ctx)
	local runCount = 0
	local sig = Signal.New()
	local rule = Rule.New("r")
	rule:On(sig):Policy({ Throttle = 1, Trailing = false }):Run(function(_c, _p, _f) runCount += 1 end):Enable()
	sig:Fire(nil)
	sig:Fire(nil)
	ctx.Mock:Flush()
	ctx:Expect(runCount):ToBe(1)
	rule:Disable()
	sig:Destroy()
end)

-- ── Cooldown ──────────────────────────────────────────────────────────────────

suite:Test("Cooldown skips events within the window", function(ctx)
	local runCount = 0
	local sig = Signal.New()
	local rule = Rule.New("r")
	rule:On(sig)
		:Policy({ Cooldown = 1, Schedule = "Immediate" })
		:Run(function(_c, _p, _f) runCount += 1 end)
		:Enable()
	sig:Fire(nil)
	sig:Fire(nil)
	ctx:Expect(runCount):ToBe(1)
	ctx:Expect(rule:Metrics().Skipped):ToBe(1)
	ctx.Mock:Advance(1)
	sig:Fire(nil)
	ctx:Expect(runCount):ToBe(2)
	rule:Disable()
	sig:Destroy()
end)

-- ── Once ──────────────────────────────────────────────────────────────────────

suite:Test("Once disables rule after first run", function(ctx)
	local runCount = 0
	local sig = Signal.New()
	local rule = Rule.New("r")
	rule:On(sig):Policy({ Once = true }):Run(function(_c, _p, _f) runCount += 1 end):Enable()
	sig:Fire(nil)
	ctx.Mock:Flush()
	sig:Fire(nil)
	ctx.Mock:Flush()
	ctx:Expect(runCount):ToBe(1)
	ctx:Expect(rule:IsEnabled()):ToBe(false)
	sig:Destroy()
end)

-- ── Disposer ──────────────────────────────────────────────────────────────────

suite:Test("Disposer returned from effect runs on next effect start", function(ctx)
	local disposerRan = false
	local sig = Signal.New()
	local rule = Rule.New("r")
	local effectCount = 0
	rule:On(sig):Policy({ Schedule = "Immediate" }):Run(function(_c, _p, _f)
		effectCount += 1
		if effectCount == 1 then
			return function()
				disposerRan = true
			end
		end
		return nil
	end):Enable()
	sig:Fire(nil)
	ctx:Expect(disposerRan):ToBe(false)
	sig:Fire(nil)
	ctx:Expect(disposerRan):ToBe(true)
	rule:Disable()
	sig:Destroy()
end)

-- ── Rule.Name ─────────────────────────────────────────────────────────────────

suite:Test("Name returns constructor name by default", function(ctx)
	local rule = Rule.New("MyRule")
	ctx:Expect(rule:Name()):ToBe("MyRule")
end)

suite:Test("Name returns Tag when set in policy", function(ctx)
	local rule = Rule.New("MyRule")
	rule:Policy({ Tag = "TaggedName" })
	ctx:Expect(rule:Name()):ToBe("TaggedName")
end)

-- ── SetTracer ─────────────────────────────────────────────────────────────────

suite:Test("SetTracer installs tracer receiving Rule.Enable and Rule.Disable", function(ctx)
	local traces = ctx:CaptureTraces(function(setTracer)
		Rule.SetTracer(setTracer)
	end)
	local sig = Signal.New()
	local rule = Rule.New("r")
	rule:On(sig):Run(function(_c, _p, _f) end):Enable():Disable()
	local enables = traces:EventsNamed("Rule.Enable")
	local disables = traces:EventsNamed("Rule.Disable")
	ctx:Expect(#enables):ToBe(1)
	ctx:Expect(#disables):ToBe(1)
	traces:Uninstall()
	sig:Destroy()
end)

return suite:Run()
