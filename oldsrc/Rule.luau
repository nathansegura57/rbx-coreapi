--!strict
--!optimize 2

-- Rule: declarative reactions.
--   on Signal → when guard → run effect → under policy.
--
-- Safety model (same as Signal/Task)
--   Handles are frozen opaque tables. All mutable state lives in
--   module-private weak tables keyed by identity.
--   __metatable = "Rule" blocks getmetatable().
--
-- Scheduling
--   admitPhase="immediate": effect runs synchronously in the signal handler.
--   admitPhase="endOfFrame" (default): effect deferred via Scheduler.defer.
--
-- Scope protocol
--   :attach(scope) calls scope:_ruleAttached(self). FSM modes implement this
--   to register lifecycle hooks. Standalone rules call :enable()/:disable() manually.
--   Scopes pass context by calling :enable(ctx); this is internal — the public
--   type omits ctx since external callers do not need it.
--
-- Multi-scope attach
--   enable/disable are ref-counted. Rule activates when enableCount 0→1 and
--   deactivates when enableCount 1→0, so a rule attached to two FSM modes
--   stays enabled while either mode is active.
--
-- Method naming
--   :when(guard)  replaces :if(guard)  — "if" is a Lua keyword.
--   :run(effect)  replaces :do(effect) — "do" is a Lua keyword.

local TaskModule      = require(script.Parent.Task)
local SchedulerModule = require(script.Parent.Internal.Scheduler)
local TracerModule    = require(script.Parent.Internal.Tracer)
local RuleTypes       = require(script.Parent.Types.RuleTypes)

local Scheduler = SchedulerModule.Scheduler

-- ── Internal types ─────────────────────────────────────────────────────────────

type Policy = RuleTypes.RulePolicy

type PendingEvent = { payload: any }

type RuleRecord = {
	handle:          any,           -- back-ref to the frozen Rule handle (for once)
	label:           string?,       -- constructor name; policy.tag overrides for display
	enabled:         boolean,
	enableCount:     number,        -- ref-count for multi-scope attach
	destroyed:       boolean,

	-- Builder-phase config (immutable after first enable)
	signal:          any?,          -- Signal handle
	guard:           any?,          -- ReadableStore<boolean> | (ctx, payload?) -> boolean | nil
	guardIsStore:    boolean,       -- duck-typed: guard has :get() method
	effect:          ((any, any?, any?) -> any?)?,
	policy:          Policy,

	-- Runtime
	ctx:             any?,          -- context from scope or manual :enable(ctx)
	signalConnection:  any?,        -- active Connection to signal
	guardConnection:   any?,        -- Connection to guard store :changed() signal

	-- Effect tracking
	inFlightTasks:   { any },       -- running Task handles
	disposer:        (() -> ())?,   -- from effect returning a function

	-- Concat concurrency queue
	concatQueue:     { PendingEvent },
	concatRunning:   boolean,

	-- Timing gates
	lastFireTime:           number,   -- for cooldown; initialised to -math.huge
	debounceThread:         thread?,
	throttleActive:         boolean,
	throttlePendingPayload: any?,
	throttleThread:         thread?,

	-- Lifecycle
	firedCount: number,             -- for once policy

	-- Diagnostics
	metrics: {
		runs:    number,
		skipped: number,
		errors:  number,
		totalMs: number,
	},
}

-- Weak keys: abandoned handles are GC'd without explicit cleanup.
local ruleRecords: { [any]: RuleRecord } =
	setmetatable({}, { __mode = "k" } :: { __mode: "k" }) :: any

-- ── Public types ───────────────────────────────────────────────────────────────

export type Rule       = RuleTypes.Rule
export type RulePolicy = RuleTypes.RulePolicy

-- ── Default policy ─────────────────────────────────────────────────────────────

local DEFAULT_POLICY: Policy = table.freeze({
	priority            = 0,
	concurrency         = "exhaust",
	capacity            = math.huge,
	queue               = "drop",
	errors              = "swallow",
	admitPhase          = "endOfFrame",
	recheckBeforeEffect = false,
	cancelIfGuardFlips  = false,
	once                = false,
	trace               = false,
} :: Policy)

-- ── Diagnostics ────────────────────────────────────────────────────────────────

export type TraceEvent = { event: string, name: string?, extra: any? }

local tracer = TracerModule.create()

