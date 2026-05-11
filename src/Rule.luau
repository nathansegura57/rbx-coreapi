--!strict
local Connection = require(script.Parent.Connection)
local Context = require(script.Parent.Context)
local ErrorHandler = require(script.Parent.ErrorHandler)
local Scheduler = require(script.Parent.Scheduler)
local Signal = require(script.Parent.Signal)
local Store = require(script.Parent.Store)
local Task = require(script.Parent.Task)

-- ── Types ─────────────────────────────────────────────────────────────────────

export type RuleFrame = {
	RuleName: string,
	Now: () -> number,
	Token: Task.Token?,
}

export type Guard<Ctx, Payload> = Store.ReadableStore<boolean> | ((ctx: Ctx, payload: Payload, frame: RuleFrame) -> boolean)

export type Effect<Ctx, Payload> = (ctx: Ctx, payload: Payload, frame: RuleFrame) -> (nil | (() -> ()) | Task.Task<any>)

export type Policy = {
	Concurrency: string,
	Capacity: number,
	Overflow: string,
	Cooldown: number?,
	Debounce: number?,
	Throttle: number?,
	Leading: boolean,
	Trailing: boolean,
	Schedule: string,
	RecheckGuardBeforeRun: boolean,
	CancelTasksWhenGuardFalse: boolean,
	Once: boolean,
	ErrorPolicy: string?,
	Retry: Task.RetryOptions?,
	Trace: boolean,
	Tag: string?,
}

export type PartialPolicy = {
	Concurrency: string?,
	Capacity: number?,
	Overflow: string?,
	Cooldown: number?,
	Debounce: number?,
	Throttle: number?,
	Leading: boolean?,
	Trailing: boolean?,
	Schedule: string?,
	RecheckGuardBeforeRun: boolean?,
	CancelTasksWhenGuardFalse: boolean?,
	Once: boolean?,
	ErrorPolicy: string?,
	Retry: Task.RetryOptions?,
	Trace: boolean?,
	Tag: string?,
}

export type Metrics = {
	Runs: number,
	Skipped: number,
	Errors: number,
	AvgMs: number,
	CollectedErrors: { unknown },
}

export type TraceEvent = {
	Event: string,
	RuleName: string,
	Tag: string?,
}

export type Rule<Ctx, Payload> = {
	On: (self: Rule<Ctx, Payload>, signal: Signal.Signal<Payload>) -> Rule<Ctx, Payload>,
	When: (self: Rule<Ctx, Payload>, guard: Guard<Ctx, Payload>) -> Rule<Ctx, Payload>,
	Run: (self: Rule<Ctx, Payload>, effect: Effect<Ctx, Payload>) -> Rule<Ctx, Payload>,
	Policy: (self: Rule<Ctx, Payload>, policy: PartialPolicy) -> Rule<Ctx, Payload>,
	WithContext: (self: Rule<Ctx, Payload>, ctx: Context.Context<Ctx>) -> Rule<Ctx, Payload>,
	Attach: (self: Rule<Ctx, Payload>, scope: any) -> Rule<Ctx, Payload>,
	Enable: (self: Rule<Ctx, Payload>, ctx: Context.Context<Ctx>?) -> Rule<Ctx, Payload>,
	Disable: (self: Rule<Ctx, Payload>) -> (),
	Destroy: (self: Rule<Ctx, Payload>) -> (),
	IsEnabled: (self: Rule<Ctx, Payload>) -> boolean,
	IsDestroyed: (self: Rule<Ctx, Payload>) -> boolean,
	Name: (self: Rule<Ctx, Payload>) -> string,
	Metrics: (self: Rule<Ctx, Payload>) -> Metrics,
	ResetMetrics: (self: Rule<Ctx, Payload>) -> (),
}

-- ── Internal record ───────────────────────────────────────────────────────────

type PolicyRecord = {
	Concurrency: string,
	Capacity: number,
	Overflow: string,
	Cooldown: number?,
	Debounce: number?,
	Throttle: number?,
	Leading: boolean,
	Trailing: boolean,
	Schedule: string,
	RecheckGuardBeforeRun: boolean,
	CancelTasksWhenGuardFalse: boolean,
	Once: boolean,
	ErrorPolicy: string?,
	Retry: Task.RetryOptions?,
	Trace: boolean,
	Tag: string?,
}

type PayloadSlot = { HasValue: boolean, Value: any }

