--!strict

local Connection = require(script.Parent.Parent.Parent.src.Connection)
local ErrorHandler = require(script.Parent.Parent.Parent.src.ErrorHandler)
local Signal = require(script.Parent.Parent.Parent.src.Signal)
local TestKit = require(script.Parent.Parent.TestKit)

local suite = TestKit.Suite("Signal")

suite:AfterEach(function(_ctx)
	ErrorHandler.SetPolicy("Throw")
end)

-- ── Construction ──────────────────────────────────────────────────────────────

suite:Test("New() returns a live signal handle", function(ctx)
	local sig = Signal.New()
	ctx:Expect(Signal.IsSignal(sig)):ToBe(true)
	ctx:Expect(sig:IsDestroyed()):ToBe(false)
end)

suite:Test("New: getmetatable returns 'Signal'", function(ctx)
	local sig = Signal.New()
	ctx:Expect(getmetatable(sig :: any)):ToBe("Signal")
end)

suite:Test("New: assigning a field errors with read-only message", function(ctx)
	local sig = Signal.New()
	ctx:Expect(function()
		(sig :: any).Field = true
	end):ToThrow("read-only")
end)

suite:Test("Never() returns a live signal", function(ctx)
	local sig = Signal.Never()
	ctx:Expect(Signal.IsSignal(sig)):ToBe(true)
	ctx:Expect(sig:IsDestroyed()):ToBe(false)
end)

suite:Test("Never: Fire throws", function(ctx)
	local sig = Signal.Never()
	ctx:Expect(function()
		sig:Fire(nil)
	end):ToThrow("cannot fire a never signal")
end)

suite:Test("Never: Connect is allowed", function(ctx)
	local sig = Signal.Never()
	ctx:Expect(function()
		sig:Connect(function(_p) end)
	end):ToNotThrow()
end)

-- ── IsSignal ──────────────────────────────────────────────────────────────────

suite:Test("IsSignal returns true for a destroyed signal", function(ctx)
	local sig = Signal.New()
	sig:Destroy()
	ctx:Expect(Signal.IsSignal(sig)):ToBe(true)
end)

suite:Test("IsSignal returns false for nil", function(ctx)
	ctx:Expect(Signal.IsSignal(nil)):ToBe(false)
end)

suite:Test("IsSignal returns false for a plain table", function(ctx)
	ctx:Expect(Signal.IsSignal({})):ToBe(false)
end)

-- ── Signal.After ──────────────────────────────────────────────────────────────

suite:Test("After(seconds) fires nil then destroys itself", function(ctx)
	local fired = false
	local payload: any = "sentinel"
	local sig = Signal.After(1)
	sig:Connect(function(p)
		fired = true
		payload = p
	end)
	ctx:Expect(fired):ToBe(false)
	ctx.Mock:Advance(1)
	ctx:Expect(fired):ToBe(true)
	ctx:Expect(payload):ToBe(nil)
	ctx:Expect(sig:IsDestroyed()):ToBe(true)
end)

suite:Test("After(0) fires after flush", function(ctx)
	local fired = false
	local sig = Signal.After(0)
	sig:Connect(function(_p) fired = true end)
	ctx.Mock:Advance(0)
	ctx:Expect(fired):ToBe(true)
end)

suite:Test("After: negative seconds throws", function(ctx)
	ctx:Expect(function()
		Signal.After(-1)
	end):ToThrow("seconds must be non-negative")
end)

suite:Test("After: NaN seconds throws", function(ctx)
	ctx:Expect(function()
		Signal.After(0 / 0)
	end):ToThrow("seconds must be non-negative")
end)

suite:Test("Destroying After signal before timer fires cancels it", function(ctx)
	local fired = false
	local sig = Signal.After(5)
	sig:Connect(function(_p) fired = true end)
	sig:Destroy()
	ctx.Mock:Advance(10)
	ctx:Expect(fired):ToBe(false)
end)

-- ── Signal.Every ──────────────────────────────────────────────────────────────

suite:Test("Every fires repeatedly at interval", function(ctx)
	local count = 0
	local sig = Signal.Every(1)
	sig:Connect(function(_p) count += 1 end)
	ctx.Mock:Advance(1)
	ctx.Mock:Advance(1)
	ctx.Mock:Advance(1)
	ctx:Expect(count):ToBe(3)
end)

