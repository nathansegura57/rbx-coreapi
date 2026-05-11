--!strict

local Connection = require(script.Parent.Parent.src.Connection)
local ErrorHandler = require(script.Parent.Parent.src.ErrorHandler)
local Scheduler = require(script.Parent.Parent.src.Scheduler)

-- ── Exported types ─────────────────────────────────────────────────────────────

export type SpyFn = {
	CallCount: (self: SpyFn) -> number,
	WasCalled: (self: SpyFn) -> boolean,
	WasCalledWith: (self: SpyFn, ...any) -> boolean,
	LastArgs: (self: SpyFn) -> { any }?,
	AllCalls: (self: SpyFn) -> { { any } },
	Reset: (self: SpyFn) -> (),
}

export type MockScheduler = {
	Install: (self: MockScheduler) -> (),
	Uninstall: (self: MockScheduler) -> (),
	Flush: (self: MockScheduler) -> (),
	Advance: (self: MockScheduler, dt: number) -> (),
	Step: (self: MockScheduler, dt: number) -> (),
	Now: (self: MockScheduler) -> number,
	PendingDefers: (self: MockScheduler) -> number,
	PendingDelays: (self: MockScheduler) -> number,
}

export type ErrorCapture = {
	Install: (self: ErrorCapture) -> (),
	Uninstall: (self: ErrorCapture) -> (),
	Take: (self: ErrorCapture) -> { any },
	Count: (self: ErrorCapture) -> number,
	HasPhase: (self: ErrorCapture, phase: string) -> boolean,
	HasModule: (self: ErrorCapture, module: string) -> boolean,
}

export type TraceCapture = {
	Events: (self: TraceCapture) -> { any },
	EventsNamed: (self: TraceCapture, name: string) -> { any },
	Clear: (self: TraceCapture) -> (),
	Uninstall: (self: TraceCapture) -> (),
}

export type Expectation = {
	ToBe: (self: Expectation, expected: any) -> (),
	ToEqual: (self: Expectation, expected: any) -> (),
	ToNotBe: (self: Expectation, expected: any) -> (),
	ToNotEqual: (self: Expectation, expected: any) -> (),
	ToBeNil: (self: Expectation) -> (),
	ToBeA: (self: Expectation, typeName: string) -> (),
	ToBeTruthy: (self: Expectation) -> (),
	ToBeFalsy: (self: Expectation) -> (),
	ToBeGreaterThan: (self: Expectation, n: number) -> (),
	ToBeLessThan: (self: Expectation, n: number) -> (),
	ToBeGreaterThanOrEqual: (self: Expectation, n: number) -> (),
	ToBeCloseTo: (self: Expectation, n: number, epsilon: number?) -> (),
	ToMatch: (self: Expectation, pattern: string) -> (),
	ToHaveLength: (self: Expectation, n: number) -> (),
	ToContain: (self: Expectation, value: any) -> (),
	ToThrow: (self: Expectation, pattern: string?) -> (),
	ToThrowExact: (self: Expectation, message: string) -> (),
	ToNotThrow: (self: Expectation) -> (),
	ToSatisfy: (self: Expectation, pred: (any) -> boolean, label: string?) -> (),
}

export type TestContext = {
	Mock: MockScheduler,
	Expect: (self: TestContext, value: any) -> Expectation,
	Spy: (self: TestContext, impl: ((...any) -> ...any)?) -> SpyFn,
	CaptureErrors: (self: TestContext) -> ErrorCapture,
	CaptureTraces: (self: TestContext, setTracer: ((any) -> ()) -> ()) -> TraceCapture,
}

export type TestResult = {
	name: string,
	status: "Passed" | "Failed" | "Skipped",
	error: string?,
	durationMs: number,
}

export type SuiteReport = {
	name: string,
	passed: number,
	failed: number,
	skipped: number,
	total: number,
	results: { TestResult },
}

export type Suite = {
	Test: (self: Suite, name: string, fn: (ctx: TestContext) -> ()) -> (),
	Skip: (self: Suite, name: string, fn: (ctx: TestContext) -> ()) -> (),
	BeforeEach: (self: Suite, fn: (ctx: TestContext) -> ()) -> (),
	AfterEach: (self: Suite, fn: (ctx: TestContext) -> ()) -> (),
	Run: (self: Suite) -> SuiteReport,
}