type RuleRecord = {
	Destroyed: boolean,
	EnableCount: number,
	RuleName: string,

	SignalHandle: any?,
	GuardValue: any?,
	EffectFn: ((any, any, RuleFrame) -> any)?,
	WithCtxHandle: any?,
	EnableCtxHandle: any?,
	AttachScope: any?,

	Policy: PolicyRecord,

	SignalConn: Connection.Connection?,
	GuardWatchConn: Connection.Connection?,

	DebounceTimerHandle: any?,
	DebouncePending: PayloadSlot?,

	ThrottleWindowActive: boolean,
	ThrottleTimerHandle: any?,
	ThrottlePending: PayloadSlot?,

	LastAdmitTime: number?,

	InFlight: { [any]: boolean },
	InFlightCount: number,
	ConcatQueue: { PayloadSlot },
	ConcatRunning: boolean,
	Disposer: (() -> ())?,

	Runs: number,
	Skipped: number,
	Errors: number,
	TotalMs: number,
	CollectedErrors: { unknown },
}

-- ── Private storage ───────────────────────────────────────────────────────────

local ruleRecords: { [any]: RuleRecord } = setmetatable({}, { __mode = "k" } :: any)

-- Scope → list of rule handles (for FSM to query)
local _scopeAttach: { [any]: { any } } = setmetatable({}, { __mode = "k" } :: any)

-- ── Tracer ────────────────────────────────────────────────────────────────────

local _tracer: ((TraceEvent) -> ())? = nil

local function emitTrace(event: string, rec: RuleRecord)
	if _tracer == nil then return end
	local fn = _tracer :: (TraceEvent) -> ()
	ErrorHandler.Protect(function()
		fn({ Event = event, RuleName = rec.RuleName, Tag = rec.Policy.Tag })
	end, "Rule", "Trace")
end

-- ── Metatable ─────────────────────────────────────────────────────────────────

local ruleMethods = {}

local ruleMeta = {
	__metatable = "Rule",
	__index = ruleMethods,
	__newindex = function(_, k: string)
		error("Rule: '" .. k .. "' is read-only", 2)
	end,
}

-- ── Default policy ────────────────────────────────────────────────────────────

local KNOWN_POLICY_KEYS: { [string]: boolean } = {
	Concurrency = true, Capacity = true, Overflow = true,
	Cooldown = true, Debounce = true, Throttle = true,
	Leading = true, Trailing = true, Schedule = true,
	RecheckGuardBeforeRun = true, CancelTasksWhenGuardFalse = true,
	Once = true, ErrorPolicy = true, Retry = true, Trace = true, Tag = true,
}

local function makeDefaultPolicy(): PolicyRecord
	return {
		Concurrency = "Exhaust",
		Capacity = math.huge,
		Overflow = "Drop",
		Cooldown = nil,
		Debounce = nil,
		Throttle = nil,
		Leading = true,
		Trailing = true,
		Schedule = "Deferred",
		RecheckGuardBeforeRun = false,
		CancelTasksWhenGuardFalse = false,
		Once = false,
		ErrorPolicy = nil,
		Retry = nil,
		Trace = false,
		Tag = nil,
	}
end

-- ── Policy validation ─────────────────────────────────────────────────────────