suite:Test("Every: positive required", function(ctx)
	ctx:Expect(function()
		Signal.Every(0)
	end):ToThrow("seconds must be positive")
end)

suite:Test("Every: NaN throws", function(ctx)
	ctx:Expect(function()
		Signal.Every(0 / 0)
	end):ToThrow("seconds must be positive")
end)

suite:Test("Destroying Every cancels future ticks", function(ctx)
	local count = 0
	local sig = Signal.Every(1)
	sig:Connect(function(_p) count += 1 end)
	ctx.Mock:Advance(1)
	sig:Destroy()
	ctx.Mock:Advance(2)
	ctx:Expect(count):ToBe(1)
end)

-- ── Connect ───────────────────────────────────────────────────────────────────

suite:Test("Connect returns a Connection", function(ctx)
	local sig = Signal.New()
	local conn = sig:Connect(function(_p) end)
	ctx:Expect(Connection.IsConnection(conn)):ToBe(true)
	ctx:Expect(conn.Connected):ToBe(true)
end)

suite:Test("Connect on destroyed signal throws", function(ctx)
	local sig = Signal.New()
	sig:Destroy()
	ctx:Expect(function()
		sig:Connect(function(_p) end)
	end):ToThrow("signal is destroyed")
end)

suite:Test("Connect with non-function throws", function(ctx)
	local sig = Signal.New()
	ctx:Expect(function()
		sig:Connect(42 :: any)
	end):ToThrow("listener must be a function")
end)

suite:Test("Disconnecting connection stops future deliveries", function(ctx)
	local count = 0
	local sig = Signal.New()
	local conn = sig:Connect(function(_p) count += 1 end)
	sig:Fire(nil)
	conn:Disconnect()
	sig:Fire(nil)
	ctx:Expect(count):ToBe(1)
end)

-- ── Once ─────────────────────────────────────────────────────────────────────

suite:Test("Once listener runs exactly once", function(ctx)
	local count = 0
	local sig = Signal.New()
	sig:Once(function(_p) count += 1 end)
	sig:Fire(nil)
	sig:Fire(nil)
	ctx:Expect(count):ToBe(1)
end)

suite:Test("Once on destroyed signal throws", function(ctx)
	local sig = Signal.New()
	sig:Destroy()
	ctx:Expect(function()
		sig:Once(function(_p) end)
	end):ToThrow("signal is destroyed")
end)

suite:Test("Once with non-function throws", function(ctx)
	local sig = Signal.New()
	ctx:Expect(function()
		sig:Once(42 :: any)
	end):ToThrow("listener must be a function")
end)

suite:Test("Once disconnects before invoking listener (no re-entry)", function(ctx)
	local count = 0
	local sig = Signal.New()
	sig:Once(function(_p)
		count += 1
		sig:Fire(nil)
	end)
	sig:Fire(nil)
	ctx:Expect(count):ToBe(1)
end)

-- ── Fire ──────────────────────────────────────────────────────────────────────

suite:Test("Fire delivers payload to all connected listeners", function(ctx)
	local results: { number } = {}
	local sig = Signal.New()
	sig:Connect(function(p) table.insert(results, p) end)
	sig:Connect(function(p) table.insert(results, p * 2) end)
	sig:Fire(5)
	ctx:Expect(results[1]):ToBe(5)
	ctx:Expect(results[2]):ToBe(10)
end)

