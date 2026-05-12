--!strict

local Connection = require(script.Parent.Parent.Parent.src.Connection)
local ErrorHandler = require(script.Parent.Parent.Parent.src.ErrorHandler)
local Task = require(script.Parent.Parent.Parent.src.Task)
local TestKit = require(script.Parent.Parent.TestKit)

local suite = TestKit.Suite("Task")

suite:AfterEach(function(_ctx)
	ErrorHandler.SetPolicy("Throw")
	Task.SetTracer(nil)
end)

-- ── Handle model ──────────────────────────────────────────────────────────────

suite:Test("Task handle: getmetatable returns 'Task'", function(ctx)
	local task = Task.Resolved(1)
	ctx:Expect(getmetatable(task :: any)):ToBe("Task")
end)

suite:Test("Task handle: assigning a field errors", function(ctx)
	local task = Task.Resolved(1)
	ctx:Expect(function()
		(task :: any).Field = true
	end):ToThrow("read-only")
end)

suite:Test("Token handle: getmetatable returns 'Token'", function(ctx)
	local task = Task.Resolved(1)
	local token = task:Token()
	ctx:Expect(getmetatable(token :: any)):ToBe("Token")
end)

-- ── Predicates ────────────────────────────────────────────────────────────────

suite:Test("IsTask returns true for task handles", function(ctx)
	local task = Task.Resolved(1)
	ctx:Expect(Task.IsTask(task)):ToBe(true)
end)

suite:Test("IsTask returns false for non-task", function(ctx)
	ctx:Expect(Task.IsTask({})):ToBe(false)
end)

suite:Test("IsToken returns true for token handles", function(ctx)
	local task = Task.Resolved(1)
	ctx:Expect(Task.IsToken(task:Token())):ToBe(true)
end)

suite:Test("IsGroup returns true for group handles", function(ctx)
	local group = Task.Group()
	ctx:Expect(Task.IsGroup(group)):ToBe(true)
end)

-- ── Pre-settled tasks ─────────────────────────────────────────────────────────

suite:Test("Resolved task starts Fulfilled with value", function(ctx)
	local task = Task.Resolved(42)
	ctx:Expect(task:IsFulfilled()):ToBe(true)
	ctx:Expect(task:IsDone()):ToBe(true)
	local ok, value = task:Result()
	ctx:Expect(ok):ToBe(true)
	ctx:Expect(value):ToBe(42)
end)

suite:Test("Rejected task starts Errored", function(ctx)
	local task = Task.Rejected("boom")
	ctx:Expect(task:IsErrored()):ToBe(true)
	local hasErr, errVal = task:Error()
	ctx:Expect(hasErr):ToBe(true)
	ctx:Expect(errVal):ToBe("boom")
end)

suite:Test("Cancelled task starts Cancelled with reason", function(ctx)
	local task = Task.Cancelled("done")
	ctx:Expect(task:IsCancelled()):ToBe(true)
end)

suite:Test("Resolved(nil) preserves nil with presence", function(ctx)
	local task = Task.Resolved(nil)
	local hasResult, value = task:Result()
	ctx:Expect(hasResult):ToBe(true)
	ctx:Expect(value):ToBe(nil)
end)

-- ── Task.Start ────────────────────────────────────────────────────────────────

suite:Test("Start: fn must be a function", function(ctx)
	ctx:Expect(function()
		Task.Start(42 :: any)
	end):ToThrow("fn must be a function")
end)

suite:Test("Start returns Pending task immediately", function(ctx)
	local task = Task.Start(function(_token) return 1 end)
	ctx:Expect(task:IsPending()):ToBe(true)
end)

suite:Test("Start fulfills task after defer flush", function(ctx)
	local task = Task.Start(function(_token) return 99 end)
	ctx.Mock:Flush()
	ctx:Expect(task:IsFulfilled()):ToBe(true)
	local _, value = task:Result()
	ctx:Expect(value):ToBe(99)
end)

suite:Test("Start errors task when fn throws", function(ctx)
	local task = Task.Start(function(_token) error("fn boom") end)
	ctx.Mock:Flush()
	ctx:Expect(task:IsErrored()):ToBe(true)
end)