local function validatePolicy(policy: any): (boolean, string?)
	if type(policy) ~= "table" then
		return false, "policy must be a table"
	end
	for k in policy do
		if not KNOWN_POLICY_KEYS[k] then
			return false, "unknown policy key: " .. tostring(k)
		end
	end
	local concurrency = policy.Concurrency
	if concurrency ~= nil then
		if concurrency ~= "Exhaust" and concurrency ~= "Merge"
			and concurrency ~= "Concat" and concurrency ~= "Switch" then
			return false, "Concurrency must be 'Exhaust', 'Merge', 'Concat', or 'Switch'"
		end
	end
	local capacity = policy.Capacity
	if capacity ~= nil then
		if type(capacity) ~= "number" or (capacity <= 0 and capacity ~= math.huge) then
			return false, "Capacity must be a positive number"
		end
	end
	local overflow = policy.Overflow
	if overflow ~= nil then
		if overflow ~= "Drop" and overflow ~= "Latest" and overflow ~= "Fifo" then
			return false, "Overflow must be 'Drop', 'Latest', or 'Fifo'"
		end
	end
	local effectiveConcurrency = if concurrency ~= nil then concurrency else "Exhaust"
	local effectiveOverflow = if overflow ~= nil then overflow else "Drop"
	if effectiveConcurrency == "Merge" and effectiveOverflow ~= "Drop" then
		return false, "Merge concurrency only supports Overflow 'Drop'"
	end
	local cooldown = policy.Cooldown
	if cooldown ~= nil then
		if type(cooldown) ~= "number" or cooldown < 0 then
			return false, "Cooldown must be >= 0"
		end
	end
	local debounce = policy.Debounce
	if debounce ~= nil then
		if type(debounce) ~= "number" or debounce < 0 then
			return false, "Debounce must be >= 0"
		end
	end
	local throttle = policy.Throttle
	if throttle ~= nil then
		if type(throttle) ~= "number" or throttle <= 0 then
			return false, "Throttle must be > 0"
		end
	end
	local leading = policy.Leading
	if leading ~= nil and type(leading) ~= "boolean" then
		return false, "Leading must be a boolean"
	end
	local trailing = policy.Trailing
	if trailing ~= nil and type(trailing) ~= "boolean" then
		return false, "Trailing must be a boolean"
	end
	local schedule = policy.Schedule
	if schedule ~= nil then
		if schedule ~= "Immediate" and schedule ~= "Deferred" then
			return false, "Schedule must be 'Immediate' or 'Deferred'"
		end
	end
	local recheckGuard = policy.RecheckGuardBeforeRun
	if recheckGuard ~= nil and type(recheckGuard) ~= "boolean" then
		return false, "RecheckGuardBeforeRun must be a boolean"
	end
	local cancelGuard = policy.CancelTasksWhenGuardFalse
	if cancelGuard ~= nil and type(cancelGuard) ~= "boolean" then
		return false, "CancelTasksWhenGuardFalse must be a boolean"
	end
	local once = policy.Once
	if once ~= nil and type(once) ~= "boolean" then
		return false, "Once must be a boolean"
	end
	local errorPolicy = policy.ErrorPolicy
	if errorPolicy ~= nil then
		if errorPolicy ~= "Throw" and errorPolicy ~= "Warn"
			and errorPolicy ~= "Swallow" and errorPolicy ~= "Collect" then
			return false, "ErrorPolicy must be 'Throw', 'Warn', 'Swallow', or 'Collect'"
		end
	end
	local retry = policy.Retry
	if retry ~= nil then
		if type(retry) ~= "table" then
			return false, "Retry must be a table"
		end
		local retryCount = (retry :: any).Count
		if type(retryCount) ~= "number" or retryCount < 1 or math.floor(retryCount) ~= retryCount then
			return false, "Retry.Count must be a positive integer"
		end
		local retryBackoff = (retry :: any).Backoff
		if retryBackoff ~= "Fixed" and retryBackoff ~= "Expo" then
			return false, "Retry.Backoff must be 'Fixed' or 'Expo'"
		end
		local retryBase = (retry :: any).Base
		if type(retryBase) ~= "number" or retryBase < 0 then
			return false, "Retry.Base must be >= 0"
		end
		local retryJitter = (retry :: any).Jitter
		if retryJitter ~= nil and (type(retryJitter) ~= "number" or retryJitter < 0) then
			return false, "Retry.Jitter must be >= 0"
		end
	end
	local trace = policy.Trace
	if trace ~= nil and type(trace) ~= "boolean" then
		return false, "Trace must be a boolean"
	end
	local tag = policy.Tag
	if tag ~= nil and type(tag) ~= "string" then
		return false, "Tag must be a string"
	end
	return true, nil
end

-- ── Effect error handler ──────────────────────────────────────────────────────

-- Handles an effect error according to the rule's own ErrorPolicy, independent
-- of the global ErrorHandler policy. Only the nil (absent) case delegates to
-- the global handler so that callers can configure global behaviour as a default.
local function handleEffectError(rec: RuleRecord, err: unknown)
	rec.Errors += 1
	local errorPolicy = rec.Policy.ErrorPolicy
	if errorPolicy == nil then
		-- No rule-level override; use the global ErrorHandler.
		ErrorHandler.Report({ Module = "Rule", Phase = "Effect", Error = err })
	elseif errorPolicy == "Warn" then
		warn(`Rule.Effect[{rec.RuleName}]: {tostring(err)}`)
	elseif errorPolicy == "Throw" then
		error(err, 0)
	elseif errorPolicy == "Collect" then
		table.insert(rec.CollectedErrors, err)
	end
	-- "Swallow": discard silently.