suite:Test("Fire with nil payload is allowed", function(ctx)
	local received: { any } = {}
	local sig = Signal.New()
	sig:Connect(function(p) table.insert(received, { v = p }) end)
	sig:Fire(nil)
	ctx:Expect(#received):ToBe(1)
	ctx:Expect(received[1].v):ToBe(nil)
end)

suite:Test("Fire on destroyed signal is a no-op", function(ctx)
	local count = 0
	local sig = Signal.New()
	sig:Connect(function(_p) count += 1 end)
	sig:Destroy()
	sig:Fire(nil)
	ctx:Expect(count):ToBe(0)
end)

suite:Test("Fire listener error routes through ErrorHandler", function(ctx)
	local errors = ctx:CaptureErrors()
	local sig = Signal.New()
	sig:Connect(function(_p) error("boom") end)
	sig:Fire(nil)
	ctx:Expect(errors:HasModule("Signal")):ToBe(true)
	ctx:Expect(errors:HasPhase("Listener")):ToBe(true)
	errors:Uninstall()
end)

suite:Test("Fire continues to later listeners after non-Throw error", function(ctx)
	ErrorHandler.SetPolicy("Swallow")
	local secondCalled = false
	local sig = Signal.New()
	sig:Connect(function(_p) error("first boom") end)
	sig:Connect(function(_p) secondCalled = true end)
	sig:Fire(nil)
	ctx:Expect(secondCalled):ToBe(true)
end)

suite:Test("Fire is synchronous", function(ctx)
	local log: { string } = {}
	local sig = Signal.New()
	sig:Connect(function(_p) table.insert(log, "listener") end)
	table.insert(log, "before")
	sig:Fire(nil)
	table.insert(log, "after")
	ctx:Expect(log[1]):ToBe("before")
	ctx:Expect(log[2]):ToBe("listener")
	ctx:Expect(log[3]):ToBe("after")
end)

suite:Test("Re-entrant Fire is allowed", function(ctx)
	local count = 0
	local sig = Signal.New()
	local fired = false
	sig:Connect(function(_p)
		count += 1
		if not fired then
			fired = true
			sig:Fire(nil)
		end
	end)
	sig:Fire(nil)
	ctx:Expect(count):ToBe(2)
end)

-- ── DisconnectAll ─────────────────────────────────────────────────────────────

suite:Test("DisconnectAll removes all listeners but keeps signal live", function(ctx)
	local count = 0
	local sig = Signal.New()
	sig:Connect(function(_p) count += 1 end)
	sig:Connect(function(_p) count += 1 end)
	sig:DisconnectAll()
	sig:Fire(nil)
	ctx:Expect(count):ToBe(0)
	ctx:Expect(sig:IsDestroyed()):ToBe(false)
end)

suite:Test("Connect after DisconnectAll works", function(ctx)
	local count = 0
	local sig = Signal.New()
	sig:Connect(function(_p) count += 1 end)
	sig:DisconnectAll()
	sig:Connect(function(_p) count += 1 end)
	sig:Fire(nil)
	ctx:Expect(count):ToBe(1)
end)

-- ── Destroy / IsDestroyed ─────────────────────────────────────────────────────

suite:Test("Destroy marks signal destroyed", function(ctx)
	local sig = Signal.New()
	ctx:Expect(sig:IsDestroyed()):ToBe(false)
	sig:Destroy()
	ctx:Expect(sig:IsDestroyed()):ToBe(true)
end)

suite:Test("Destroy is idempotent", function(ctx)
	local sig = Signal.New()
	sig:Destroy()
	ctx:Expect(function()
		sig:Destroy()
	end):ToNotThrow()
end)

-- ── Replay ────────────────────────────────────────────────────────────────────

suite:Test("ReplayCount replays last N payloads to new subscriber", function(ctx)
	local sig = Signal.New()
	sig:ReplayCount(2)
	sig:Fire(1)
	sig:Fire(2)
	sig:Fire(3)
	local received: { number } = {}
	sig:Connect(function(p) table.insert(received, p) end)
	ctx.Mock:Flush()
	ctx:Expect(#received):ToBe(2)
	ctx:Expect(received[1]):ToBe(2)
	ctx:Expect(received[2]):ToBe(3)
end)

suite:Test("ReplayCount: count must be positive integer", function(ctx)
	local sig = Signal.New()
	ctx:Expect(function()
		sig:ReplayCount(0)
	end):ToThrow("count must be a positive integer")
end)

suite:Test("ReplayCount on destroyed signal throws", function(ctx)
	local sig = Signal.New()
	sig:Destroy()
	ctx:Expect(function()
		sig:ReplayCount(1)
	end):ToThrow("signal is destroyed")
end)

suite:Test("Only one replay policy may be applied", function(ctx)
	local sig = Signal.New()
	sig:ReplayCount(1)
	ctx:Expect(function()
		sig:ReplayCount(1)
	end):ToThrow("only one replay policy")
end)

suite:Test("ReplayTime replays payloads within the time window", function(ctx)
	local sig = Signal.New()
	sig:ReplayTime(2)
	sig:Fire("old")
	ctx.Mock:Advance(2.1)
	sig:Fire("recent")
	local received: { string } = {}
	sig:Connect(function(p) table.insert(received, p) end)
	ctx.Mock:Flush()
	ctx:Expect(#received):ToBe(1)
	ctx:Expect(received[1]):ToBe("recent")
end)

suite:Test("ClearReplay disables replay and clears buffer", function(ctx)
	local sig = Signal.New()
	sig:ReplayCount(5)
	sig:Fire(1)
	sig:ClearReplay()
	local received: { any } = {}
	sig:Connect(function(p) table.insert(received, p) end)
	ctx.Mock:Flush()
	ctx:Expect(#received):ToBe(0)
end)

suite:Test("ClearReplay on signal without policy is a no-op", function(ctx)
	local sig = Signal.New()
	ctx:Expect(function()
		sig:ClearReplay()
	end):ToNotThrow()
end)

-- ── Map ───────────────────────────────────────────────────────────────────────

suite:Test("Map transforms each payload", function(ctx)
	local received: { number } = {}
	local sig = Signal.New()
	local mapped = sig:Map(function(p: number) return p * 2 end)
	mapped:Connect(function(p) table.insert(received, p) end)
	sig:Fire(3)
	sig:Fire(5)
	ctx:Expect(received[1]):ToBe(6)
	ctx:Expect(received[2]):ToBe(10)
end)

suite:Test("Map: non-function throws", function(ctx)
	local sig = Signal.New()
	ctx:Expect(function()
		sig:Map(42 :: any)
	end):ToThrow("mapper must be a function")
end)

suite:Test("Map: destroying source destroys derived", function(ctx)
	local sig = Signal.New()
	local mapped = sig:Map(function(p) return p end)
	sig:Destroy()
	ctx:Expect(mapped:IsDestroyed()):ToBe(true)
end)

suite:Test("Map: destroying derived disconnects from source", function(ctx)
	local count = 0
	local sig = Signal.New()
	local mapped = sig:Map(function(p) return p end)
	mapped:Connect(function(_p) count += 1 end)
	mapped:Destroy()
	sig:Fire(nil)
	ctx:Expect(count):ToBe(0)
end)

suite:Test("Map: mapper error routes through ErrorHandler", function(ctx)
	local errors = ctx:CaptureErrors()
	local sig = Signal.New()
	local mapped = sig:Map(function(_p) error("map boom") end)
	mapped:Connect(function(_p) end)
	sig:Fire(nil)
	ctx:Expect(errors:HasPhase("Map")):ToBe(true)
	errors:Uninstall()
end)

-- ── Filter ────────────────────────────────────────────────────────────────────

suite:Test("Filter passes payloads where predicate returns exactly true", function(ctx)
	local received: { number } = {}
	local sig = Signal.New()
	local filtered = sig:Filter(function(p: number) return p > 0 end)
	filtered:Connect(function(p) table.insert(received, p) end)
	sig:Fire(-1)
	sig:Fire(1)
	sig:Fire(0)
	ctx:Expect(#received):ToBe(1)
	ctx:Expect(received[1]):ToBe(1)
end)

suite:Test("Filter: truthy non-true values do not pass", function(ctx)
	local count = 0
	local sig = Signal.New()
	local filtered = sig:Filter(function(_p) return 1 :: any end)
	filtered:Connect(function(_p) count += 1 end)
	sig:Fire(nil)
	ctx:Expect(count):ToBe(0)
end)

-- ── Scan ──────────────────────────────────────────────────────────────────────

suite:Test("Scan accumulates with seed", function(ctx)
	local received: { number } = {}
	local sig = Signal.New()
	local scanned = sig:Scan(function(acc: number, v: number) return acc + v end, 0)
	scanned:Connect(function(p) table.insert(received, p) end)
	sig:Fire(1)
	sig:Fire(2)
	sig:Fire(3)
	ctx:Expect(received[1]):ToBe(1)
	ctx:Expect(received[2]):ToBe(3)
	ctx:Expect(received[3]):ToBe(6)
end)

-- ── Take ─────────────────────────────────────────────────────────────────────

suite:Test("Take(N) emits first N payloads then destroys derived", function(ctx)
	local received: { number } = {}
	local sig = Signal.New()
	local taken = sig:Take(2)
	taken:Connect(function(p) table.insert(received, p) end)
	sig:Fire(1)
	sig:Fire(2)
	sig:Fire(3)
	ctx:Expect(#received):ToBe(2)
	ctx:Expect(taken:IsDestroyed()):ToBe(true)
	ctx:Expect(sig:IsDestroyed()):ToBe(false)
end)

suite:Test("Take: count must be positive integer", function(ctx)
	local sig = Signal.New()
	ctx:Expect(function()
		sig:Take(0)
	end):ToThrow("count must be a positive integer")
end)

-- ── Skip ─────────────────────────────────────────────────────────────────────

suite:Test("Skip(N) ignores first N then emits rest", function(ctx)
	local received: { number } = {}
	local sig = Signal.New()
	local skipped = sig:Skip(2)
	skipped:Connect(function(p) table.insert(received, p) end)
	sig:Fire(1)
	sig:Fire(2)
	sig:Fire(3)
	ctx:Expect(#received):ToBe(1)
	ctx:Expect(received[1]):ToBe(3)
end)

suite:Test("Skip(0) emits all payloads", function(ctx)
	local count = 0
	local sig = Signal.New()
	local skipped = sig:Skip(0)
	skipped:Connect(function(_p) count += 1 end)
	sig:Fire(1)
	sig:Fire(2)
	ctx:Expect(count):ToBe(2)
end)

-- ── TakeWhile / SkipWhile ─────────────────────────────────────────────────────

suite:Test("TakeWhile emits while predicate returns true then destroys", function(ctx)
	local received: { number } = {}
	local sig = Signal.New()
	local tw = sig:TakeWhile(function(p: number) return p < 3 end)
	tw:Connect(function(p) table.insert(received, p) end)
	sig:Fire(1)
	sig:Fire(2)
	sig:Fire(3)
	ctx:Expect(#received):ToBe(2)
	ctx:Expect(tw:IsDestroyed()):ToBe(true)
end)

suite:Test("SkipWhile emits from first false predicate onward", function(ctx)
	local received: { number } = {}
	local sig = Signal.New()
	local sw = sig:SkipWhile(function(p: number) return p < 3 end)
	sw:Connect(function(p) table.insert(received, p) end)
	sig:Fire(1)
	sig:Fire(2)
	sig:Fire(3)
	sig:Fire(4)
	ctx:Expect(#received):ToBe(2)
	ctx:Expect(received[1]):ToBe(3)
	ctx:Expect(received[2]):ToBe(4)
end)

-- ── TakeUntil / SkipUntil ────────────────────────────────────────────────────

suite:Test("TakeUntil emits until stopper fires then destroys derived", function(ctx)
	local received: { number } = {}
	local sig = Signal.New()
	local stopper = Signal.New()
	local tu = sig:TakeUntil(stopper)
	tu:Connect(function(p) table.insert(received, p) end)
	sig:Fire(1)
	stopper:Fire(nil)
	sig:Fire(2)
	ctx:Expect(#received):ToBe(1)
	ctx:Expect(tu:IsDestroyed()):ToBe(true)
end)

suite:Test("SkipUntil ignores payloads before starter fires", function(ctx)
	local received: { number } = {}
	local sig = Signal.New()
	local starter = Signal.New()
	local su = sig:SkipUntil(starter)
	su:Connect(function(p) table.insert(received, p) end)
	sig:Fire(1)
	starter:Fire(nil)
	sig:Fire(2)
	sig:Fire(3)
	ctx:Expect(#received):ToBe(2)
	ctx:Expect(received[1]):ToBe(2)
end)

-- ── Debounce ─────────────────────────────────────────────────────────────────

suite:Test("Debounce emits only latest payload after quiet period", function(ctx)
	local received: { number } = {}
	local sig = Signal.New()
	local debounced = sig:Debounce(1)
	debounced:Connect(function(p) table.insert(received, p) end)
	sig:Fire(1)
	sig:Fire(2)
	sig:Fire(3)
	ctx:Expect(#received):ToBe(0)
	ctx.Mock:Advance(1)
	ctx:Expect(#received):ToBe(1)
	ctx:Expect(received[1]):ToBe(3)
end)

suite:Test("Debounce: NaN seconds throws", function(ctx)
	local sig = Signal.New()
	ctx:Expect(function()
		sig:Debounce(0 / 0)
	end):ToThrow("seconds must be non-negative")
end)

-- ── Throttle ─────────────────────────────────────────────────────────────────

suite:Test("Throttle default (leading+trailing) emits first and last", function(ctx)
	local received: { number } = {}
	local sig = Signal.New()
	local throttled = sig:Throttle(1)
	throttled:Connect(function(p) table.insert(received, p) end)
	sig:Fire(1)
	sig:Fire(2)
	sig:Fire(3)
	ctx:Expect(received[1]):ToBe(1)
	ctx.Mock:Advance(1)
	ctx:Expect(#received):ToBe(2)
	ctx:Expect(received[2]):ToBe(3)
end)

suite:Test("Throttle leading-only does not emit trailing", function(ctx)
	local received: { number } = {}
	local sig = Signal.New()
	local throttled = sig:Throttle(1, { Leading = true, Trailing = false })
	throttled:Connect(function(p) table.insert(received, p) end)
	sig:Fire(1)
	sig:Fire(2)
	ctx.Mock:Advance(1)
	ctx:Expect(#received):ToBe(1)
	ctx:Expect(received[1]):ToBe(1)
end)

suite:Test("Throttle: seconds must be positive", function(ctx)
	local sig = Signal.New()
	ctx:Expect(function()
		sig:Throttle(0)
	end):ToThrow("seconds must be positive")
end)

-- ── Delay ─────────────────────────────────────────────────────────────────────

suite:Test("Delay defers each payload independently", function(ctx)
	local log: { string } = {}
	local sig = Signal.New()
	local delayed = sig:Delay(1)
	delayed:Connect(function(p) table.insert(log, p) end)
	sig:Fire("first")
	ctx.Mock:Advance(0.5)
	sig:Fire("second")
	ctx.Mock:Advance(0.6)
	ctx:Expect(#log):ToBe(1)
	ctx:Expect(log[1]):ToBe("first")
	ctx.Mock:Advance(0.5)
	ctx:Expect(#log):ToBe(2)
	ctx:Expect(log[2]):ToBe("second")
end)

suite:Test("Delay: NaN throws", function(ctx)
	local sig = Signal.New()
	ctx:Expect(function()
		sig:Delay(0 / 0)
	end):ToThrow("seconds must be non-negative")
end)

-- ── BufferCount ───────────────────────────────────────────────────────────────

suite:Test("BufferCount emits array when count is reached", function(ctx)
	local received: { any } = {}
	local sig = Signal.New()
	local buffered = sig:BufferCount(3)
	buffered:Connect(function(p) table.insert(received, p) end)
	sig:Fire(1)
	sig:Fire(2)
	ctx:Expect(#received):ToBe(0)
	sig:Fire(3)
	ctx:Expect(#received):ToBe(1)
	ctx:Expect(received[1][1]):ToBe(1)
	ctx:Expect(received[1][2]):ToBe(2)
	ctx:Expect(received[1][3]):ToBe(3)
end)

suite:Test("BufferCount with step creates sliding window", function(ctx)
	local received: { any } = {}
	local sig = Signal.New()
	local buffered = sig:BufferCount(3, 1)
	buffered:Connect(function(p) table.insert(received, p) end)
	sig:Fire(1)
	sig:Fire(2)
	sig:Fire(3)
	sig:Fire(4)
	ctx:Expect(#received):ToBe(2)
	ctx:Expect(received[2][1]):ToBe(2)
end)

suite:Test("BufferCount: count must be positive integer", function(ctx)
	local sig = Signal.New()
	ctx:Expect(function()
		sig:BufferCount(0)
	end):ToThrow("count must be a positive integer")
end)

-- ── BufferTime ────────────────────────────────────────────────────────────────

suite:Test("BufferTime emits array on timer fire", function(ctx)
	local received: { any } = {}
	local sig = Signal.New()
	local buffered = sig:BufferTime(1)
	buffered:Connect(function(p) table.insert(received, p) end)
	sig:Fire("a")
	sig:Fire("b")
	ctx:Expect(#received):ToBe(0)
	ctx.Mock:Advance(1)
	ctx:Expect(#received):ToBe(1)
	ctx:Expect(#received[1]):ToBe(2)
end)

suite:Test("BufferTime: seconds must be positive", function(ctx)
	local sig = Signal.New()
	ctx:Expect(function()
		sig:BufferTime(0)
	end):ToThrow("seconds must be positive")
end)

-- ── SampleBy ─────────────────────────────────────────────────────────────────

suite:Test("SampleBy emits latest when sampler fires", function(ctx)
	local received: { number } = {}
	local sig = Signal.New()
	local sampler = Signal.New()
	local sampled = sig:SampleBy(sampler)
	sampled:Connect(function(p) table.insert(received, p) end)
	sig:Fire(1)
	sig:Fire(2)
	ctx:Expect(#received):ToBe(0)
	sampler:Fire(nil)
	ctx:Expect(#received):ToBe(1)
	ctx:Expect(received[1]):ToBe(2)
end)

suite:Test("SampleBy clears presence after sampling", function(ctx)
	local count = 0
	local sig = Signal.New()
	local sampler = Signal.New()
	local sampled = sig:SampleBy(sampler)
	sampled:Connect(function(_p) count += 1 end)
	sig:Fire(1)
	sampler:Fire(nil)
	sampler:Fire(nil)
	ctx:Expect(count):ToBe(1)
end)

-- ── MergeMap ─────────────────────────────────────────────────────────────────

suite:Test("MergeMap subscribes to each inner signal", function(ctx)
	local received: { any } = {}
	local sig = Signal.New()
	local inner1 = Signal.New()
	local inner2 = Signal.New()
	local sources = { inner1, inner2 }
	local idx = 0
	local merged = sig:MergeMap(function(_p)
		idx += 1
		return sources[idx]
	end)
	merged:Connect(function(p) table.insert(received, p) end)
	sig:Fire(nil)
	sig:Fire(nil)
	inner1:Fire("a")
	inner2:Fire("b")
	ctx:Expect(#received):ToBe(2)
end)

-- ── SwitchMap ─────────────────────────────────────────────────────────────────

suite:Test("SwitchMap switches to latest inner signal", function(ctx)
	local received: { any } = {}
	local sig = Signal.New()
	local inner1 = Signal.New()
	local inner2 = Signal.New()
	local sources = { inner1, inner2 }
	local idx = 0
	local switched = sig:SwitchMap(function(_p)
		idx += 1
		return sources[idx]
	end)
	switched:Connect(function(p) table.insert(received, p) end)
	sig:Fire(nil)
	sig:Fire(nil)
	inner1:Fire("from first")
	inner2:Fire("from second")
	ctx:Expect(#received):ToBe(1)
	ctx:Expect(received[1]):ToBe("from second")
end)

-- ── Signal.Merge ─────────────────────────────────────────────────────────────

suite:Test("Merge forwards payloads from all sources", function(ctx)
	local received: { any } = {}
	local sig1 = Signal.New()
	local sig2 = Signal.New()
	local merged = Signal.Merge({ sig1, sig2 })
	merged:Connect(function(p) table.insert(received, p) end)
	sig1:Fire("a")
	sig2:Fire("b")
	ctx:Expect(#received):ToBe(2)
end)

suite:Test("Merge: destroying a source destroys merged", function(ctx)
	local sig1 = Signal.New()
	local sig2 = Signal.New()
	local merged = Signal.Merge({ sig1, sig2 })
	sig1:Destroy()
	ctx:Expect(merged:IsDestroyed()):ToBe(true)
end)

suite:Test("Merge: empty array throws", function(ctx)
	ctx:Expect(function()
		Signal.Merge({})
	end):ToThrow("non-empty dense array")
end)

-- ── Signal.Zip ───────────────────────────────────────────────────────────────

suite:Test("Zip waits for one payload from each source per round", function(ctx)
	local received: { any } = {}
	local sig1 = Signal.New()
	local sig2 = Signal.New()
	local zipped = Signal.Zip({ sig1, sig2 })
	zipped:Connect(function(p) table.insert(received, p) end)
	sig1:Fire("a")
	ctx:Expect(#received):ToBe(0)
	sig2:Fire("b")
	ctx:Expect(#received):ToBe(1)
	ctx:Expect(received[1][1]):ToBe("a")
	ctx:Expect(received[1][2]):ToBe("b")
end)

suite:Test("Zip ignores duplicate source emissions within a round", function(ctx)
	local count = 0
	local sig1 = Signal.New()
	local sig2 = Signal.New()
	local zipped = Signal.Zip({ sig1, sig2 })
	zipped:Connect(function(_p) count += 1 end)
	sig1:Fire(1)
	sig1:Fire(99)
	sig2:Fire(2)
	ctx:Expect(count):ToBe(1)
end)

-- ── Signal.Race ───────────────────────────────────────────────────────────────

suite:Test("Race: first source to emit becomes winner", function(ctx)
	local received: { any } = {}
	local sig1 = Signal.New()
	local sig2 = Signal.New()
	local race = Signal.Race({ sig1, sig2 })
	race:Connect(function(p) table.insert(received, p) end)
	sig2:Fire("winner")
	sig1:Fire("loser")
	ctx:Expect(#received):ToBe(1)
	ctx:Expect(received[1]):ToBe("winner")
end)

-- ── Signal.Sequence ───────────────────────────────────────────────────────────

suite:Test("Sequence fires Completed=true when correct order completed", function(ctx)
	local result: any = nil
	local sigA = Signal.New()
	local sigB = Signal.New()
	local seq = Signal.Sequence({ sigA, sigB })
	seq:Connect(function(p) result = p end)
	sigA:Fire(nil)
	sigB:Fire(nil)
	ctx:Expect(result):ToNotBe(nil)
	ctx:Expect((result :: any).Completed):ToBe(true)
end)

suite:Test("Sequence resets on wrong-order fire by default", function(ctx)
	local completed = false
	local sigA = Signal.New()
	local sigB = Signal.New()
	local seq = Signal.Sequence({ sigA, sigB })
	seq:Connect(function(p) if (p :: any).Completed then completed = true end end)
	sigB:Fire(nil)
	sigA:Fire(nil)
	sigB:Fire(nil)
	ctx:Expect(completed):ToBe(false)
	sigA:Fire(nil)
	sigB:Fire(nil)
	ctx:Expect(completed):ToBe(true)
end)

-- ── Pathological coverage ────────────────────────────────────────────────────

suite:Test("Wait resumes with explicit nil payload", function(ctx)
	local sig = Signal.New()
	local received = "unset" :: any
	local thread = coroutine.create(function()
		received = sig:Wait()
	end)
	coroutine.resume(thread)
	sig:Fire(nil)
	ctx.Mock:Flush()
	ctx:Expect(received):ToBe(nil)
	ctx:Expect(coroutine.status(thread)):ToBe("dead")
end)

suite:Test("ReplayCount replays nil payloads as present values", function(ctx)
	local sig = Signal.New():ReplayCount(2)
	local received: { any } = {}
	sig:Fire(nil)
	sig:Fire("after")
	sig:Connect(function(payload)
		table.insert(received, { HasValue = true, Value = payload })
	end)
	ctx.Mock:Flush()
	ctx:Expect(#received):ToBe(2)
	ctx:Expect(received[1].HasValue):ToBe(true)
	ctx:Expect(received[1].Value):ToBe(nil)
	ctx:Expect(received[2].Value):ToBe("after")
end)

suite:Test("BufferCount preserves nil entries using packed length", function(ctx)
	local sig = Signal.New()
	local buffered = sig:BufferCount(2)
	local result: any = nil
	buffered:Connect(function(payload)
		result = payload
	end)
	sig:Fire(nil)
	sig:Fire("x")
	ctx:Expect(result.n):ToBe(2)
	ctx:Expect(result[1]):ToBe(nil)
	ctx:Expect(result[2]):ToBe("x")
end)

suite:Test("Destroying delayed derived signal cancels pending payloads", function(ctx)
	local sig = Signal.New()
	local delayed = sig:Delay(1)
	local count = 0
	delayed:Connect(function(_payload)
		count += 1
	end)
	sig:Fire("queued")
	delayed:Destroy()
	ctx.Mock:Advance(2)
	ctx:Expect(count):ToBe(0)
end)

suite:Test("Sequence emits mismatch event when FireOnMismatch=true", function(ctx)
	local sigA = Signal.New()
	local sigB = Signal.New()
	local seq = Signal.Sequence({ sigA, sigB }, { FireOnMismatch = true })
	local result: any = nil
	seq:Connect(function(payload)
		result = payload
	end)
	sigB:Fire(nil)
	ctx:Expect(result):ToNotBe(nil)
	ctx:Expect(result.Completed):ToBe(false)
end)

return suite:Run()