local function emitTrace(event: string, ruleRecord: RuleRecord, extra: any?)
	if not tracer.hasHandler() and not ruleRecord.policy.trace then return end
	tracer.emit({ event = event, name = ruleRecord.policy.tag or ruleRecord.label, extra = extra })
end

-- ── Tools (injected as third arg into every effect call) ───────────────────────
-- tools.now is a live closure so it always reflects the current Scheduler.now.

local tools: { [string]: any } = { now = function() return Scheduler.now() end }

-- ── Rule methods table + META (declared early so runEffect can reference) ──────

local ruleMethods = {}

local RULE_META = {
	__metatable = "Rule",
	__newindex  = function(_, key: string) error("Rule: '" .. key .. "' is read-only", 2) end,
	__index     = ruleMethods,
}

-- ── Forward declarations (mutual recursion: runEffect ↔ admitAndSchedule) ─────

local runEffect:        (ruleRecord: RuleRecord, payload: any) -> ()
local admitAndSchedule: (ruleRecord: RuleRecord, payload: any) -> ()

-- ── Admission helpers ──────────────────────────────────────────────────────────

local function checkAdmit(ruleRecord: RuleRecord, payload: any): boolean
	local policy = ruleRecord.policy

	if policy.cooldown and (Scheduler.now() - ruleRecord.lastFireTime) < (policy.cooldown :: number) then
		ruleRecord.metrics.skipped += 1
		emitTrace("Rule.Skip", ruleRecord, "cooldown")
		return false
	end

	if ruleRecord.guard then
		local pass: boolean
		if ruleRecord.guardIsStore then
			pass = (ruleRecord.guard :: any):get() == true
		else
			local ok, result = pcall(ruleRecord.guard :: any, ruleRecord.ctx, payload)
			pass = ok and result == true
		end
		if not pass then
			ruleRecord.metrics.skipped += 1
			emitTrace("Rule.Skip", ruleRecord, "guard")
			return false
		end
	end

	return true
end