end

-- ── Context resolution ────────────────────────────────────────────────────────

local _emptyRoot: any = nil

local function resolveCtx(rec: RuleRecord): any
	if rec.WithCtxHandle ~= nil then
		return rec.WithCtxHandle
	end
	if rec.EnableCtxHandle ~= nil then
		return rec.EnableCtxHandle
	end
	if _emptyRoot == nil then
		_emptyRoot = Context.Root({})
	end
	return _emptyRoot
end

-- ── Guard evaluation ──────────────────────────────────────────────────────────

local function evalGuard(rec: RuleRecord, payload: any, frame: RuleFrame): boolean
	local g = rec.GuardValue
	if g == nil then
		return true
	end
	if Store.IsStore(g) then
		local ok, result = ErrorHandler.Protect(function() return (g :: any):Get() end, "Rule", "Guard")
		if not ok then
			rec.Errors += 1
			return false
		end
		return result == true
	else
		local ctx = resolveCtx(rec)
		local ok, result = ErrorHandler.Protect(function() return (g :: any)(ctx, payload, frame) end, "Rule", "Guard")
		if not ok then
			rec.Errors += 1
			return false
		end
		return result == true
	end
end

-- ── Concat drain ──────────────────────────────────────────────────────────────

local runEffect: (rec: RuleRecord, ruleHandle: any, payload: any) -> ()

local function concatDrain(rec: RuleRecord, ruleHandle: any)
	if #rec.ConcatQueue == 0 then
		rec.ConcatRunning = false
		return
	end
	local slot = table.remove(rec.ConcatQueue, 1) :: PayloadSlot
	runEffect(rec, ruleHandle, slot.Value)
end

-- ── Task tracking ─────────────────────────────────────────────────────────────

local function trackTask(rec: RuleRecord, ruleHandle: any, taskHandle: any, startMs: number)
	rec.InFlight[taskHandle] = true
	rec.InFlightCount += 1

	taskHandle:Finally(function(status: Task.Status, _value: unknown?)
		rec.InFlight[taskHandle] = nil
		rec.InFlightCount -= 1
		local endMs = Scheduler.Now() * 1000
		rec.TotalMs += endMs - startMs
		if status == "Errored" or status == "Cancelled" then
			rec.Errors += 1
			emitTrace("Rule.Error", rec)
		else
			emitTrace("Rule.Done", rec)
		end
		if rec.Policy.Concurrency == "Concat" then
			concatDrain(rec, ruleHandle)
		end
	end)
end

-- ── Run disposer ──────────────────────────────────────────────────────────────

local function runDisposer(rec: RuleRecord)
	local d = rec.Disposer
	rec.Disposer = nil
	if d ~= nil then
		local ok = ErrorHandler.Protect(d, "Rule", "Disposer")
		if not ok then
			rec.Errors += 1
		end
	end
end

-- ── Once cleanup ──────────────────────────────────────────────────────────────

local function doOnce(rec: RuleRecord, ruleHandle: any)
	if rec.EnableCount == 0 then return end
	emitTrace("Rule.Once", rec)
	rec.EnableCount = 0
	if rec.SignalConn ~= nil then
		rec.SignalConn:Disconnect()
		rec.SignalConn = nil
	end
	if rec.GuardWatchConn ~= nil then
		rec.GuardWatchConn:Disconnect()
		rec.GuardWatchConn = nil
	end
	Scheduler.Cancel(rec.DebounceTimerHandle)
	rec.DebounceTimerHandle = nil
	rec.DebouncePending = nil
	Scheduler.Cancel(rec.ThrottleTimerHandle)
	rec.ThrottleTimerHandle = nil
	rec.ThrottleWindowActive = false
	rec.ThrottlePending = nil
	table.clear(rec.ConcatQueue)
	rec.ConcatRunning = false
	emitTrace("Rule.Disable", rec)
end

-- ── Effect execution ──────────────────────────────────────────────────────────

