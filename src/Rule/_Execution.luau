--!strict

local Connection = require(script.Parent.Parent.Connection)
local Context = require(script.Parent.Parent.Context)
local ErrorHandler = require(script.Parent.Parent.ErrorHandler)
local Scheduler = require(script.Parent.Parent.Scheduler)
local Signal = require(script.Parent.Parent.Signal)
local Store = require(script.Parent.Parent.Store)
local Task = require(script.Parent.Parent.Task)

local Policy = require(script.Parent._Policy)
local Types = require(script.Parent._Types)

export type Concurrency = Types.Concurrency
export type Overflow = Types.Overflow
export type Schedule = Types.Schedule
export type ConcurrencySet = Types.ConcurrencySet
export type OverflowSet = Types.OverflowSet
export type ScheduleSet = Types.ScheduleSet
export type RuleFrame = Types.RuleFrame
export type Guard<Ctx, Payload> = Types.Guard<Ctx, Payload>
export type Effect<Ctx, Payload> = Types.Effect<Ctx, Payload>
export type RetryOptions = Types.RetryOptions
export type Policy = Types.Policy
export type PartialPolicy = Types.PartialPolicy
export type Metrics = Types.Metrics
export type TraceEvent = Types.TraceEvent
export type Rule<Ctx, Payload> = Types.Rule<Ctx, Payload>
export type RuleModule = Types.RuleModule

-- ── Internal record ───────────────────────────────────────────────────────────