suite:Test("Start receives token as first arg", function(ctx)
	local receivedToken: any = nil
	local task = Task.Start(function(token)
		receivedToken = token
		return 1
	end)
	ctx.Mock:Flush()
	ctx:Expect(Task.IsToken(receivedToken)):ToBe(true)
	ctx:Expect(task:IsFulfilled()):ToBe(true)
end)

suite:Test("Start with Name option sets task name", function(ctx)
	local task = Task.Start(function(_token) return 1 end, { Name = "MyTask" })
	ctx:Expect(task:Name()):ToBe("MyTask")
end)

-- ── Task.Delay ────────────────────────────────────────────────────────────────

suite:Test("Delay(seconds) fulfills after timer", function(ctx)
	local task = Task.Delay(1)
	ctx:Expect(task:IsPending()):ToBe(true)
	ctx.Mock:Advance(1)
	ctx:Expect(task:IsFulfilled()):ToBe(true)
end)

suite:Test("Delay(seconds, fn) calls fn and fulfills with return", function(ctx)
	local task = Task.Delay(1, function() return "result" end)
	ctx.Mock:Advance(1)
	local _, value = task:Result()
	ctx:Expect(value):ToBe("result")
end)

suite:Test("Delay: negative seconds throws", function(ctx)
	ctx:Expect(function()
		Task.Delay(-1)
	end):ToThrow("seconds must be non-negative")
end)

suite:Test("Delay: NaN seconds throws", function(ctx)
	ctx:Expect(function()
		Task.Delay(0 / 0)
	end):ToThrow("seconds must be non-negative")
end)

suite:Test("Delay task can be cancelled before timer fires", function(ctx)
	local task = Task.Delay(5)
	task:Cancel()
	ctx.Mock:Advance(10)
	ctx:Expect(task:IsCancelled()):ToBe(true)
end)

-- ── task:Cancel ───────────────────────────────────────────────────────────────

suite:Test("Cancel transitions pending task to Cancelled", function(ctx)
	local task = Task.Start(function(_token) return 1 end)
	task:Cancel()
	ctx:Expect(task:IsCancelled()):ToBe(true)
end)

suite:Test("Cancel on terminal task is a no-op", function(ctx)
	local task = Task.Resolved(1)
	ctx:Expect(function()
		task:Cancel()
	end):ToNotThrow()
	ctx:Expect(task:IsFulfilled()):ToBe(true)
end)

suite:Test("Cancel uses default reason 'User'", function(ctx)
	local task = Task.Start(function(_token) return 1 end)
	task:Cancel()
	ctx:Expect(task:Token():Reason()):ToBe(Task.Reason.User)
end)

suite:Test("Cancel with custom reason stores it", function(ctx)
	local task = Task.Start(function(_token) return 1 end)
	task:Cancel("CustomReason")
	ctx:Expect(task:Token():Reason()):ToBe("CustomReason")
end)

-- ── Status predicates ─────────────────────────────────────────────────────────

suite:Test("IsPending true for pending, false after settle", function(ctx)
	local task = Task.Start(function(_token) return 1 end)
	ctx:Expect(task:IsPending()):ToBe(true)
	ctx.Mock:Flush()
	ctx:Expect(task:IsPending()):ToBe(false)
end)

suite:Test("IsDone true for any terminal status", function(ctx)
	ctx:Expect(Task.Resolved(1):IsDone()):ToBe(true)
	ctx:Expect(Task.Rejected("e"):IsDone()):ToBe(true)
	ctx:Expect(Task.Cancelled():IsDone()):ToBe(true)
end)

suite:Test("Status returns correct string", function(ctx)
	ctx:Expect(Task.Resolved(1):Status()):ToBe("Fulfilled")
	ctx:Expect(Task.Rejected("e"):Status()):ToBe("Errored")
	ctx:Expect(Task.Cancelled():Status()):ToBe("Cancelled")
end)

-- ── task:Finally ──────────────────────────────────────────────────────────────