runEffect = function(rec: RuleRecord, ruleHandle: any, payload: any)
	if rec.Destroyed or rec.EnableCount == 0 then
		if rec.Policy.Concurrency == "Concat" then
			concatDrain(rec, ruleHandle)
		end
		return
	end

	local ctx = resolveCtx(rec)
	local frame: RuleFrame = {
		RuleName = rec.Policy.Tag or rec.RuleName,
		Now = Scheduler.Now,
		Token = nil,
	}

	if rec.Policy.RecheckGuardBeforeRun then
		if not evalGuard(rec, payload, frame) then
			rec.Skipped += 1
			emitTrace("Rule.Skip", rec)
			if rec.Policy.Concurrency == "Concat" then
				concatDrain(rec, ruleHandle)
			end
			return
		end
	end

	local startMs = Scheduler.Now() * 1000
	rec.Runs += 1
	emitTrace("Rule.Start", rec)

	if rec.Policy.Retry ~= nil then
		local retryOpts = rec.Policy.Retry :: Task.RetryOptions
		local retryTask = Task.Retry(function(token: Task.Token)
			local f: RuleFrame = {
				RuleName = rec.Policy.Tag or rec.RuleName,
				Now = Scheduler.Now,
				Token = token,
			}
			return (rec.EffectFn :: any)(ctx, payload, f)
		end, retryOpts)
		trackTask(rec, ruleHandle, retryTask, startMs)
		if rec.Policy.Once then
			doOnce(rec, ruleHandle)
		end
		return
	end

	local ok, result = pcall(rec.EffectFn :: any, ctx, payload, frame)
	if not ok then
		handleEffectError(rec, result)
		emitTrace("Rule.Error", rec)
		local endMs = Scheduler.Now() * 1000
		rec.TotalMs += endMs - startMs
		if rec.Policy.Concurrency == "Concat" then
			concatDrain(rec, ruleHandle)
		end
		return
	end

	if Task.IsTask(result) then
		trackTask(rec, ruleHandle, result, startMs)
		if rec.Policy.Once then
			doOnce(rec, ruleHandle)
		end
		return
	end

	local endMs = Scheduler.Now() * 1000
	rec.TotalMs += endMs - startMs

	if type(result) == "function" then
		runDisposer(rec)
		rec.Disposer = result :: () -> ()
	end
	-- nil or other: ignored success

	emitTrace("Rule.Done", rec)
	if rec.Policy.Concurrency == "Concat" then
		concatDrain(rec, ruleHandle)
	end
	if rec.Policy.Once then
		doOnce(rec, ruleHandle)
	end
end

-- ── Concurrency admission ─────────────────────────────────────────────────────

local function processPayload(rec: RuleRecord, ruleHandle: any, payload: any)
	if rec.Destroyed or rec.EnableCount == 0 then return end

	local frame: RuleFrame = {
		RuleName = rec.Policy.Tag or rec.RuleName,
		Now = Scheduler.Now,
		Token = nil,
	}

	-- Cooldown check
	if rec.Policy.Cooldown ~= nil then
		local now = Scheduler.Now()
		if rec.LastAdmitTime ~= nil and (now - rec.LastAdmitTime) < (rec.Policy.Cooldown :: number) then
			rec.Skipped += 1
			emitTrace("Rule.Skip", rec)
			return
		end
	end

	-- Guard check
	if not evalGuard(rec, payload, frame) then
		rec.Skipped += 1
		emitTrace("Rule.Skip", rec)
		return
	end

	-- Concurrency policy
	local concurrency = rec.Policy.Concurrency

	if concurrency == "Exhaust" then
		if rec.InFlightCount > 0 then
			rec.Skipped += 1
			emitTrace("Rule.Skip", rec)
			return
		end
	elseif concurrency == "Merge" then
		if rec.InFlightCount >= rec.Policy.Capacity then
			rec.Skipped += 1
			emitTrace("Rule.Skip", rec)
			return
		end
	elseif concurrency == "Concat" then
		if rec.ConcatRunning then
			local qlen = #rec.ConcatQueue
			if qlen >= rec.Policy.Capacity then
				local overflow = rec.Policy.Overflow
				if overflow == "Drop" then
					rec.Skipped += 1
					emitTrace("Rule.Skip", rec)
					return
				elseif overflow == "Latest" then
					rec.ConcatQueue[qlen] = { HasValue = true, Value = payload }
					return
				elseif overflow == "Fifo" then
					table.remove(rec.ConcatQueue, 1)
					table.insert(rec.ConcatQueue, { HasValue = true, Value = payload })
					return
				end
			else
				table.insert(rec.ConcatQueue, { HasValue = true, Value = payload })
				return
			end
		else
			rec.ConcatRunning = true
		end
	elseif concurrency == "Switch" then
		local toCancel = {}
		for t in rec.InFlight do
			table.insert(toCancel, t)
		end
		for _, t in toCancel do
			(t :: any):Cancel(Task.Reason.Superseded)
		end
		emitTrace("Rule.Cancel", rec)
	end

	rec.LastAdmitTime = Scheduler.Now()
	emitTrace("Rule.Admit", rec)

	if rec.Policy.Schedule == "Immediate" then
		runEffect(rec, ruleHandle, payload)
	else
		Scheduler.Defer(function()
			runEffect(rec, ruleHandle, payload)
		end)
	end
