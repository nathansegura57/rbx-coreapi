--!strict

local Connection = require(script.Parent.Parent.Parent.src.Connection)
local ErrorHandler = require(script.Parent.Parent.Parent.src.ErrorHandler)
local Scheduler = require(script.Parent.Parent.Parent.src.Scheduler)
local TestKit = require(script.Parent.Parent.TestKit)

local suite = TestKit.Suite("Scheduler")

suite:AfterEach(function(_ctx)
	Scheduler.ResetDriver()
	ErrorHandler.SetPolicy("Throw")
end)

-- ── Defer ─────────────────────────────────────────────────────────────────────

suite:Test("Defer(fn) schedules fn to run after current stack", function(ctx)
	local ran = false
	Scheduler.Defer(function()
		ran = true
	end)
	ctx:Expect(ran):ToBe(false)
	ctx.Mock:Flush()
	ctx:Expect(ran):ToBe(true)
end)

suite:Test("Defer(nonFunction) throws", function(ctx)
	ctx:Expect(function()
		Scheduler.Defer(42 :: any)
	end):ToThrow("fn must be a function")
end)

suite:Test("Defer callback error routes through ErrorHandler", function(ctx)
	local errors = ctx:CaptureErrors()
	Scheduler.Defer(function()
		error("deferred boom")
	end)
	ctx.Mock:Flush()
	ctx:Expect(errors:HasModule("Scheduler")):ToBe(true)
	ctx:Expect(errors:HasPhase("Defer")):ToBe(true)
	errors:Uninstall()
end)

-- ── Delay ─────────────────────────────────────────────────────────────────────

suite:Test("Delay(seconds, fn) executes fn after the given duration", function(ctx)
	local ran = false
	Scheduler.Delay(1, function()
		ran = true
	end)
	ctx:Expect(ran):ToBe(false)
	ctx.Mock:Advance(0.9)
	ctx:Expect(ran):ToBe(false)
	ctx.Mock:Advance(0.2)
	ctx:Expect(ran):ToBe(true)
end)

suite:Test("Delay(0, fn) is allowed and runs after flush", function(ctx)
	local ran = false
	Scheduler.Delay(0, function()
		ran = true
	end)
	ctx.Mock:Advance(0)
	ctx:Expect(ran):ToBe(true)
end)

suite:Test("Delay negative seconds throws", function(ctx)
	ctx:Expect(function()
		Scheduler.Delay(-1, function() end)
	end):ToThrow("seconds must be non-negative")
end)

suite:Test("Delay NaN seconds throws", function(ctx)
	ctx:Expect(function()
		Scheduler.Delay(0 / 0, function() end)
	end):ToThrow("seconds must be non-negative")
end)

suite:Test("Delay non-function callback throws", function(ctx)
	ctx:Expect(function()
		Scheduler.Delay(1, "not a function" :: any)
	end):ToThrow("fn must be a function")
end)

suite:Test("Delay callback error routes through ErrorHandler", function(ctx)
	local errors = ctx:CaptureErrors()
	Scheduler.Delay(1, function()
		error("delay boom")
	end)
	ctx.Mock:Advance(2)
	ctx:Expect(errors:HasModule("Scheduler")):ToBe(true)
	ctx:Expect(errors:HasPhase("Delay")):ToBe(true)
	errors:Uninstall()
end)

-- ── Cancel ────────────────────────────────────────────────────────────────────

suite:Test("Cancel(nil) is a no-op", function(ctx)
	ctx:Expect(function()
		Scheduler.Cancel(nil)
	end):ToNotThrow()
end)

suite:Test("Cancel(handle) prevents the scheduled callback from running", function(ctx)
	local ran = false
	local handle = Scheduler.Delay(1, function()
		ran = true
	end)
	Scheduler.Cancel(handle)
	ctx.Mock:Advance(2)
	ctx:Expect(ran):ToBe(false)
end)

-- ── Now ───────────────────────────────────────────────────────────────────────

suite:Test("Now() returns current scheduler time", function(ctx)
	ctx:Expect(Scheduler.Now()):ToBe(0)
	ctx.Mock:Advance(5)
	ctx:Expect(Scheduler.Now()):ToBe(5)
end)

suite:Test("Now() driver returning non-number errors directly", function(ctx)
	Scheduler.SetDriver({ Now = function(): any return "not a number" end })
	ctx:Expect(function()
		Scheduler.Now()
	end):ToThrow("driver returned non-number")
end)

suite:Test("Now() driver error routes through ErrorHandler under non-Throw policy", function(ctx)
	ErrorHandler.SetPolicy("Collect")
	Scheduler.SetDriver({ Now = function(): number error("now exploded") end })
	local result = Scheduler.Now()
	ctx:Expect(result):ToBe(0)
	local collected = ErrorHandler.TakeCollected()
	ctx:Expect(#collected):ToBe(1)
	ErrorHandler.SetPolicy("Throw")
end)

-- ── OnStep ────────────────────────────────────────────────────────────────────

suite:Test("OnStep(fn) returns Connection; callback receives dt on each step", function(ctx)
	local received: { number } = {}
	local conn = Scheduler.OnStep(function(dt: number)
		table.insert(received, dt)
	end)
	ctx:Expect(Connection.IsConnection(conn)):ToBe(true)
	ctx.Mock:Step(0.1)
	ctx.Mock:Step(0.2)
	ctx:Expect(#received):ToBe(2)
	ctx:Expect(received[1]):ToBe(0.1)
	ctx:Expect(received[2]):ToBe(0.2)
end)

suite:Test("Disconnecting OnStep connection stops future callbacks", function(ctx)
	local callCount = 0
	local conn = Scheduler.OnStep(function(_dt)
		callCount += 1
	end)
	ctx.Mock:Step(0.1)
	conn:Disconnect()
	ctx.Mock:Step(0.1)
	ctx:Expect(callCount):ToBe(1)
end)

suite:Test("OnStep non-function throws", function(ctx)
	ctx:Expect(function()
		Scheduler.OnStep(42 :: any)
	end):ToThrow("fn must be a function")
end)

suite:Test("OnStep callback error routes through ErrorHandler", function(ctx)
	local errors = ctx:CaptureErrors()
	Scheduler.OnStep(function(_dt)
		error("step boom")
	end)
	ctx.Mock:Step(0.1)
	ctx:Expect(errors:HasPhase("OnStep")):ToBe(true)
	errors:Uninstall()
end)

-- ── SetDriver / ResetDriver ───────────────────────────────────────────────────

suite:Test("SetDriver non-table throws", function(ctx)
	ctx:Expect(function()
		Scheduler.SetDriver("not a table" :: any)
	end):ToThrow("driver must be a table")
end)

suite:Test("SetDriver with non-function field throws", function(ctx)
	ctx:Expect(function()
		Scheduler.SetDriver({ Defer = 123 } :: any)
	end):ToThrow("Defer must be a function or nil")
end)

suite:Test("SetDriver empty table keeps all defaults", function(ctx)
	ctx:Expect(function()
		Scheduler.SetDriver({})
	end):ToNotThrow()
end)

suite:Test("ResetDriver restores default driver behaviour", function(ctx)
	local customNowCalled = false
	Scheduler.SetDriver({ Now = function()
		customNowCalled = true
		return 99
	end })
	ctx:Expect(Scheduler.Now()):ToBe(99)
	Scheduler.ResetDriver()
	-- After reset, Now() goes back to the mock (installed by TestContext).
	ctx:Expect(customNowCalled):ToBe(true)
	ctx:Expect(Scheduler.Now()):ToBe(ctx.Mock:Now())
end)

return suite:Run()