-- Handles overflow when a concurrency queue is full (concat) or capacity is
-- exceeded (merge). For merge, concatQueue is always empty so "latest" and
-- "fifo" both fall back to drop.
local function applyQueueOverflow(ruleRecord: RuleRecord, queuePolicy: string?, payload: any)
	local resolvedPolicy = queuePolicy or "drop"
	emitTrace("Rule.Skip", ruleRecord, "capacity")
	ruleRecord.metrics.skipped += 1
	if resolvedPolicy == "latest" and #ruleRecord.concatQueue > 0 then
		ruleRecord.concatQueue[#ruleRecord.concatQueue] = { payload = payload }
		ruleRecord.metrics.skipped -= 1 -- replacement, not a true drop
	elseif resolvedPolicy == "fifo" and #ruleRecord.concatQueue > 0 then
		table.remove(ruleRecord.concatQueue, 1)
		table.insert(ruleRecord.concatQueue, { payload = payload })
		ruleRecord.metrics.skipped -= 1 -- replacement
	end
end

local function dequeueConcat(ruleRecord: RuleRecord)
	ruleRecord.concatRunning = false
	if ruleRecord.enabled and not ruleRecord.destroyed and #ruleRecord.concatQueue > 0 then
		local nextEvent = table.remove(ruleRecord.concatQueue, 1) :: PendingEvent
		ruleRecord.concatRunning = true
		runEffect(ruleRecord, nextEvent.payload)
	end
end

-- ── Signal connection ──────────────────────────────────────────────────────────

local function disconnectSignal(ruleRecord: RuleRecord)
	if ruleRecord.signalConnection then
		(ruleRecord.signalConnection :: any):Disconnect()
		ruleRecord.signalConnection = nil
	end
end

local function connectSignal(ruleRecord: RuleRecord)
	if ruleRecord.signalConnection or not ruleRecord.signal or not ruleRecord.effect then return end
	local policy = ruleRecord.policy
	ruleRecord.signalConnection = (ruleRecord.signal :: any):connect(function(payload: any)
		if not ruleRecord.enabled or ruleRecord.destroyed then return end

		-- Debounce: cancel pending timer, restart; emit only after silence.
		if policy.debounce then
			if ruleRecord.debounceThread then Scheduler.cancel(ruleRecord.debounceThread) end
			ruleRecord.debounceThread = Scheduler.delay(policy.debounce :: number, function()
				ruleRecord.debounceThread = nil
				if ruleRecord.enabled and not ruleRecord.destroyed then
					admitAndSchedule(ruleRecord, payload)
				end
			end)
			return
		end

		-- Throttle: leading edge fires immediately; trailing edge fires after window.
		if policy.throttle then
			if ruleRecord.throttleActive then
				ruleRecord.throttlePendingPayload = payload -- keep latest for trailing
				return
			end
			ruleRecord.throttleActive = true
			ruleRecord.throttleThread = Scheduler.delay(policy.throttle :: number, function()
				ruleRecord.throttleThread         = nil
				ruleRecord.throttleActive         = false
				local pendingPayload              = ruleRecord.throttlePendingPayload
				ruleRecord.throttlePendingPayload = nil
				if pendingPayload ~= nil and ruleRecord.enabled and not ruleRecord.destroyed then
					admitAndSchedule(ruleRecord, pendingPayload)
				end
			end)
			-- Fall through: leading edge
		end

		admitAndSchedule(ruleRecord, payload)
	end)
end

-- ── Guard watch (cancelIfGuardFlips) ──────────────────────────────────────────

local function watchGuard(ruleRecord: RuleRecord)
	if not ruleRecord.policy.cancelIfGuardFlips
		or not ruleRecord.guardIsStore
		or ruleRecord.guardConnection
	then return end
	local guardStore = ruleRecord.guard :: any
	if type(guardStore.changed) ~= "function" then return end
	ruleRecord.guardConnection = (guardStore:changed() :: any):connect(function(event: any)
		if event.new == false and ruleRecord.enabled and not ruleRecord.destroyed then
			local taskSnapshot: { any } = {}
			for _, taskHandle in ipairs(ruleRecord.inFlightTasks) do
				table.insert(taskSnapshot, taskHandle)
			end
			for _, taskHandle in ipairs(taskSnapshot) do
				(taskHandle :: any):cancel(TaskModule.Reason.GuardFlipped)
			end
			emitTrace("Rule.Cancel", ruleRecord, TaskModule.Reason.GuardFlipped)
		end
	end)
end

local function unwatchGuard(ruleRecord: RuleRecord)
	if ruleRecord.guardConnection then
		(ruleRecord.guardConnection :: any):Disconnect()
		ruleRecord.guardConnection = nil
	end
end

-- ── admitAndSchedule ──────────────────────────────────────────────────────────

admitAndSchedule = function(ruleRecord: RuleRecord, payload: any)
	if not ruleRecord.enabled or ruleRecord.destroyed then return end
	if not checkAdmit(ruleRecord, payload) then return end

	local policy      = ruleRecord.policy
	local concurrency = policy.concurrency or "exhaust"

	if concurrency == "exhaust" then
		if #ruleRecord.inFlightTasks > 0 then
			ruleRecord.metrics.skipped += 1
			emitTrace("Rule.Skip", ruleRecord, "exhaust")
			return
		end

	elseif concurrency == "merge" then
		local capacity = (policy.capacity or math.huge) :: number
		if #ruleRecord.inFlightTasks >= capacity then
			applyQueueOverflow(ruleRecord, policy.queue, payload)
			return
		end

	elseif concurrency == "concat" then
		if ruleRecord.concatRunning then
			local capacity = (policy.capacity or math.huge) :: number
			if #ruleRecord.concatQueue >= capacity then
				applyQueueOverflow(ruleRecord, policy.queue, payload)
			else
				table.insert(ruleRecord.concatQueue, { payload = payload })
			end
			return
		end
		ruleRecord.concatRunning = true
		-- "switch" always admits; runEffect cancels previous tasks.
	end

	ruleRecord.lastFireTime = Scheduler.now()
	emitTrace("Rule.Admit", ruleRecord, payload)

	if policy.admitPhase == "immediate" then
		runEffect(ruleRecord, payload)
	else
		Scheduler.defer(function()
			if ruleRecord.enabled and not ruleRecord.destroyed then
				runEffect(ruleRecord, payload)
			end
		end)
	end
end

-- ── runEffect ──────────────────────────────────────────────────────────────────

runEffect = function(ruleRecord: RuleRecord, payload: any)
	if not ruleRecord.enabled or not ruleRecord.effect or ruleRecord.destroyed then
		if ruleRecord.policy.concurrency == "concat" then dequeueConcat(ruleRecord) end
		return
	end

	-- Re-evaluate guard before running (only meaningful for endOfFrame phase).
	if ruleRecord.policy.recheckBeforeEffect and ruleRecord.guard then
		local pass: boolean
		if ruleRecord.guardIsStore then
			pass = (ruleRecord.guard :: any):get() == true
		else
			local ok, result = pcall(ruleRecord.guard :: any, ruleRecord.ctx, payload)
			pass = ok and result == true
		end
		if not pass then
			ruleRecord.metrics.skipped += 1
			emitTrace("Rule.Skip", ruleRecord, "recheck")
			if ruleRecord.policy.concurrency == "concat" then dequeueConcat(ruleRecord) end
			return
		end
	end

	-- switch: cancel all previous tasks before starting the new one.
	if ruleRecord.policy.concurrency == "switch" and #ruleRecord.inFlightTasks > 0 then
		local previousTasks    = ruleRecord.inFlightTasks
		ruleRecord.inFlightTasks = {}
		for _, taskHandle in ipairs(previousTasks) do
			(taskHandle :: any):cancel(TaskModule.Reason.Superseded)
		end
	end

	local startTime = Scheduler.now()
	local ok: boolean
	local effectResult: any

	if ruleRecord.policy.errors == "retry" and ruleRecord.policy.retry then
		local retryOpts = ruleRecord.policy.retry
		:: { count: number, backoff: "fixed" | "expo", base: number, jitter: number? }
		effectResult = TaskModule.retry(function(innerToken: any)
			local result = (ruleRecord.effect :: any)(ruleRecord.ctx, payload, tools)
			if type(result) == "table" and type((result :: any).await) == "function" then
				local taskOk, taskValue = (result :: any):await(innerToken)
				if not taskOk then error(taskValue) end
				return taskValue
			elseif type(result) == "function" then
				if ruleRecord.disposer then pcall(ruleRecord.disposer) end
				ruleRecord.disposer = result :: any
			end
			return nil
		end, retryOpts)
		ok = true
	else
		ok, effectResult = pcall(ruleRecord.effect :: any, ruleRecord.ctx, payload, tools)
	end

	if not ok then
		ruleRecord.metrics.errors += 1
		emitTrace("Rule.Error", ruleRecord, effectResult)
		if ruleRecord.policy.concurrency == "concat" then dequeueConcat(ruleRecord) end
		if ruleRecord.policy.errors == "propagate" then error(effectResult, 0) end
		return
	end

	ruleRecord.metrics.runs += 1
	ruleRecord.firedCount   += 1

	if type(effectResult) == "function" then
		-- Disposer: replace any existing one before storing the new one.
		if ruleRecord.disposer then pcall(ruleRecord.disposer) end
		ruleRecord.disposer = effectResult :: any
		emitTrace("Rule.Start", ruleRecord)
		ruleRecord.metrics.totalMs += (Scheduler.now() - startTime) * 1000
		if ruleRecord.policy.concurrency == "concat" then dequeueConcat(ruleRecord) end

	elseif type(effectResult) == "table" and type((effectResult :: any).finally) == "function" then
		-- Task: track in inFlightTasks; remove and dequeue on completion.
		local taskHandle = effectResult :: any
		table.insert(ruleRecord.inFlightTasks, taskHandle)
		emitTrace("Rule.Start", ruleRecord, taskHandle:name())
		taskHandle:finally(function(status: string, errValue: any?)
			for i, v in ipairs(ruleRecord.inFlightTasks) do
				if v == taskHandle then table.remove(ruleRecord.inFlightTasks, i); break end
			end
			ruleRecord.metrics.totalMs += (Scheduler.now() - startTime) * 1000
			if status == "error" then
				ruleRecord.metrics.errors += 1
				emitTrace("Rule.Error", ruleRecord, errValue)
			elseif status == "fulfilled" then
				emitTrace("Rule.Done", ruleRecord)
			end
			if ruleRecord.policy.concurrency == "concat" then dequeueConcat(ruleRecord) end
		end)

	else
		-- nil or other sync return value.
		emitTrace("Rule.Start", ruleRecord)
		emitTrace("Rule.Done", ruleRecord)
		ruleRecord.metrics.totalMs += (Scheduler.now() - startTime) * 1000
		if ruleRecord.policy.concurrency == "concat" then dequeueConcat(ruleRecord) end
	end

	-- once: stop listening after the first successful effect start.
	if ruleRecord.policy.once then
		ruleRecord.enabled = false
		disconnectSignal(ruleRecord)
		if ruleRecord.debounceThread then
			Scheduler.cancel(ruleRecord.debounceThread)
			ruleRecord.debounceThread = nil
		end
		if ruleRecord.throttleThread then
			Scheduler.cancel(ruleRecord.throttleThread)
			ruleRecord.throttleThread = nil
		end
		emitTrace("Rule.Once", ruleRecord)
	end
end

-- ── Constructor ────────────────────────────────────────────────────────────────

local function newRule(label: string?): any
	local handle = setmetatable({}, RULE_META)
	ruleRecords[handle] = {
		handle               = handle,
		label                = label,
		enabled              = false,
		enableCount          = 0,
		destroyed            = false,
		signal               = nil,
		guard                = nil,
		guardIsStore         = false,
		effect               = nil,
		policy               = DEFAULT_POLICY,
		ctx                  = nil,
		signalConnection     = nil,
		guardConnection      = nil,
		inFlightTasks        = {},
		disposer             = nil,
		concatQueue          = {},
		concatRunning        = false,
		lastFireTime         = -math.huge,
		debounceThread       = nil,
		throttleActive       = false,
		throttlePendingPayload = nil,
		throttleThread       = nil,
		firedCount           = 0,
		metrics              = { runs = 0, skipped = 0, errors = 0, totalMs = 0 },
	}
	return handle
end

-- ── Rule methods ───────────────────────────────────────────────────────────────

function ruleMethods:on(sig: any): Rule
	local ruleRecord = ruleRecords[self]
	assert(ruleRecord and not ruleRecord.destroyed, "Rule.on: rule is destroyed")
	assert(not ruleRecord.enabled, "Rule.on: cannot change signal while enabled")
	ruleRecord.signal = sig
	return self :: any
end

function ruleMethods:when(guard: any): Rule
	local ruleRecord = ruleRecords[self]
	assert(ruleRecord and not ruleRecord.destroyed, "Rule.when: rule is destroyed")
	assert(not ruleRecord.enabled, "Rule.when: cannot change guard while enabled")
	ruleRecord.guard        = guard
	ruleRecord.guardIsStore = type(guard) == "table"
		and type((guard :: any).get) == "function"
	return self :: any
end

function ruleMethods:run(effect: (any, any?, any?) -> any?): Rule
	local ruleRecord = ruleRecords[self]
	assert(ruleRecord and not ruleRecord.destroyed, "Rule.run: rule is destroyed")
	assert(not ruleRecord.enabled, "Rule.run: cannot change effect while enabled")
	ruleRecord.effect = effect
	return self :: any
end

function ruleMethods:policy(opts: RulePolicy): Rule
	local ruleRecord = ruleRecords[self]
	assert(ruleRecord and not ruleRecord.destroyed, "Rule.policy: rule is destroyed")
	local merged: { [string]: any } = {}
	for key, value in pairs(DEFAULT_POLICY :: any) do merged[key] = value end
	for key, value in pairs(opts :: any) do merged[key] = value end
	ruleRecord.policy = table.freeze(merged) :: any
	return self :: any
end

function ruleMethods:attach(scope: any): Rule
	local ruleRecord = ruleRecords[self]
	assert(ruleRecord and not ruleRecord.destroyed, "Rule.attach: rule is destroyed")
	if type(scope) == "table" and type(scope._ruleAttached) == "function" then
		scope:_ruleAttached(self :: any)
	end
	return self :: any
end

-- enable(ctx?) — ctx is scope-internal; public type shows no ctx parameter.
-- Scopes call rule:enable(ctx) after casting to any. External callers use
-- rule:enable() with no arguments.
function ruleMethods:enable(ctx: any?): Rule
	local ruleRecord = ruleRecords[self]
	assert(ruleRecord and not ruleRecord.destroyed, "Rule.enable: rule is destroyed")
	if ctx ~= nil then ruleRecord.ctx = ctx end
	ruleRecord.enableCount += 1
	if ruleRecord.enableCount == 1 then
		ruleRecord.enabled = true
		connectSignal(ruleRecord)
		watchGuard(ruleRecord)
		emitTrace("Rule.Enable", ruleRecord)
	end
	return self :: any
end

function ruleMethods:disable(): Rule
	local ruleRecord = ruleRecords[self]
	assert(ruleRecord and not ruleRecord.destroyed, "Rule.disable: rule is destroyed")
	if ruleRecord.enableCount <= 0 then return self :: any end
	ruleRecord.enableCount -= 1
	if ruleRecord.enableCount == 0 then
		ruleRecord.enabled = false
		disconnectSignal(ruleRecord)
		unwatchGuard(ruleRecord)
		local taskSnapshot      = ruleRecord.inFlightTasks
		ruleRecord.inFlightTasks = {}
		for _, taskHandle in ipairs(taskSnapshot) do
			(taskHandle :: any):cancel(TaskModule.Reason.ModeExit)
		end
		if ruleRecord.disposer then pcall(ruleRecord.disposer); ruleRecord.disposer = nil end
		if ruleRecord.debounceThread then
			Scheduler.cancel(ruleRecord.debounceThread)
			ruleRecord.debounceThread = nil
		end
		if ruleRecord.throttleThread then
			Scheduler.cancel(ruleRecord.throttleThread)
			ruleRecord.throttleThread = nil
		end
		ruleRecord.throttleActive         = false
		ruleRecord.throttlePendingPayload = nil
		ruleRecord.concatQueue            = {}
		ruleRecord.concatRunning          = false
		emitTrace("Rule.Disable", ruleRecord)
	end
	return self :: any
end

function ruleMethods:dispose()
	local ruleRecord = ruleRecords[self]
	if not ruleRecord or ruleRecord.destroyed then return end
	-- Tear down unconditionally regardless of enableCount.
	ruleRecord.enabled     = false
	ruleRecord.enableCount = 0
	disconnectSignal(ruleRecord)
	unwatchGuard(ruleRecord)
	local taskSnapshot       = ruleRecord.inFlightTasks
	ruleRecord.inFlightTasks = {}
	for _, taskHandle in ipairs(taskSnapshot) do
		(taskHandle :: any):cancel(TaskModule.Reason.ModeExit)
	end
	if ruleRecord.disposer then pcall(ruleRecord.disposer); ruleRecord.disposer = nil end
	if ruleRecord.debounceThread then
		Scheduler.cancel(ruleRecord.debounceThread)
		ruleRecord.debounceThread = nil
	end
	if ruleRecord.throttleThread then
		Scheduler.cancel(ruleRecord.throttleThread)
		ruleRecord.throttleThread = nil
	end
	ruleRecord.throttleActive         = false
	ruleRecord.throttlePendingPayload = nil
	ruleRecord.concatQueue            = {}
	ruleRecord.concatRunning          = false
	ruleRecord.destroyed              = true
	emitTrace("Rule.Dispose", ruleRecord)
end

function ruleMethods:name(): string?
	local ruleRecord = ruleRecords[self]
	return ruleRecord and (ruleRecord.policy.tag or ruleRecord.label) or nil
end

-- ── Module API ─────────────────────────────────────────────────────────────────

local RuleAPI: {
	rule:         (name: string) -> Rule,
	setTracer:    (fn: ((TraceEvent) -> ())?) -> (),
	metrics:      (r: Rule) -> { runs: number, skipped: number, errors: number, avgMs: number },
	setScheduler: (s: { defer: any?, delay: any?, cancel: any?, now: (() -> number)? }) -> (),
	setTools:     (extra: { [string]: any }) -> (),
} = {} :: any

function RuleAPI.rule(name: string): Rule
	return newRule(name) :: any
end

function RuleAPI.setTracer(fn: ((TraceEvent) -> ())?)
	tracer.setHandler(fn)
end

function RuleAPI.metrics(r: Rule): { runs: number, skipped: number, errors: number, avgMs: number }
	local ruleRecord = ruleRecords[r :: any]
	assert(ruleRecord, "Rule.metrics: invalid rule handle")
	local avgMs = if ruleRecord.metrics.runs > 0
		then ruleRecord.metrics.totalMs / ruleRecord.metrics.runs
		else 0
	return {
		runs    = ruleRecord.metrics.runs,
		skipped = ruleRecord.metrics.skipped,
		errors  = ruleRecord.metrics.errors,
		avgMs   = avgMs,
	}
end

function RuleAPI.setScheduler(s: { defer: any?, delay: any?, cancel: any?, now: (() -> number)? })
	SchedulerModule.override(s)
end

function RuleAPI.setTools(extra: { [string]: any })
	for key, value in pairs(extra) do (tools :: any)[key] = value end
end

table.freeze(ruleMethods)
return table.freeze(RuleAPI)