end

-- ── Throttle ──────────────────────────────────────────────────────────────────

local function applyThrottle(rec: RuleRecord, ruleHandle: any, payload: any)
	local throttle = rec.Policy.Throttle :: number
	local leading = rec.Policy.Leading
	local trailing = rec.Policy.Trailing

	if not rec.ThrottleWindowActive then
		rec.ThrottleWindowActive = true
		if trailing then
			rec.ThrottlePending = { HasValue = true, Value = payload }
		end
		rec.ThrottleTimerHandle = Scheduler.Delay(throttle, function()
			rec.ThrottleWindowActive = false
			rec.ThrottleTimerHandle = nil
			local pending = rec.ThrottlePending
			rec.ThrottlePending = nil
			if trailing and pending ~= nil then
				processPayload(rec, ruleHandle, pending.Value)
			end
		end)
		if leading then
			processPayload(rec, ruleHandle, payload)
		end
	else
		if trailing then
			rec.ThrottlePending = { HasValue = true, Value = payload }
		end
	end
end

-- ── Signal fire handler ───────────────────────────────────────────────────────

local function onSignalFire(rec: RuleRecord, ruleHandle: any, payload: any)
	if rec.Destroyed or rec.EnableCount == 0 then return end

	if rec.Policy.Debounce ~= nil then
		Scheduler.Cancel(rec.DebounceTimerHandle)
		rec.DebouncePending = { HasValue = true, Value = payload }
		rec.DebounceTimerHandle = Scheduler.Delay(rec.Policy.Debounce :: number, function()
			rec.DebounceTimerHandle = nil
			local pending = rec.DebouncePending
			rec.DebouncePending = nil
			if pending ~= nil then
				if rec.Policy.Throttle ~= nil then
					applyThrottle(rec, ruleHandle, pending.Value)
				else
					processPayload(rec, ruleHandle, pending.Value)
				end
			end
		end)
		return
	end

	if rec.Policy.Throttle ~= nil then
		applyThrottle(rec, ruleHandle, payload)
		return
	end

	processPayload(rec, ruleHandle, payload)
end

-- ── Public API ────────────────────────────────────────────────────────────────

local Rule = {} :: any

function Rule.New(name: string): any
	if type(name) ~= "string" or #name == 0 then
		error("Rule.New: name must be a non-empty string", 2)
	end

	local rec: RuleRecord = {
		Destroyed = false,
		EnableCount = 0,
		RuleName = name,
		SignalHandle = nil,
		GuardValue = nil,
		EffectFn = nil,
		WithCtxHandle = nil,
		EnableCtxHandle = nil,
		AttachScope = nil,
		Policy = makeDefaultPolicy(),
		SignalConn = nil,
		GuardWatchConn = nil,
		DebounceTimerHandle = nil,
		DebouncePending = nil,
		ThrottleWindowActive = false,
		ThrottleTimerHandle = nil,
		ThrottlePending = nil,
		LastAdmitTime = nil,
		InFlight = {},
		InFlightCount = 0,
		ConcatQueue = {},
		ConcatRunning = false,
		Disposer = nil,
		Runs = 0,
		Skipped = 0,
		Errors = 0,
		TotalMs = 0,
		CollectedErrors = {},
	}
	local handle = setmetatable({}, ruleMeta)
	ruleRecords[handle] = rec
	return handle
end

function Rule.IsRule(value: unknown): boolean
	return type(value) == "table"
		and getmetatable(value :: any) == "Rule"
		and ruleRecords[value :: any] ~= nil
end

function Rule.DefaultPolicy(): Policy
	return makeDefaultPolicy() :: Policy
end

function Rule.ValidatePolicy(policy: PartialPolicy): (boolean, string?)
	return validatePolicy(policy)
end