-- ── Deep equality ──────────────────────────────────────────────────────────────

local function deepEqual(a: any, b: any, visited: { [any]: { [any]: boolean } }?): boolean
	if a == b then
		return true
	end
	if type(a) ~= type(b) then
		return false
	end
	if type(a) ~= "table" then
		return false
	end
	local vis: { [any]: { [any]: boolean } } = if visited ~= nil then visited else {}
	if vis[a] and vis[a][b] then
		return true
	end
	vis[a] = vis[a] or {}
	vis[a][b] = true
	vis[b] = vis[b] or {}
	vis[b][a] = true
	for k, v in a do
		if not deepEqual(v, (b :: any)[k], vis) then
			return false
		end
	end
	for k, _ in b do
		if (a :: any)[k] == nil and (b :: any)[k] ~= nil then
			return false
		end
	end
	return true
end

-- ── MockScheduler ──────────────────────────────────────────────────────────────

type DelayEntry = {
	deadline: number,
	fn: () -> (),
	handle: number,
	cancelled: boolean,
}

local function newMockScheduler(): MockScheduler
	local self = {} :: any
	self._now = 0
	self._deferQueue = {} :: { () -> () }
	self._delayQueue = {} :: { DelayEntry }
	self._stepListeners = {} :: { (number) -> () }
	self._nextHandle = 1
	self._installed = false

	function self:Now(): number
		return self._now
	end

	function self:PendingDefers(): number
		return #self._deferQueue
	end

	function self:PendingDelays(): number
		local count = 0
		for _, entry in self._delayQueue do
			if not entry.cancelled then
				count += 1
			end
		end
		return count
	end

	-- Drain the entire deferred queue, including work enqueued by callbacks.
	function self:Flush(): ()
		local guard = 0
		while #self._deferQueue > 0 and guard < 10000 do
			local fn = table.remove(self._deferQueue, 1) :: any
			fn()
			guard += 1
		end
	end

	-- Advance virtual clock and run all due delay callbacks.
	function self:Advance(dt: number): ()
		self._now += dt
		local i = 1
		while i <= #self._delayQueue do
			local entry: DelayEntry = self._delayQueue[i]
			if entry.cancelled then
				table.remove(self._delayQueue, i)
			elseif entry.deadline <= self._now then
				table.remove(self._delayQueue, i)
				entry.fn()
				self:Flush()
			else
				i += 1
			end
		end
	end

	-- Fire all OnStep listeners then flush deferred work.
	function self:Step(dt: number): ()
		for _, fn in self._stepListeners do
			fn(dt)
		end
		self:Flush()
	end

	function self:Install(): ()
		if self._installed then
			return
		end
		self._installed = true
		local mock = self
		Scheduler.SetDriver({
			Defer = function(fn: () -> ()): any
				table.insert(mock._deferQueue, fn)
				return nil
			end,
			Delay = function(seconds: number, fn: () -> ()): any
				local handle = mock._nextHandle
				mock._nextHandle += 1
				local entry: DelayEntry = {
					deadline = mock._now + seconds,
					fn = fn,
					handle = handle,
					cancelled = false,
				}
				local inserted = false
				for i = 1, #mock._delayQueue do
					if mock._delayQueue[i].deadline > entry.deadline then
						table.insert(mock._delayQueue, i, entry)
						inserted = true
						break
					end
				end
				if not inserted then
					table.insert(mock._delayQueue, entry)
				end
				return handle
			end,
			Cancel = function(handle: any): ()
				for _, entry in mock._delayQueue do
					if entry.handle == handle then
						entry.cancelled = true
						break
					end
				end
			end,
			Now = function(): number
				return mock._now
			end,
			OnStep = function(fn: (number) -> ()): Connection.Connection
				table.insert(mock._stepListeners, fn)
				return Connection.New(function()
					for i = 1, #mock._stepListeners do
						if mock._stepListeners[i] == fn then
							table.remove(mock._stepListeners, i)
							break
						end
					end
				end)
			end,
		})
	end

	function self:Uninstall(): ()
		if not self._installed then
			return
		end
		self._installed = false
		Scheduler.ResetDriver()
	end

	return self :: MockScheduler
end

-- ── Spy ────────────────────────────────────────────────────────────────────────

