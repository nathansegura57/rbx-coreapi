--!strict

local ErrorHandler = require(script.Parent.Parent.Parent.src.ErrorHandler)
local TestKit = require(script.Parent.Parent.TestKit)

local suite = TestKit.Suite("ErrorHandler")

-- Helper: reset to Throw policy and clear reporter after each test.
suite:AfterEach(function(_ctx)
	ErrorHandler.SetPolicy("Throw")
	ErrorHandler.SetReporter(nil)
	ErrorHandler.TakeCollected()
end)

-- ── Policy ────────────────────────────────────────────────────────────────────

suite:Test("default policy is Throw", function(ctx)
	ctx:Expect(ErrorHandler.GetPolicy()):ToBe("Throw")
end)

suite:Test("SetPolicy changes active policy", function(ctx)
	ErrorHandler.SetPolicy("Warn")
	ctx:Expect(ErrorHandler.GetPolicy()):ToBe("Warn")
	ErrorHandler.SetPolicy("Swallow")
	ctx:Expect(ErrorHandler.GetPolicy()):ToBe("Swallow")
	ErrorHandler.SetPolicy("Collect")
	ctx:Expect(ErrorHandler.GetPolicy()):ToBe("Collect")
end)

suite:Test("SetPolicy with invalid value throws", function(ctx)
	ctx:Expect(function()
		ErrorHandler.SetPolicy("Invalid" :: any)
	end):ToThrow("invalid policy 'Invalid'")
end)

-- ── Report validation ─────────────────────────────────────────────────────────

suite:Test("Report non-table throws", function(ctx)
	ctx:Expect(function()
		ErrorHandler.Report("oops" :: any)
	end):ToThrow("info must be a table")
end)

suite:Test("Report missing Phase throws", function(ctx)
	ctx:Expect(function()
		ErrorHandler.Report({ Module = "X", Error = "e" } :: any)
	end):ToThrow("Phase must be a string")
end)

suite:Test("Report missing Module throws", function(ctx)
	ctx:Expect(function()
		ErrorHandler.Report({ Phase = "P", Error = "e" } :: any)
	end):ToThrow("Module must be a string")
end)

suite:Test("Report absent Error key throws", function(ctx)
	ctx:Expect(function()
		ErrorHandler.Report({ Module = "X", Phase = "P" } :: any)
	end):ToThrow("Error is required")
end)