function Rule.SetTracer(fn: ((TraceEvent) -> ())?): ()
	if fn ~= nil and type(fn) ~= "function" then
		error("Rule.SetTracer: fn must be a function or nil", 2)
	end
	_tracer = fn
end

-- Internal: get rules attached to a scope (used by FSM)
function Rule._getAttachedRules(scope: any): { any }
	return _scopeAttach[scope] or {}
end

-- ── Instance methods ──────────────────────────────────────────────────────────

function ruleMethods:On(signal: Signal.Signal<any>): any
	local rec = ruleRecords[self]
	if rec == nil or rec.Destroyed then
		error("Rule.On: rule is destroyed", 2)
	end
	if rec.EnableCount > 0 then
		error("Rule.On: cannot configure while enabled", 2)
	end
	if not Signal.IsSignal(signal :: any) or (signal :: any):IsDestroyed() then
		error("Rule.On: signal must be a live Signal", 2)
	end
	rec.SignalHandle = signal
	return self
end

function ruleMethods:When(guard: any): any
	local rec = ruleRecords[self]
	if rec == nil or rec.Destroyed then
		error("Rule.When: rule is destroyed", 2)
	end
	if rec.EnableCount > 0 then
		error("Rule.When: cannot configure while enabled", 2)
	end
	if not Store.IsStore(guard) and type(guard) ~= "function" then
		error("Rule.When: guard must be a Store or function", 2)
	end
	rec.GuardValue = guard
	return self
end

function ruleMethods:Run(effect: any): any
	local rec = ruleRecords[self]
	if rec == nil or rec.Destroyed then
		error("Rule.Run: rule is destroyed", 2)
	end
	if rec.EnableCount > 0 then
		error("Rule.Run: cannot configure while enabled", 2)
	end
	if type(effect) ~= "function" then
		error("Rule.Run: effect must be a function", 2)
	end
	rec.EffectFn = effect
	return self
end

function ruleMethods:Policy(policy: any): any
	local rec = ruleRecords[self]
	if rec == nil or rec.Destroyed then
		error("Rule.Policy: rule is destroyed", 2)
	end
	if rec.EnableCount > 0 then
		error("Rule.Policy: cannot configure while enabled", 2)
	end
	local ok, msg = validatePolicy(policy)
	if not ok then
		error("Rule.Policy: " .. (msg :: string), 2)
	end
	local defaults = makeDefaultPolicy()
	for k, v in policy do
		(defaults :: any)[k] = v
	end
	rec.Policy = defaults
	return self
end

function ruleMethods:WithContext(ctx: any): any
	local rec = ruleRecords[self]
	if rec == nil or rec.Destroyed then
		error("Rule.WithContext: rule is destroyed", 2)
	end
	if rec.EnableCount > 0 then
		error("Rule.WithContext: cannot configure while enabled", 2)
	end
	if not Context.IsContext(ctx) then
		error("Rule.WithContext: ctx must be a Context", 2)
	end
	rec.WithCtxHandle = ctx
	return self
end

function ruleMethods:Attach(scope: any): any
	local rec = ruleRecords[self]
	if rec == nil or rec.Destroyed then
		error("Rule.Attach: rule is destroyed", 2)
	end
	local mt = getmetatable(scope :: any)
	if mt ~= "FSM" and mt ~= "FSMMode" then
		error("Rule.Attach: scope must be an FSM or FSM Mode", 2)
	end
	rec.AttachScope = scope
	if not _scopeAttach[scope] then
		_scopeAttach[scope] = {}
	end
	table.insert(_scopeAttach[scope], self)
	return self
end

function ruleMethods:Enable(ctx: any?): any
	local rec = ruleRecords[self]
	if rec == nil or rec.Destroyed then
		error("Rule.Enable: rule is destroyed", 2)
	end
	if rec.SignalHandle == nil then
		error("Rule.Enable: signal is not configured", 2)
	end
	if rec.EffectFn == nil then
		error("Rule.Enable: effect is not configured", 2)
	end
	if ctx ~= nil and not Context.IsContext(ctx) then
		error("Rule.Enable: ctx must be Context", 2)
	end

	if ctx ~= nil then
		rec.EnableCtxHandle = ctx
	end

	rec.EnableCount += 1

	if rec.EnableCount == 1 then
		local ruleHandle = self
		rec.SignalConn = (rec.SignalHandle :: any):Connect(function(payload: any)
			onSignalFire(rec, ruleHandle, payload)
		end)

		if rec.Policy.CancelTasksWhenGuardFalse and Store.IsStore(rec.GuardValue) then
			rec.GuardWatchConn = (rec.GuardValue :: any):Subscribe(function(value: any)
				if value ~= true then
					local toCancel = {}
					for t in rec.InFlight do
						table.insert(toCancel, t)
					end
					for _, t in toCancel do
						(t :: any):Cancel(Task.Reason.GuardFalse)
					end
				end
			end, { Immediate = false })
		end

		emitTrace("Rule.Enable", rec)
	end

	return self