local function newSpy(impl: ((...any) -> ...any)?): SpyFn
	local calls: { { any } } = {}
	local spy = {} :: any

	setmetatable(spy, {
		__call = function(_self: any, ...: any): ...any
			table.insert(calls, { ... })
			if impl ~= nil then
				return impl(...)
			end
			return
		end,
	})

	function spy:CallCount(): number
		return #calls
	end

	function spy:WasCalled(): boolean
		return #calls > 0
	end

	function spy:WasCalledWith(...: any): boolean
		local expected = { ... }
		local last = calls[#calls]
		if last == nil then
			return false
		end
		if #last ~= #expected then
			return false
		end
		for i = 1, #expected do
			if last[i] ~= expected[i] then
				return false
			end
		end
		return true
	end

	function spy:LastArgs(): { any }?
		return calls[#calls]
	end

	function spy:AllCalls(): { { any } }
		return table.clone(calls)
	end

	function spy:Reset(): ()
		table.clear(calls)
	end

	return spy :: SpyFn
end

-- ── ErrorCapture ───────────────────────────────────────────────────────────────

local function newErrorCapture(): ErrorCapture
	local self = {} :: any
	local _prevPolicy: ErrorHandler.Policy = "Throw"
	local _buffer: { any } = {}

	local function sync(): ()
		local from = ErrorHandler.TakeCollected()
		for _, e in from do
			table.insert(_buffer, e)
		end
	end

	function self:Install(): ()
		_prevPolicy = ErrorHandler.GetPolicy()
		ErrorHandler.SetPolicy("Collect")
	end

	function self:Uninstall(): ()
		sync()
		ErrorHandler.SetPolicy(_prevPolicy)
	end

	function self:Take(): { any }
		sync()
		local result = _buffer
		_buffer = {}
		return result
	end

	function self:Count(): number
		sync()
		return #_buffer
	end

	function self:HasPhase(phase: string): boolean
		sync()
		for _, e in _buffer do
			if (e :: any).Phase == phase then
				return true
			end
		end
		return false
	end

	function self:HasModule(mod: string): boolean
		sync()
		for _, e in _buffer do
			if (e :: any).Module == mod then
				return true
			end
		end
		return false
	end

	return self :: ErrorCapture
end

-- ── TraceCapture ───────────────────────────────────────────────────────────────

local function newTraceCapture(setTracer: ((any) -> ()) -> ()): TraceCapture
	local self = {} :: any
	local _events: { any } = {}

	setTracer(function(event: any)
		table.insert(_events, event)
	end)

	function self:Events(): { any }
		return table.clone(_events)
	end

	function self:EventsNamed(name: string): { any }
		local result: { any } = {}
		for _, e in _events do
			if (e :: any).Event == name then
				table.insert(result, e)
			end
		end
		return result
	end

	function self:Clear(): ()
		table.clear(_events)
	end

	function self:Uninstall(): ()
		setTracer(nil :: any)
		table.clear(_events)
	end

	return self :: TraceCapture
end

-- ── Expectation ────────────────────────────────────────────────────────────────

local function failAt(label: string, msg: string): ()
	error(`[{label}] {msg}`, 3)
end

local function newExpectation(value: any, label: string): Expectation
	local self = {} :: any

	function self:ToBe(expected: any): ()
		if value ~= expected then
			failAt(label, `Expected {tostring(expected)}, got {tostring(value)}`)
		end
	end

	function self:ToEqual(expected: any): ()
		if not deepEqual(value, expected) then
			failAt(label, `Expected deep equality.\n  Expected: {tostring(expected)}\n  Got:      {tostring(value)}`)
		end
	end

	function self:ToNotBe(expected: any): ()
		if value == expected then
			failAt(label, `Expected value to NOT be {tostring(expected)}`)
		end
	end

	function self:ToNotEqual(expected: any): ()
		if deepEqual(value, expected) then
			failAt(label, `Expected values to NOT be deeply equal`)
		end
	end

	function self:ToBeNil(): ()
		if value ~= nil then
			failAt(label, `Expected nil, got {tostring(value)}`)
		end
	end

	function self:ToBeA(typeName: string): ()
		local t = type(value)
		if t ~= typeName then
			failAt(label, `Expected type '{typeName}', got '{t}'`)
		end
	end

	function self:ToBeTruthy(): ()
		if not value then
			failAt(label, `Expected truthy value, got {tostring(value)}`)
		end
	end

	function self:ToBeFalsy(): ()
		if value then
			failAt(label, `Expected falsy value, got {tostring(value)}`)
		end
	end

	function self:ToBeGreaterThan(n: number): ()
		if type(value) ~= "number" or value <= n then
			failAt(label, `Expected {tostring(value)} > {n}`)
		end
	end

	function self:ToBeLessThan(n: number): ()
		if type(value) ~= "number" or value >= n then
			failAt(label, `Expected {tostring(value)} < {n}`)
		end
	end

	function self:ToBeGreaterThanOrEqual(n: number): ()
		if type(value) ~= "number" or value < n then
			failAt(label, `Expected {tostring(value)} >= {n}`)
		end
	end

	function self:ToBeCloseTo(n: number, epsilon: number?): ()
		local eps = if epsilon ~= nil then epsilon else 1e-9
		if type(value) ~= "number" or math.abs(value - n) > eps then
			failAt(label, `Expected {tostring(value)} ≈ {n} (±{eps})`)
		end
	end

	function self:ToMatch(pattern: string): ()
		if type(value) ~= "string" or not string.find(value, pattern) then
			failAt(label, `Expected '{tostring(value)}' to match pattern '{pattern}'`)
		end
	end

	function self:ToHaveLength(n: number): ()
		if type(value) ~= "table" and type(value) ~= "string" then
			failAt(label, `Expected a table or string for length check, got {type(value)}`)
		end
		local len = if type(value) == "string" then #(value :: string) else #(value :: { any })
		if len ~= n then
			failAt(label, `Expected length {n}, got {len}`)
		end
	end

	function self:ToContain(item: any): ()
		if type(value) ~= "table" then
			failAt(label, `Expected a table for :ToContain, got {type(value)}`)
		end
		for _, v in (value :: { any }) do
			if v == item then
				return
			end
		end
		failAt(label, `Expected table to contain {tostring(item)}`)
	end

	function self:ToThrow(pattern: string?): ()
		if type(value) ~= "function" then
			failAt(label, `Expected a function for :ToThrow, got {type(value)}`)
		end
		local ok, err = pcall(value :: any)
		if ok then
			failAt(label, `Expected function to throw, but it did not`)
		end
		if pattern ~= nil and not string.find(tostring(err), pattern) then
			failAt(label, `Expected error matching '{pattern}', got '{tostring(err)}'`)
		end
	end

	function self:ToThrowExact(message: string): ()
		if type(value) ~= "function" then
			failAt(label, `Expected a function for :ToThrowExact, got {type(value)}`)
		end
		local ok, err = pcall(value :: any)
		if ok then
			failAt(label, `Expected function to throw '{message}', but it did not`)
		end
		local errStr = tostring(err)
		if not string.find(errStr, message, 1, true) then
			failAt(label, `Expected error containing '{message}', got '{errStr}'`)
		end
	end

	function self:ToNotThrow(): ()
		if type(value) ~= "function" then
			failAt(label, `Expected a function for :ToNotThrow, got {type(value)}`)
		end
		local ok, err = pcall(value :: any)
		if not ok then
			failAt(label, `Expected function not to throw, got: {tostring(err)}`)
		end
	end

	function self:ToSatisfy(pred: (any) -> boolean, lbl: string?): ()
		if not pred(value) then
			local suffix = if lbl ~= nil then ` ({lbl})` else ""
			failAt(label, `Expected value to satisfy predicate{suffix}: {tostring(value)}`)
		end
	end

	return self :: Expectation
end

-- ── TestContext ─────────────────────────────────────────────────────────────────

local function newTestContext(suiteName: string, testName: string): (TestContext, MockScheduler)
	local mock = newMockScheduler()
	mock:Install()

	local ctx = {} :: any
	ctx.Mock = mock
	local fullLabel = `{suiteName} > {testName}`

	function ctx:Expect(v: any): Expectation
		return newExpectation(v, fullLabel)
	end

	function ctx:Spy(impl: ((...any) -> ...any)?): SpyFn
		return newSpy(impl)
	end

	function ctx:CaptureErrors(): ErrorCapture
		local cap = newErrorCapture()
		cap:Install()
		return cap
	end

	function ctx:CaptureTraces(setTracer: ((any) -> ()) -> ()): TraceCapture
		return newTraceCapture(setTracer)
	end

	return ctx :: TestContext, mock
end

-- ── Suite ───────────────────────────────────────────────────────────────────────

type TestCase = {
	name: string,
	fn: (ctx: TestContext) -> (),
	skip: boolean,
}

type SuiteRecord = {
	_name: string,
	_tests: { TestCase },
	_beforeEach: ((ctx: TestContext) -> ())?,
	_afterEach: ((ctx: TestContext) -> ())?,
}

local suiteMethods: { [string]: any } = {}

function suiteMethods:Test(name: string, fn: (ctx: TestContext) -> ()): ()
	table.insert(self._tests, { name = name, fn = fn, skip = false })
end

function suiteMethods:Skip(name: string, fn: (ctx: TestContext) -> ()): ()
	table.insert(self._tests, { name = name, fn = fn, skip = true })
end

function suiteMethods:BeforeEach(fn: (ctx: TestContext) -> ()): ()
	self._beforeEach = fn
end

function suiteMethods:AfterEach(fn: (ctx: TestContext) -> ()): ()
	self._afterEach = fn
end

function suiteMethods:Run(): SuiteReport
	local report: SuiteReport = {
		name = self._name,
		passed = 0,
		failed = 0,
		skipped = 0,
		total = #self._tests,
		results = {},
	}

	for _, testCase in self._tests do
		if testCase.skip then
			report.skipped += 1
			table.insert(report.results, {
				name = testCase.name,
				status = "Skipped",
				error = nil,
				durationMs = 0,
			})
			continue
		end

		local ctx, mock = newTestContext(self._name, testCase.name)
		local prevPolicy = ErrorHandler.GetPolicy()

		local beforeOk = true
		local beforeErr: string? = nil
		if self._beforeEach ~= nil then
			local ok, err = pcall(self._beforeEach :: any, ctx)
			if not ok then
				beforeOk = false
				beforeErr = "BeforeEach: " .. tostring(err)
			end
		end

		local testOk = true
		local testErr: string? = nil
		local startTime = os.clock()

		if beforeOk then
			local coro = coroutine.create(testCase.fn :: any)
			local ok, err = coroutine.resume(coro, ctx)
			if not ok then
				testOk = false
				testErr = tostring(err)
			else
				-- Drain coroutine: flush deferred work and resume until complete.
				-- This handles tests that yield waiting for deferred callbacks.
				local guard = 0
				while coroutine.status(coro) ~= "dead" and guard < 200 do
					mock:Flush()
					local resumed, resumeErr = coroutine.resume(coro)
					if not resumed then
						testOk = false
						testErr = tostring(resumeErr)
						break
					end
					guard += 1
				end
				if coroutine.status(coro) ~= "dead" then
					testOk = false
					testErr = "Test hung: yielded without progressing after 200 flush attempts"
				end
			end
		else
			testOk = false
			testErr = beforeErr
		end

		local durationMs = (os.clock() - startTime) * 1000

		if self._afterEach ~= nil then
			pcall(self._afterEach :: any, ctx)
		end

		mock:Uninstall()
		ErrorHandler.SetPolicy(prevPolicy)

		if testOk then
			report.passed += 1
			table.insert(report.results, {
				name = testCase.name,
				status = "Passed",
				error = nil,
				durationMs = durationMs,
			})
		else
			report.failed += 1
			table.insert(report.results, {
				name = testCase.name,
				status = "Failed",
				error = testErr,
				durationMs = durationMs,
			})
		end
	end

	return report
end

-- ── Public API ──────────────────────────────────────────────────────────────────

local TestKit = {}

function TestKit.Suite(name: string): Suite
	if type(name) ~= "string" or #name == 0 then
		error("TestKit.Suite: name must be a non-empty string")
	end
	local suite = setmetatable({
		_name = name,
		_tests = {},
		_beforeEach = nil,
		_afterEach = nil,
	} :: any, { __index = suiteMethods })
	return suite :: Suite
end

function TestKit.Expect(value: any): Expectation
	return newExpectation(value, "standalone")
end

function TestKit.MockScheduler(): MockScheduler
	return newMockScheduler()
end

function TestKit.Spy(impl: ((...any) -> ...any)?): SpyFn
	return newSpy(impl)
end

function TestKit.ErrorCapture(): ErrorCapture
	return newErrorCapture()
end

function TestKit.TraceCapture(setTracer: ((any) -> ()) -> ()): TraceCapture
	return newTraceCapture(setTracer)
end

return TestKit