suite:Test("Report with Error = nil is valid (nil is a legitimate error value)", function(ctx)
	ErrorHandler.SetPolicy("Collect")
	ctx:Expect(function()
		ErrorHandler.Report({ Module = "X", Phase = "P", Error = nil })
	end):ToNotThrow()
	local collected = ErrorHandler.TakeCollected()
	ctx:Expect(#collected):ToBe(1)
end)

suite:Test("Report non-string Name throws", function(ctx)
	ctx:Expect(function()
		ErrorHandler.Report({ Module = "X", Phase = "P", Error = "e", Name = 123 } :: any)
	end):ToThrow("Name must be a string or nil")
end)

suite:Test("Report non-string Message throws", function(ctx)
	ctx:Expect(function()
		ErrorHandler.Report({ Module = "X", Phase = "P", Error = "e", Message = true } :: any)
	end):ToThrow("Message must be a string or nil")
end)

-- ── Policy behaviour ──────────────────────────────────────────────────────────

suite:Test("Throw policy: Report raises formatted error", function(ctx)
	ErrorHandler.SetPolicy("Throw")
	ctx:Expect(function()
		ErrorHandler.Report({ Module = "Mod", Phase = "Phase", Error = "bad thing" })
	end):ToThrow("Mod.Phase: bad thing")
end)

suite:Test("Throw policy with Name: Report raises error with Name in message", function(ctx)
	ErrorHandler.SetPolicy("Throw")
	ctx:Expect(function()
		ErrorHandler.Report({ Module = "Mod", Phase = "Phase", Name = "myName", Error = "bad" })
	end):ToThrow("Mod.Phase[myName]: bad")
end)

suite:Test("Throw policy with Message: Report uses Message, not Error tostring", function(ctx)
	ErrorHandler.SetPolicy("Throw")
	ctx:Expect(function()
		ErrorHandler.Report({ Module = "Mod", Phase = "Phase", Error = {}, Message = "custom msg" })
	end):ToThrow("Mod.Phase: custom msg")
end)

suite:Test("Swallow policy: Report does not throw or warn", function(ctx)
	ErrorHandler.SetPolicy("Swallow")
	ctx:Expect(function()
		ErrorHandler.Report({ Module = "X", Phase = "P", Error = "e" })
	end):ToNotThrow()
end)

suite:Test("Collect policy: Report appends to collected array", function(ctx)
	ErrorHandler.SetPolicy("Collect")
	ErrorHandler.Report({ Module = "X", Phase = "P", Error = "first" })
	ErrorHandler.Report({ Module = "X", Phase = "P", Error = "second" })
	local collected = ErrorHandler.TakeCollected()
	ctx:Expect(#collected):ToBe(2)
	ctx:Expect((collected[1] :: any).Error):ToBe("first")
	ctx:Expect((collected[2] :: any).Error):ToBe("second")
end)

suite:Test("TakeCollected clears the internal buffer", function(ctx)
	ErrorHandler.SetPolicy("Collect")
	ErrorHandler.Report({ Module = "X", Phase = "P", Error = "e" })
	ErrorHandler.TakeCollected()
	local second = ErrorHandler.TakeCollected()
	ctx:Expect(#second):ToBe(0)
end)

suite:Test("Policy enum constants are accepted by SetPolicy", function(ctx)
	ErrorHandler.SetPolicy(ErrorHandler.Policy.Collect)
	ctx:Expect(ErrorHandler.GetPolicy()):ToBe("Collect")
	ErrorHandler.SetPolicy(ErrorHandler.Policy.Swallow)
	ctx:Expect(ErrorHandler.GetPolicy()):ToBe("Swallow")
end)

suite:Test("Collect stores the original error info table by identity", function(ctx)
	ErrorHandler.SetPolicy("Collect")
	local info = { Module = "X", Phase = "P", Error = { Code = 5 } }
	ErrorHandler.Report(info)
	local collected = ErrorHandler.TakeCollected()
	ctx:Expect(collected[1]):ToBe(info)
	ctx:Expect((collected[1] :: any).Error.Code):ToBe(5)
end)

-- ── Reporter ──────────────────────────────────────────────────────────────────

suite:Test("SetReporter installs a reporter called before policy action", function(ctx)
	local reporterCalled = false
	ErrorHandler.SetPolicy("Swallow")
	ErrorHandler.SetReporter(function(_info)
		reporterCalled = true
	end)
	ErrorHandler.Report({ Module = "X", Phase = "P", Error = "e" })
	ctx:Expect(reporterCalled):ToBe(true)
end)

suite:Test("SetReporter(nil) clears the reporter", function(ctx)
	local callCount = 0
	ErrorHandler.SetPolicy("Swallow")
	ErrorHandler.SetReporter(function(_info)
		callCount += 1
	end)
	ErrorHandler.SetReporter(nil)
	ErrorHandler.Report({ Module = "X", Phase = "P", Error = "e" })
	ctx:Expect(callCount):ToBe(0)
end)

suite:Test("SetReporter non-function throws", function(ctx)
	ctx:Expect(function()
		ErrorHandler.SetReporter(42 :: any)
	end):ToThrow("reporter must be a function or nil")
end)

suite:Test("Reporter error does not recurse and does not prevent policy action", function(ctx)
	ErrorHandler.SetPolicy("Collect")
	ErrorHandler.SetReporter(function(_info)
		error("reporter boom")
	end)
	-- Should not throw; reporter failure is warn'd internally.
	ctx:Expect(function()
		ErrorHandler.Report({ Module = "X", Phase = "P", Error = "e" })
	end):ToNotThrow()
	local collected = ErrorHandler.TakeCollected()
	ctx:Expect(#collected):ToBe(1)
end)

suite:Test("Nested Report during reporter skips reporter for nested call", function(ctx)
	local reporterCallCount = 0
	ErrorHandler.SetPolicy("Swallow")
	ErrorHandler.SetReporter(function(_info)
		reporterCallCount += 1
		-- Nested call: reporter must not re-enter.
		ErrorHandler.Report({ Module = "Inner", Phase = "P", Error = "nested" })
	end)
	ErrorHandler.Report({ Module = "Outer", Phase = "P", Error = "outer" })
	-- Reporter was called once (for outer); nested call bypassed reporter.
	ctx:Expect(reporterCallCount):ToBe(1)
end)

-- ── Protect helper ────────────────────────────────────────────────────────────

suite:Test("Protect returns true on success", function(ctx)
	ErrorHandler.SetPolicy("Collect")
	local result = ErrorHandler.Protect(function() end, "Mod", "Phase", nil)
	ctx:Expect(result):ToBe(true)
	ctx:Expect(#ErrorHandler.TakeCollected()):ToBe(0)
end)

suite:Test("Protect returns false and routes error on failure", function(ctx)
	ErrorHandler.SetPolicy("Collect")
	local result = ErrorHandler.Protect(function()
		error("oops")
	end, "Mod", "Phase", nil)
	ctx:Expect(result):ToBe(false)
	local collected = ErrorHandler.TakeCollected()
	ctx:Expect(#collected):ToBe(1)
	ctx:Expect((collected[1] :: any).Module):ToBe("Mod")
end)

suite:Test("Protect returns (true, value) on success when value matters", function(ctx)
	ErrorHandler.SetPolicy("Collect")
	local ok, value = ErrorHandler.Protect(function()
		return 42
	end, "Mod", "Phase", nil)
	ctx:Expect(ok):ToBe(true)
	ctx:Expect(value):ToBe(42)
end)

suite:Test("Protect preserves successful nil returns without reporting", function(ctx)
	ErrorHandler.SetPolicy("Collect")
	local ok, value = ErrorHandler.Protect(function()
		return nil
	end, "Mod", "Phase", nil)
	ctx:Expect(ok):ToBe(true)
	ctx:Expect(value):ToBe(nil)
	ctx:Expect(#ErrorHandler.TakeCollected()):ToBe(0)
end)

suite:Test("Protect returns (false, err) and routes error on failure", function(ctx)
	ErrorHandler.SetPolicy("Collect")
	local ok, _ = ErrorHandler.Protect(function()
		error("fail")
	end, "Mod", "Phase", nil)
	ctx:Expect(ok):ToBe(false)
	ctx:Expect(#ErrorHandler.TakeCollected()):ToBe(1)
end)

return suite:Run()