end

function ruleMethods:Disable(): ()
	local rec = ruleRecords[self]
	if rec == nil then return end
	if rec.EnableCount == 0 then return end
	rec.EnableCount -= 1
	if rec.EnableCount > 0 then return end

	if rec.SignalConn ~= nil then
		rec.SignalConn:Disconnect()
		rec.SignalConn = nil
	end
	if rec.GuardWatchConn ~= nil then
		rec.GuardWatchConn:Disconnect()
		rec.GuardWatchConn = nil
	end

	local toCancel = {}
	for t in rec.InFlight do
		table.insert(toCancel, t)
	end
	for _, t in toCancel do
		(t :: any):Cancel(Task.Reason.ModeExit)
	end

	runDisposer(rec)

	Scheduler.Cancel(rec.DebounceTimerHandle)
	rec.DebounceTimerHandle = nil
	rec.DebouncePending = nil
	Scheduler.Cancel(rec.ThrottleTimerHandle)
	rec.ThrottleTimerHandle = nil
	rec.ThrottleWindowActive = false
	rec.ThrottlePending = nil
	table.clear(rec.ConcatQueue)
	rec.ConcatRunning = false

	emitTrace("Rule.Disable", rec)
end

function ruleMethods:Destroy(): ()
	local rec = ruleRecords[self]
	if rec == nil or rec.Destroyed then return end

	-- Force disable regardless of count
	if rec.EnableCount > 0 then
		rec.EnableCount = 1
		ruleMethods.Disable(self)
	end

	rec.Destroyed = true
	rec.EnableCount = 0

	rec.SignalHandle = nil
	rec.GuardValue = nil
	rec.EffectFn = nil
	rec.WithCtxHandle = nil
	rec.EnableCtxHandle = nil

	emitTrace("Rule.Destroy", rec)
end

function ruleMethods:IsEnabled(): boolean
	local rec = ruleRecords[self]
	if rec == nil then return false end
	return rec.EnableCount > 0
end

function ruleMethods:IsDestroyed(): boolean
	local rec = ruleRecords[self]
	if rec == nil then return true end
	return rec.Destroyed
end

function ruleMethods:Name(): string
	local rec = ruleRecords[self]
	if rec == nil then
		error("Rule.Name: invalid rule handle", 2)
	end
	return if rec.Policy.Tag ~= nil then rec.Policy.Tag :: string else rec.RuleName
end

function ruleMethods:Metrics(): Metrics
	local rec = ruleRecords[self]
	if rec == nil then
		error("Rule.Metrics: invalid rule handle", 2)
	end
	return {
		Runs = rec.Runs,
		Skipped = rec.Skipped,
		Errors = rec.Errors,
		AvgMs = if rec.Runs > 0 then rec.TotalMs / rec.Runs else 0,
		CollectedErrors = table.clone(rec.CollectedErrors),
	}
end

function ruleMethods:ResetMetrics(): ()
	local rec = ruleRecords[self]
	if rec == nil then
		error("Rule.ResetMetrics: invalid rule handle", 2)
	end
	rec.Runs = 0
	rec.Skipped = 0
	rec.Errors = 0
	rec.TotalMs = 0
	table.clear(rec.CollectedErrors)
end

-- Enum tables: use Rule.Concurrency.Exhaust etc. instead of raw strings in Policy.
Rule.Concurrency = table.freeze({
	Exhaust = "Exhaust" :: "Exhaust",
	Merge = "Merge" :: "Merge",
	Concat = "Concat" :: "Concat",
	Switch = "Switch" :: "Switch",
})

Rule.Overflow = table.freeze({
	Drop = "Drop" :: "Drop",
	Latest = "Latest" :: "Latest",
	Fifo = "Fifo" :: "Fifo",
})

Rule.Schedule = table.freeze({
	Immediate = "Immediate" :: "Immediate",
	Deferred = "Deferred" :: "Deferred",
})

return Rule