type PolicyRecord = {
	Concurrency: Concurrency,
	Capacity: number,
	Overflow: Overflow,
	Cooldown: number?,
	Debounce: number?,
	Throttle: number?,
	Leading: boolean,
	Trailing: boolean,
	Schedule: Schedule,
	RecheckGuardBeforeRun: boolean,
	CancelTasksWhenGuardFalse: boolean,
	Once: boolean,
	ErrorPolicy: ErrorHandler.Policy?,
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

local ruleRecords: { [any]: RuleRecord } = setmetatable({}, { __mode = "k" }) :: any

-- Scope → list of rule handles (for FSM to query)
local attachedRulesByScope: { [any]: { any } } = setmetatable({}, { __mode = "k" }) :: any

-- ── Tracer ────────────────────────────────────────────────────────────────────

local activeTracer: ((TraceEvent) -> ())? = nil

local function emitTrace(event: string, ruleRecord: RuleRecord)
	if activeTracer == nil then return end
	local fn = activeTracer :: (TraceEvent) -> ()
	ErrorHandler.Protect(function()
		fn({ Event = event, RuleName = ruleRecord.RuleName, Tag = ruleRecord.Policy.Tag })
	end, "Rule", "Trace")
end

-- ── Metatable ─────────────────────────────────────────────────────────────────

local ruleMethods = {}

local ruleMeta = {
	__metatable = "Rule",
	__index = ruleMethods,
	__newindex = function(_, k: string)
		ErrorHandler.RaiseUsageError(`Rule: '{k}' is read-only`)
	end,
}

-- ── Effect error handler ──────────────────────────────────────────────────────

local function handleEffectError(ruleRecord: RuleRecord, err: unknown): ()
	ruleRecord.Errors += 1
	local errorInfo: ErrorHandler.ErrorInfo = { Module = "Rule", Phase = "Effect", Name = ruleRecord.RuleName, Error = err }
	local errorPolicy = ruleRecord.Policy.ErrorPolicy
	if errorPolicy ~= nil then
		ErrorHandler.ReportWithPolicy(errorInfo, errorPolicy)
		if errorPolicy == ErrorHandler.Policy.Collect then
			table.insert(ruleRecord.CollectedErrors, err)
		end
	else
		ErrorHandler.Report(errorInfo)
	end
end

-- ── Context resolution ────────────────────────────────────────────────────────

local emptyRootContext: any = nil

local function resolveCtx(ruleRecord: RuleRecord): any
	if ruleRecord.WithCtxHandle ~= nil then
		return ruleRecord.WithCtxHandle
	end
	if ruleRecord.EnableCtxHandle ~= nil then
		return ruleRecord.EnableCtxHandle
	end
	if emptyRootContext == nil then
		emptyRootContext = Context.Root({})
	end
	return emptyRootContext
end

-- ── Guard evaluation ──────────────────────────────────────────────────────────

local function evalGuard(ruleRecord: RuleRecord, payload: any, frame: RuleFrame): boolean
	local g = ruleRecord.GuardValue
	if g == nil then
		return true
	end
	if Store.IsStore(g) then
		local ok, result = ErrorHandler.Protect(function() return (g :: any):Get() end, "Rule", "Guard")
		if not ok then
			ruleRecord.Errors += 1
			return false
		end
		return result == true
	else
		local ctx = resolveCtx(ruleRecord)
		local ok, result = ErrorHandler.Protect(function() return (g :: any)(ctx, payload, frame) end, "Rule", "Guard")
		if not ok then
			ruleRecord.Errors += 1
			return false
		end
		return result == true
	end
end

-- ── Concat drain ──────────────────────────────────────────────────────────────

local runEffect: (ruleRecord: RuleRecord, ruleHandle: any, payload: any) -> ()

local function concatDrain(ruleRecord: RuleRecord, ruleHandle: any)
	if #ruleRecord.ConcatQueue == 0 then
		ruleRecord.ConcatRunning = false
		return
	end
	local slot = table.remove(ruleRecord.ConcatQueue, 1) :: PayloadSlot
	runEffect(ruleRecord, ruleHandle, slot.Value)
end

-- ── Task tracking ─────────────────────────────────────────────────────────────

local function trackTask(ruleRecord: RuleRecord, ruleHandle: any, taskHandle: any, startMs: number)
	ruleRecord.InFlight[taskHandle] = true
	ruleRecord.InFlightCount += 1

	taskHandle:Finally(function(status: Task.Status, _value: unknown?)
		ruleRecord.InFlight[taskHandle] = nil
		ruleRecord.InFlightCount -= 1
		local endMs = Scheduler.Now() * 1000
		ruleRecord.TotalMs += endMs - startMs
		if status == "Errored" or status == "Cancelled" then
			ruleRecord.Errors += 1
			emitTrace("Rule.Error", ruleRecord)
		else
			emitTrace("Rule.Done", ruleRecord)
		end
		if ruleRecord.Policy.Concurrency == "Concat" then
			concatDrain(ruleRecord, ruleHandle)
		end
	end)
end

-- ── Run disposer ──────────────────────────────────────────────────────────────

local function runDisposer(ruleRecord: RuleRecord)
	local d = ruleRecord.Disposer
	ruleRecord.Disposer = nil
	if d ~= nil then
		local ok = ErrorHandler.Protect(d, "Rule", "Disposer")
		if not ok then
			ruleRecord.Errors += 1
		end
	end
end

-- ── Once cleanup ──────────────────────────────────────────────────────────────

local function doOnce(ruleRecord: RuleRecord, ruleHandle: any)
	if ruleRecord.EnableCount == 0 then return end
	emitTrace("Rule.Once", ruleRecord)
	ruleRecord.EnableCount = 0
	if ruleRecord.SignalConn ~= nil then
		ruleRecord.SignalConn:Disconnect()
		ruleRecord.SignalConn = nil
	end
	if ruleRecord.GuardWatchConn ~= nil then
		ruleRecord.GuardWatchConn:Disconnect()
		ruleRecord.GuardWatchConn = nil
	end
	Scheduler.Cancel(ruleRecord.DebounceTimerHandle)
	ruleRecord.DebounceTimerHandle = nil
	ruleRecord.DebouncePending = nil
	Scheduler.Cancel(ruleRecord.ThrottleTimerHandle)
	ruleRecord.ThrottleTimerHandle = nil
	ruleRecord.ThrottleWindowActive = false
	ruleRecord.ThrottlePending = nil
	table.clear(ruleRecord.ConcatQueue)
	ruleRecord.ConcatRunning = false
	emitTrace("Rule.Disable", ruleRecord)
end

-- ── Effect execution ──────────────────────────────────────────────────────────

runEffect = function(ruleRecord: RuleRecord, ruleHandle: any, payload: any)
	if ruleRecord.Destroyed or ruleRecord.EnableCount == 0 then
		if ruleRecord.Policy.Concurrency == "Concat" then
			concatDrain(ruleRecord, ruleHandle)
		end
		return
	end

	local ctx = resolveCtx(ruleRecord)
	local frame: RuleFrame = {
		RuleName = ruleRecord.Policy.Tag or ruleRecord.RuleName,
		Now = Scheduler.Now,
		Token = nil,
	}

	if ruleRecord.Policy.RecheckGuardBeforeRun then
		if not evalGuard(ruleRecord, payload, frame) then
			ruleRecord.Skipped += 1
			emitTrace("Rule.Skip", ruleRecord)
			if ruleRecord.Policy.Concurrency == "Concat" then
				concatDrain(ruleRecord, ruleHandle)
			end
			return
		end
	end

	local startMs = Scheduler.Now() * 1000
	ruleRecord.Runs += 1
	emitTrace("Rule.Start", ruleRecord)

	if ruleRecord.Policy.Retry ~= nil then
		local retryOpts = ruleRecord.Policy.Retry :: Task.RetryOptions
		local retryTask = Task.Retry(function(token: Task.Token)
			local f: RuleFrame = {
				RuleName = ruleRecord.Policy.Tag or ruleRecord.RuleName,
				Now = Scheduler.Now,
				Token = token,
			}
			return (ruleRecord.EffectFn :: any)(ctx, payload, f)
		end, retryOpts)
		trackTask(ruleRecord, ruleHandle, retryTask, startMs)
		if ruleRecord.Policy.Once then
			doOnce(ruleRecord, ruleHandle)
		end
		return
	end

	local ok, result = pcall(ruleRecord.EffectFn :: any, ctx, payload, frame)
	if not ok then
		handleEffectError(ruleRecord, result)
		emitTrace("Rule.Error", ruleRecord)
		local endMs = Scheduler.Now() * 1000
		ruleRecord.TotalMs += endMs - startMs
		if ruleRecord.Policy.Concurrency == "Concat" then
			concatDrain(ruleRecord, ruleHandle)
		end
		return
	end

	if Task.IsTask(result) then
		trackTask(ruleRecord, ruleHandle, result, startMs)
		if ruleRecord.Policy.Once then
			doOnce(ruleRecord, ruleHandle)
		end
		return
	end

	local endMs = Scheduler.Now() * 1000
	ruleRecord.TotalMs += endMs - startMs

	if type(result) == "function" then
		runDisposer(ruleRecord)
		ruleRecord.Disposer = result :: () -> ()
	end
	-- nil or other: ignored success

	emitTrace("Rule.Done", ruleRecord)
	if ruleRecord.Policy.Concurrency == "Concat" then
		concatDrain(ruleRecord, ruleHandle)
	end
	if ruleRecord.Policy.Once then
		doOnce(ruleRecord, ruleHandle)
	end
end

-- ── Concurrency admission ─────────────────────────────────────────────────────

local function processPayload(ruleRecord: RuleRecord, ruleHandle: any, payload: any)
	if ruleRecord.Destroyed or ruleRecord.EnableCount == 0 then return end

	local frame: RuleFrame = {
		RuleName = ruleRecord.Policy.Tag or ruleRecord.RuleName,
		Now = Scheduler.Now,
		Token = nil,
	}

	-- Cooldown check
	if ruleRecord.Policy.Cooldown ~= nil then
		local now = Scheduler.Now()
		if ruleRecord.LastAdmitTime ~= nil and (now - ruleRecord.LastAdmitTime) < (ruleRecord.Policy.Cooldown :: number) then
			ruleRecord.Skipped += 1
			emitTrace("Rule.Skip", ruleRecord)
			return
		end
	end

	-- Guard check
	if not evalGuard(ruleRecord, payload, frame) then
		ruleRecord.Skipped += 1
		emitTrace("Rule.Skip", ruleRecord)
		return
	end

	-- Concurrency policy
	local concurrency = ruleRecord.Policy.Concurrency

	if concurrency == "Exhaust" then
		if ruleRecord.InFlightCount > 0 then
			ruleRecord.Skipped += 1
			emitTrace("Rule.Skip", ruleRecord)
			return
		end
	elseif concurrency == "Merge" then
		if ruleRecord.InFlightCount >= ruleRecord.Policy.Capacity then
			ruleRecord.Skipped += 1
			emitTrace("Rule.Skip", ruleRecord)
			return
		end
	elseif concurrency == "Concat" then
		if ruleRecord.ConcatRunning then
			local qlen = #ruleRecord.ConcatQueue
			if qlen >= ruleRecord.Policy.Capacity then
				local overflow = ruleRecord.Policy.Overflow
				if overflow == "Drop" then
					ruleRecord.Skipped += 1
					emitTrace("Rule.Skip", ruleRecord)
					return
				elseif overflow == "Latest" then
					ruleRecord.ConcatQueue[qlen] = { HasValue = true, Value = payload }
					return
				elseif overflow == "Fifo" then
					table.remove(ruleRecord.ConcatQueue, 1)
					table.insert(ruleRecord.ConcatQueue, { HasValue = true, Value = payload })
					return
				end
			else
				table.insert(ruleRecord.ConcatQueue, { HasValue = true, Value = payload })
				return
			end
		else
			ruleRecord.ConcatRunning = true
		end
	elseif concurrency == "Switch" then
		local toCancel = {}
		for t in ruleRecord.InFlight do
			table.insert(toCancel, t)
		end
		for _, t in toCancel do
			(t :: any):Cancel(Task.Reason.Superseded)
		end
		emitTrace("Rule.Cancel", ruleRecord)
	end

	ruleRecord.LastAdmitTime = Scheduler.Now()
	emitTrace("Rule.Admit", ruleRecord)

	if ruleRecord.Policy.Schedule == "Immediate" then
		runEffect(ruleRecord, ruleHandle, payload)
	else
		Scheduler.Defer(function()
			runEffect(ruleRecord, ruleHandle, payload)
		end)
	end
end

-- ── Throttle ──────────────────────────────────────────────────────────────────

local function applyThrottle(ruleRecord: RuleRecord, ruleHandle: any, payload: any)
	local throttle = ruleRecord.Policy.Throttle :: number
	local leading = ruleRecord.Policy.Leading
	local trailing = ruleRecord.Policy.Trailing

	if not ruleRecord.ThrottleWindowActive then
		ruleRecord.ThrottleWindowActive = true
		if trailing then
			ruleRecord.ThrottlePending = { HasValue = true, Value = payload }
		end
		ruleRecord.ThrottleTimerHandle = Scheduler.Delay(throttle, function()
			ruleRecord.ThrottleWindowActive = false
			ruleRecord.ThrottleTimerHandle = nil
			local pending = ruleRecord.ThrottlePending
			ruleRecord.ThrottlePending = nil
			if trailing and pending ~= nil then
				processPayload(ruleRecord, ruleHandle, pending.Value)
			end
		end)
		if leading then
			processPayload(ruleRecord, ruleHandle, payload)
		end
	else
		if trailing then
			ruleRecord.ThrottlePending = { HasValue = true, Value = payload }
		end
	end
end

-- ── Signal fire handler ───────────────────────────────────────────────────────

local function onSignalFire(ruleRecord: RuleRecord, ruleHandle: any, payload: any)
	if ruleRecord.Destroyed or ruleRecord.EnableCount == 0 then return end

	if ruleRecord.Policy.Debounce ~= nil then
		Scheduler.Cancel(ruleRecord.DebounceTimerHandle)
		ruleRecord.DebouncePending = { HasValue = true, Value = payload }
		ruleRecord.DebounceTimerHandle = Scheduler.Delay(ruleRecord.Policy.Debounce :: number, function()
			ruleRecord.DebounceTimerHandle = nil
			local pending = ruleRecord.DebouncePending
			ruleRecord.DebouncePending = nil
			if pending ~= nil then
				if ruleRecord.Policy.Throttle ~= nil then
					applyThrottle(ruleRecord, ruleHandle, pending.Value)
				else
					processPayload(ruleRecord, ruleHandle, pending.Value)
				end
			end
		end)
		return
	end

	if ruleRecord.Policy.Throttle ~= nil then
		applyThrottle(ruleRecord, ruleHandle, payload)
		return
	end

	processPayload(ruleRecord, ruleHandle, payload)
end

-- ── Public API ────────────────────────────────────────────────────────────────

local Rule = {} :: any

function Rule.New<Ctx, Payload>(name: string): Rule<Ctx, Payload>
	if type(name) ~= "string" or #name == 0 then
		ErrorHandler.RaiseUsageError("Rule.New: name must be a non-empty string")
	end

	local ruleRecord: RuleRecord = {
		Destroyed = false,
		EnableCount = 0,
		RuleName = name,
		SignalHandle = nil,
		GuardValue = nil,
		EffectFn = nil,
		WithCtxHandle = nil,
		EnableCtxHandle = nil,
		AttachScope = nil,
		Policy = Policy.createDefaultPolicy(),
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
	} :: any
	local handle = setmetatable({}, ruleMeta)
	ruleRecords[handle] = ruleRecord
	return handle :: any
end

function Rule.IsRule(value: unknown): boolean
	return type(value) == "table"
		and getmetatable(value :: any) == "Rule"
		and ruleRecords[value :: any] ~= nil
end

function Rule.DefaultPolicy(): Policy
	return (Policy.createDefaultPolicy() :: any) :: Policy
end

function Rule.ValidatePolicy(policy: PartialPolicy): (boolean, string?)
	return Policy.validatePolicy(policy :: any)
end

function Rule.SetTracer(fn: ((TraceEvent) -> ())?): ()
	if fn ~= nil and type(fn) ~= "function" then
		ErrorHandler.RaiseUsageError("Rule.SetTracer: fn must be a function or nil")
	end
	activeTracer = fn
end

-- Internal: get rules attached to a scope (used by FSM)
function Rule._getAttachedRules(scope: any): { Rule<any, any> }
	return attachedRulesByScope[scope] or {}
end

-- ── Instance methods ──────────────────────────────────────────────────────────

function ruleMethods:On(signal: Signal.Signal<any>): any
	local ruleRecord = ruleRecords[self]
	if ruleRecord == nil or ruleRecord.Destroyed then
		ErrorHandler.RaiseUsageError("Rule.On: rule is destroyed")
	end
	if ruleRecord.EnableCount > 0 then
		ErrorHandler.RaiseUsageError("Rule.On: cannot configure while enabled")
	end
	if not Signal.IsSignal(signal :: any) or (signal :: any):IsDestroyed() then
		ErrorHandler.RaiseUsageError("Rule.On: signal must be a live Signal")
	end
	ruleRecord.SignalHandle = signal
	return self
end

function ruleMethods:When(guard: any): any
	local ruleRecord = ruleRecords[self]
	if ruleRecord == nil or ruleRecord.Destroyed then
		ErrorHandler.RaiseUsageError("Rule.When: rule is destroyed")
	end
	if ruleRecord.EnableCount > 0 then
		ErrorHandler.RaiseUsageError("Rule.When: cannot configure while enabled")
	end
	if not Store.IsStore(guard) and type(guard) ~= "function" then
		ErrorHandler.RaiseUsageError("Rule.When: guard must be a Store or function")
	end
	ruleRecord.GuardValue = guard
	return self
end

function ruleMethods:Run(effect: any): any
	local ruleRecord = ruleRecords[self]
	if ruleRecord == nil or ruleRecord.Destroyed then
		ErrorHandler.RaiseUsageError("Rule.Run: rule is destroyed")
	end
	if ruleRecord.EnableCount > 0 then
		ErrorHandler.RaiseUsageError("Rule.Run: cannot configure while enabled")
	end
	if type(effect) ~= "function" then
		ErrorHandler.RaiseUsageError("Rule.Run: effect must be a function")
	end
	ruleRecord.EffectFn = effect
	return self
end

function ruleMethods:Policy(policy: any): any
	local ruleRecord = ruleRecords[self]
	if ruleRecord == nil or ruleRecord.Destroyed then
		ErrorHandler.RaiseUsageError("Rule.Policy: rule is destroyed")
	end
	if ruleRecord.EnableCount > 0 then
		ErrorHandler.RaiseUsageError("Rule.Policy: cannot configure while enabled")
	end
	local ok, msg = Policy.validatePolicy(policy)
	if not ok then
		ErrorHandler.RaiseUsageError("Rule.Policy: " .. (msg :: string))
	end
	local defaults = Policy.createDefaultPolicy()
	for k, v in policy do
		(defaults :: any)[k] = v
	end
	ruleRecord.Policy = defaults :: any
	return self
end

function ruleMethods:WithContext(ctx: any): any
	local ruleRecord = ruleRecords[self]
	if ruleRecord == nil or ruleRecord.Destroyed then
		ErrorHandler.RaiseUsageError("Rule.WithContext: rule is destroyed")
	end
	if ruleRecord.EnableCount > 0 then
		ErrorHandler.RaiseUsageError("Rule.WithContext: cannot configure while enabled")
	end
	if not Context.IsContext(ctx) then
		ErrorHandler.RaiseUsageError("Rule.WithContext: ctx must be a Context")
	end
	ruleRecord.WithCtxHandle = ctx
	return self
end

function ruleMethods:Attach(scope: any): any
	local ruleRecord = ruleRecords[self]
	if ruleRecord == nil or ruleRecord.Destroyed then
		ErrorHandler.RaiseUsageError("Rule.Attach: rule is destroyed")
	end
	local mt = getmetatable(scope :: any)
	if mt ~= "FSM" and mt ~= "FSMMode" then
		ErrorHandler.RaiseUsageError("Rule.Attach: scope must be an FSM or FSM Mode")
	end
	ruleRecord.AttachScope = scope
	if not attachedRulesByScope[scope] then
		attachedRulesByScope[scope] = {}
	end
	table.insert(attachedRulesByScope[scope], self)
	return self
end

function ruleMethods:Enable(ctx: any?): any
	local ruleRecord = ruleRecords[self]
	if ruleRecord == nil or ruleRecord.Destroyed then
		ErrorHandler.RaiseUsageError("Rule.Enable: rule is destroyed")
	end
	if ruleRecord.SignalHandle == nil then
		ErrorHandler.RaiseUsageError("Rule.Enable: signal is not configured")
	end
	if ruleRecord.EffectFn == nil then
		ErrorHandler.RaiseUsageError("Rule.Enable: effect is not configured")
	end
	if ctx ~= nil and not Context.IsContext(ctx) then
		ErrorHandler.RaiseUsageError("Rule.Enable: ctx must be Context")
	end

	if ctx ~= nil then
		ruleRecord.EnableCtxHandle = ctx
	end

	ruleRecord.EnableCount += 1

	if ruleRecord.EnableCount == 1 then
		local ruleHandle = self
		ruleRecord.SignalConn = (ruleRecord.SignalHandle :: any):Connect(function(payload: any)
			onSignalFire(ruleRecord, ruleHandle, payload)
		end)

		if ruleRecord.Policy.CancelTasksWhenGuardFalse and Store.IsStore(ruleRecord.GuardValue) then
			ruleRecord.GuardWatchConn = (ruleRecord.GuardValue :: any):Subscribe(function(value: any)
				if value ~= true then
					local toCancel = {}
					for t in ruleRecord.InFlight do
						table.insert(toCancel, t)
					end
					for _, t in toCancel do
						(t :: any):Cancel(Task.Reason.GuardFalse)
					end
				end
			end, { Immediate = false })
		end

		emitTrace("Rule.Enable", ruleRecord)
	end

	return self
end

function ruleMethods:Disable(): ()
	local ruleRecord = ruleRecords[self]
	if ruleRecord == nil then return end
	if ruleRecord.EnableCount == 0 then return end
	ruleRecord.EnableCount -= 1
	if ruleRecord.EnableCount > 0 then return end

	if ruleRecord.SignalConn ~= nil then
		ruleRecord.SignalConn:Disconnect()
		ruleRecord.SignalConn = nil
	end
	if ruleRecord.GuardWatchConn ~= nil then
		ruleRecord.GuardWatchConn:Disconnect()
		ruleRecord.GuardWatchConn = nil
	end

	local toCancel = {}
	for t in ruleRecord.InFlight do
		table.insert(toCancel, t)
	end
	for _, t in toCancel do
		(t :: any):Cancel(Task.Reason.ModeExit)
	end

	runDisposer(ruleRecord)

	Scheduler.Cancel(ruleRecord.DebounceTimerHandle)
	ruleRecord.DebounceTimerHandle = nil
	ruleRecord.DebouncePending = nil
	Scheduler.Cancel(ruleRecord.ThrottleTimerHandle)
	ruleRecord.ThrottleTimerHandle = nil
	ruleRecord.ThrottleWindowActive = false
	ruleRecord.ThrottlePending = nil
	table.clear(ruleRecord.ConcatQueue)
	ruleRecord.ConcatRunning = false

	emitTrace("Rule.Disable", ruleRecord)
end

function ruleMethods:Destroy(): ()
	local ruleRecord = ruleRecords[self]
	if ruleRecord == nil or ruleRecord.Destroyed then return end

	-- Force disable regardless of count
	if ruleRecord.EnableCount > 0 then
		ruleRecord.EnableCount = 1
		ruleMethods.Disable(self)
	end

	ruleRecord.Destroyed = true
	ruleRecord.EnableCount = 0

	ruleRecord.SignalHandle = nil
	ruleRecord.GuardValue = nil
	ruleRecord.EffectFn = nil
	ruleRecord.WithCtxHandle = nil
	ruleRecord.EnableCtxHandle = nil

	emitTrace("Rule.Destroy", ruleRecord)
end

function ruleMethods:IsEnabled(): boolean
	local ruleRecord = ruleRecords[self]
	if ruleRecord == nil then return false end
	return ruleRecord.EnableCount > 0
end

function ruleMethods:IsDestroyed(): boolean
	local ruleRecord = ruleRecords[self]
	if ruleRecord == nil then return true end
	return ruleRecord.Destroyed
end

function ruleMethods:Name(): string
	local ruleRecord = ruleRecords[self]
	if ruleRecord == nil then
		ErrorHandler.RaiseUsageError("Rule.Name: invalid rule handle")
	end
	return if ruleRecord.Policy.Tag ~= nil then ruleRecord.Policy.Tag :: string else ruleRecord.RuleName
end

function ruleMethods:Metrics(): Metrics
	local ruleRecord = ruleRecords[self]
	if ruleRecord == nil then
		ErrorHandler.RaiseUsageError("Rule.Metrics: invalid rule handle")
	end
	return {
		Runs = ruleRecord.Runs,
		Skipped = ruleRecord.Skipped,
		Errors = ruleRecord.Errors,
		AvgMs = if ruleRecord.Runs > 0 then ruleRecord.TotalMs / ruleRecord.Runs else 0,
		CollectedErrors = table.clone(ruleRecord.CollectedErrors),
	}
end

function ruleMethods:ResetMetrics(): ()
	local ruleRecord = ruleRecords[self]
	if ruleRecord == nil then
		ErrorHandler.RaiseUsageError("Rule.ResetMetrics: invalid rule handle")
	end
	ruleRecord.Runs = 0
	ruleRecord.Skipped = 0
	ruleRecord.Errors = 0
	ruleRecord.TotalMs = 0
	table.clear(ruleRecord.CollectedErrors)
end

-- ── Enum tables ───────────────────────────────────────────────────────────────

local exhaustConcurrency: "Exhaust" = "Exhaust"
local mergeConcurrency: "Merge" = "Merge"
local concatConcurrency: "Concat" = "Concat"
local switchConcurrency: "Switch" = "Switch"

local dropOverflow: "Drop" = "Drop"
local latestOverflow: "Latest" = "Latest"
local fifoOverflow: "Fifo" = "Fifo"

local immediateSchedule: "Immediate" = "Immediate"
local deferredSchedule: "Deferred" = "Deferred"

Rule.Concurrency = table.freeze({
	Exhaust = exhaustConcurrency,
	Merge = mergeConcurrency,
	Concat = concatConcurrency,
	Switch = switchConcurrency,
}) :: ConcurrencySet

Rule.Overflow = table.freeze({
	Drop = dropOverflow,
	Latest = latestOverflow,
	Fifo = fifoOverflow,
}) :: OverflowSet

Rule.Schedule = table.freeze({
	Immediate = immediateSchedule,
	Deferred = deferredSchedule,
}) :: ScheduleSet

return Rule :: Types.RuleModule