suite:Test("Finally on pending task runs after fulfillment", function(ctx)
	local received: { any } = {}
	local task = Task.Start(function(_token) return 7 end)
	task:Finally(function(status, value)
		table.insert(received, { status, value })
	end)
	ctx.Mock:Flush()
	ctx:Expect(#received):ToBe(1)
	ctx:Expect(received[1][1]):ToBe("Fulfilled")
	ctx:Expect(received[1][2]):ToBe(7)
end)

suite:Test("Finally on terminal task schedules callback via defer", function(ctx)
	local ran = false
	local task = Task.Resolved(1)
	task:Finally(function(_s, _v) ran = true end)
	ctx:Expect(ran):ToBe(false)
	ctx.Mock:Flush()
	ctx:Expect(ran):ToBe(true)
end)

suite:Test("Finally returns same task for chaining", function(ctx)
	local task = Task.Resolved(1)
	local result = task:Finally(function(_s, _v) end)
	ctx:Expect(result):ToBe(task)
end)

suite:Test("Finally: fn must be a function", function(ctx)
	local task = Task.Resolved(1)
	ctx:Expect(function()
		task:Finally(42 :: any)
	end):ToThrow("fn must be a function")
end)

suite:Test("Finally: callback error routes through ErrorHandler", function(ctx)
	local errors = ctx:CaptureErrors()
	local task = Task.Resolved(1)
	task:Finally(function(_s, _v) error("finally boom") end)
	ctx.Mock:Flush()
	ctx:Expect(errors:HasModule("Task")):ToBe(true)
	ctx:Expect(errors:HasPhase("Finally")):ToBe(true)
	errors:Uninstall()
end)

-- ── task:Result / task:Error ──────────────────────────────────────────────────

suite:Test("Result returns (false, nil) for non-Fulfilled task", function(ctx)
	local ok, val = Task.Rejected("e"):Result()
	ctx:Expect(ok):ToBe(false)
	ctx:Expect(val):ToBe(nil)
end)

suite:Test("Error returns (false, nil) for non-Errored task", function(ctx)
	local ok, err = Task.Resolved(1):Error()
	ctx:Expect(ok):ToBe(false)
	ctx:Expect(err):ToBe(nil)
end)

-- ── Token ─────────────────────────────────────────────────────────────────────

suite:Test("Token.Cancelled returns false before cancel", function(ctx)
	local task = Task.Start(function(_token) return 1 end)
	ctx:Expect(task:Token():Cancelled()):ToBe(false)
end)

suite:Test("Token.Cancelled returns true after cancel", function(ctx)
	local task = Task.Start(function(_token) return 1 end)
	task:Cancel()
	ctx:Expect(task:Token():Cancelled()):ToBe(true)
end)

suite:Test("Token.Reason returns nil before cancel", function(ctx)
	local task = Task.Start(function(_token) return 1 end)
	ctx:Expect(task:Token():Reason()):ToBe(nil)
end)

suite:Test("Token.OnCancel fires on cancellation", function(ctx)
	local called = false
	local task = Task.Start(function(_token) return 1 end)
	task:Token():OnCancel(function(_reason) called = true end)
	task:Cancel()
	ctx.Mock:Flush()
	ctx:Expect(called):ToBe(true)
end)

suite:Test("Token.OnCancel on already-cancelled token defers callback", function(ctx)
	local called = false
	local task = Task.Cancelled()
	task:Token():OnCancel(function(_reason) called = true end)
	ctx:Expect(called):ToBe(false)
	ctx.Mock:Flush()
	ctx:Expect(called):ToBe(true)
end)

suite:Test("Token.OnCancel returns disconnected Connection for already-cancelled token", function(ctx)
	local task = Task.Cancelled()
	local conn = task:Token():OnCancel(function(_reason) end)
	ctx:Expect(Connection.IsConnection(conn)):ToBe(true)
	ctx:Expect(conn.Connected):ToBe(false)
end)

suite:Test("Token.OnCancel: disconnecting prevents callback", function(ctx)
	local called = false
	local task = Task.Start(function(_token) return 1 end)
	local conn = task:Token():OnCancel(function(_reason) called = true end)
	conn:Disconnect()
	task:Cancel()
	ctx.Mock:Flush()
	ctx:Expect(called):ToBe(false)
end)

-- ── Task.Timeout ──────────────────────────────────────────────────────────────

suite:Test("Timeout mirrors fulfilled inner task", function(ctx)
	local inner = Task.Start(function(_token) return "inner result" end)
	local outer = Task.Timeout(inner, 5)
	ctx.Mock:Flush()
	ctx:Expect(outer:IsFulfilled()):ToBe(true)
	local _, value = outer:Result()
	ctx:Expect(value):ToBe("inner result")
end)

suite:Test("Timeout cancels inner and becomes Cancelled when timer fires first", function(ctx)
	local inner = Task.Start(function(token)
		while not token:Cancelled() do end
		return nil
	end)
	local outer = Task.Timeout(inner, 1)
	ctx.Mock:Advance(1)
	ctx.Mock:Flush()
	ctx:Expect(outer:IsCancelled()):ToBe(true)
end)

suite:Test("Timeout: seconds must be positive", function(ctx)
	local inner = Task.Resolved(1)
	ctx:Expect(function()
		Task.Timeout(inner, 0)
	end):ToThrow("seconds must be positive")
end)

-- ── Task.All ─────────────────────────────────────────────────────────────────

suite:Test("All fulfills with array of results when all succeed", function(ctx)
	local t1 = Task.Resolved(1)
	local t2 = Task.Resolved(2)
	local all = Task.All({ t1, t2 })
	ctx.Mock:Flush()
	ctx:Expect(all:IsFulfilled()):ToBe(true)
	local _, results = all:Result()
	ctx:Expect((results :: any)[1]):ToBe(1)
	ctx:Expect((results :: any)[2]):ToBe(2)
end)

suite:Test("All errors when any child errors", function(ctx)
	local t1 = Task.Resolved(1)
	local t2 = Task.Rejected("boom")
	local all = Task.All({ t1, t2 })
	ctx.Mock:Flush()
	ctx:Expect(all:IsErrored()):ToBe(true)
end)

suite:Test("All: empty array throws", function(ctx)
	ctx:Expect(function()
		Task.All({})
	end):ToThrow("non-empty dense array")
end)

-- ── Task.Race ─────────────────────────────────────────────────────────────────

suite:Test("Race mirrors first settled task", function(ctx)
	local t1 = Task.Resolved("first")
	local t2 = Task.Resolved("second")
	local race = Task.Race({ t1, t2 })
	ctx.Mock:Flush()
	ctx:Expect(race:IsFulfilled()):ToBe(true)
end)

-- ── Task.Any ──────────────────────────────────────────────────────────────────

suite:Test("Any fulfills on first successful task even if others failed", function(ctx)
	local t1 = Task.Rejected("bad")
	local t2 = Task.Resolved("good")
	local any = Task.Any({ t1, t2 })
	ctx.Mock:Flush()
	ctx:Expect(any:IsFulfilled()):ToBe(true)
	local _, value = any:Result()
	ctx:Expect(value):ToBe("good")
end)

suite:Test("Any errors with all failures when all tasks fail", function(ctx)
	local t1 = Task.Rejected("e1")
	local t2 = Task.Rejected("e2")
	local any = Task.Any({ t1, t2 })
	ctx.Mock:Flush()
	ctx:Expect(any:IsErrored()):ToBe(true)
end)

-- ── Task.AllSettled ───────────────────────────────────────────────────────────

suite:Test("AllSettled fulfills with results for all tasks regardless of status", function(ctx)
	local t1 = Task.Resolved("ok")
	local t2 = Task.Rejected("err")
	local t3 = Task.Cancelled("reason")
	local settled = Task.AllSettled({ t1, t2, t3 })
	ctx.Mock:Flush()
	ctx:Expect(settled:IsFulfilled()):ToBe(true)
	local _, results = settled:Result()
	ctx:Expect(#(results :: any)):ToBe(3)
	ctx:Expect((results :: any)[1].Status):ToBe("Fulfilled")
	ctx:Expect((results :: any)[2].Status):ToBe("Errored")
	ctx:Expect((results :: any)[3].Status):ToBe("Cancelled")
end)

-- ── Task.Retry ────────────────────────────────────────────────────────────────

suite:Test("Retry succeeds on first attempt", function(ctx)
	local task = Task.Retry(function(_token) return Task.Resolved("done") end, {
		Count = 3, Backoff = "Fixed", Base = 0,
	})
	ctx.Mock:Flush()
	ctx:Expect(task:IsFulfilled()):ToBe(true)
	local _, value = task:Result()
	ctx:Expect(value):ToBe("done")
end)

suite:Test("Retry retries up to Count times on error", function(ctx)
	local attempts = 0
	local task = Task.Retry(function(_token)
		attempts += 1
		return Task.Rejected("nope")
	end, { Count = 3, Backoff = "Fixed", Base = 0 })
	ctx.Mock:Flush()
	ctx:Expect(task:IsErrored()):ToBe(true)
	ctx:Expect(attempts):ToBe(3)
end)

suite:Test("Retry: Count must be positive integer", function(ctx)
	ctx:Expect(function()
		Task.Retry(function(_token) return Task.Resolved(1) end, {
			Count = 0, Backoff = "Fixed", Base = 0,
		})
	end):ToThrow("Count must be a positive integer")
end)

suite:Test("Retry: Base NaN throws", function(ctx)
	ctx:Expect(function()
		Task.Retry(function(_token) return Task.Resolved(1) end, {
			Count = 1, Backoff = "Fixed", Base = 0 / 0,
		})
	end):ToThrow("Base must be >= 0")
end)

-- ── Group ─────────────────────────────────────────────────────────────────────

suite:Test("Group.Size tracks pending task count", function(ctx)
	local group = Task.Group()
	ctx:Expect(group:Size()):ToBe(0)
	local t = Task.Start(function(_token) return 1 end)
	group:Add(t)
	ctx:Expect(group:Size()):ToBe(1)
	ctx.Mock:Flush()
	ctx:Expect(group:Size()):ToBe(0)
end)

suite:Test("Group.Start starts task and tracks it", function(ctx)
	local group = Task.Group()
	local task = group:Start(function(_token) return 42 end)
	ctx:Expect(group:Size()):ToBe(1)
	ctx:Expect(Task.IsTask(task)):ToBe(true)
end)

suite:Test("Group.CancelAll cancels all pending tasks", function(ctx)
	local group = Task.Group()
	local t1 = group:Start(function(_token) return 1 end)
	local t2 = group:Start(function(_token) return 2 end)
	group:CancelAll()
	ctx:Expect(t1:IsCancelled()):ToBe(true)
	ctx:Expect(t2:IsCancelled()):ToBe(true)
end)

suite:Test("Group.JoinAll fulfills when all tasks settle", function(ctx)
	local group = Task.Group()
	local t1 = group:Start(function(_token) return 1 end)
	local t2 = group:Start(function(_token) return 2 end)
	local joined = group:JoinAll()
	ctx:Expect(joined:IsPending()):ToBe(true)
	ctx.Mock:Flush()
	ctx:Expect(joined:IsFulfilled()):ToBe(true)
	ctx:Expect(t1:IsFulfilled()):ToBe(true)
	ctx:Expect(t2:IsFulfilled()):ToBe(true)
end)

suite:Test("Group.Destroy cancels all pending and marks destroyed", function(ctx)
	local group = Task.Group()
	local task = group:Start(function(_token) return 1 end)
	group:Destroy()
	ctx:Expect(task:IsCancelled()):ToBe(true)
	ctx:Expect(function()
		group:Start(function(_token) return 1 end)
	end):ToThrow("group is destroyed")
end)

suite:Test("Group.Name returns the configured name", function(ctx)
	local group = Task.Group({ Name = "MyGroup" })
	ctx:Expect(group:Name()):ToBe("MyGroup")
end)

-- ── Task.SetTracer ────────────────────────────────────────────────────────────

suite:Test("SetTracer installs tracer that receives Start and Done events", function(ctx)
	local traces = ctx:CaptureTraces(function(setTracer)
		Task.SetTracer(setTracer)
	end)
	local task = Task.Start(function(_token) return 1 end)
	ctx.Mock:Flush()
	local starts = traces:EventsNamed("Start")
	local dones = traces:EventsNamed("Done")
	ctx:Expect(#starts):ToBe(1)
	ctx:Expect(#dones):ToBe(1)
	traces:Uninstall()
	ctx:Expect(task:IsFulfilled()):ToBe(true)
end)

suite:Test("SetTracer: tracer error routes through ErrorHandler", function(ctx)
	local errors = ctx:CaptureErrors()
	Task.SetTracer(function(_event) error("tracer boom") end)
	local task = Task.Start(function(_token) return 1 end)
	ctx.Mock:Flush()
	ctx:Expect(errors:HasModule("Task")):ToBe(true)
	ctx:Expect(errors:HasPhase("Trace")):ToBe(true)
	errors:Uninstall()
	Task.SetTracer(nil)
	ctx:Expect(task:IsFulfilled()):ToBe(true)
end)

suite:Test("SetTracer(nil) removes tracer", function(ctx)
	local callCount = 0
	Task.SetTracer(function(_event) callCount += 1 end)
	Task.SetTracer(nil)
	local task = Task.Start(function(_token) return 1 end)
	ctx.Mock:Flush()
	ctx:Expect(callCount):ToBe(0)
	ctx:Expect(task:IsFulfilled()):ToBe(true)
end)

-- ── Task.Reason constants ─────────────────────────────────────────────────────

suite:Test("Reason table contains expected constants", function(ctx)
	ctx:Expect(Task.Reason.ModeExit):ToBe("ModeExit")
	ctx:Expect(Task.Reason.GuardFalse):ToBe("GuardFalse")
	ctx:Expect(Task.Reason.Superseded):ToBe("Superseded")
	ctx:Expect(Task.Reason.Timeout):ToBe("Timeout")
	ctx:Expect(Task.Reason.User):ToBe("User")
	ctx:Expect(Task.Reason.Shutdown):ToBe("Shutdown")
	ctx:Expect(Task.Reason.Capacity):ToBe("Capacity")
end)

-- ── Pathological coverage ────────────────────────────────────────────────────

suite:Test("Delay callback errors settle the task as Errored", function(ctx)
	local task = Task.Delay(1, function()
		error("delay callback failed")
	end)
	ctx.Mock:Advance(1)
	ctx:Expect(task:IsErrored()):ToBe(true)
	local hasError, err = task:Error()
	ctx:Expect(hasError):ToBe(true)
	ctx:Expect(tostring(err)):ToMatch("delay callback failed")
end)

suite:Test("Await can be cancelled by an external token without settling awaited task", function(ctx)
	local awaited = Task.Delay(10)
	local canceller = Task.Start(function(_token)
		return "driver"
	end)
	local awaitOk: boolean? = nil
	local awaitReason: any = nil
	local thread = coroutine.create(function()
		awaitOk, awaitReason = awaited:Await(canceller:Token())
	end)
	coroutine.resume(thread)
	canceller:Cancel("StopWaiting")
	ctx.Mock:Flush()
	ctx:Expect(awaitOk):ToBe(false)
	ctx:Expect(awaitReason):ToBe("StopWaiting")
	ctx:Expect(awaited:IsPending()):ToBe(true)
end)

suite:Test("Unwrap throws the stored error for rejected tasks", function(ctx)
	local task = Task.Rejected("stored failure")
	ctx:Expect(function()
		task:Unwrap()
	end):ToThrow("stored failure")
end)

suite:Test("AllSettled records fulfilled nil values by status", function(ctx)
	local combined = Task.AllSettled({
		Task.Resolved(nil),
		Task.Rejected("bad"),
		Task.Cancelled("done"),
	})
	ctx.Mock:Flush()
	local ok, result = combined:Result()
	ctx:Expect(ok):ToBe(true)
	ctx:Expect(result[1].Status):ToBe(Task.Status.Fulfilled)
	ctx:Expect(result[1].Value):ToBe(nil)
	ctx:Expect(result[2].Status):ToBe(Task.Status.Errored)
	ctx:Expect(result[2].Error):ToBe("bad")
	ctx:Expect(result[3].Status):ToBe(Task.Status.Cancelled)
	ctx:Expect(result[3].Reason):ToBe("done")
end)

suite:Test("Group.Add ignores terminal tasks and preserves zero Size", function(ctx)
	local group = Task.Group()
	group:Add(Task.Resolved(1))
	group:Add(Task.Rejected("e"))
	group:Add(Task.Cancelled("c"))
	ctx:Expect(group:Size()):ToBe(0)
end)

return suite:Run()
