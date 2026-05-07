--!strict
--!optimize 2

-- Task: cancellable async jobs. Tokens, groups, timeouts, retries.
--
-- Safety model
--   Handles are frozen opaque tables. All mutable state lives in
--   module-private weak tables keyed by identity.
--   __metatable = "Token"/"Task"/"TaskGroup" blocks getmetatable().
--
-- Execution model
--   Each task runs in a Luau coroutine. start() defers the first resume
--   so the caller always receives the Task handle before the job begins.
--   await() yields the calling coroutine; a finally handler on the awaited
--   task defers the resume, keeping all continuations off the fire stack.
--
-- Cancellation
--   Cooperative: token.cancelled() + await(token) propagate cancel signals.
--   cancel() fires token hooks synchronously, then sets terminal status.
--   finally() handlers fire synchronously when status changes; if the task
--   is already terminal when finally() is called, delivery is deferred.
--
-- Lifetime
--   TaskGroups hold strong references to pending tasks; tasks are pruned
--   automatically via finally hooks when they reach a terminal state.

local ConnectionModule = require(script.Parent.Internal.Connection)
local SchedulerModule  = require(script.Parent.Internal.Scheduler)
local TracerModule     = require(script.Parent.Internal.Tracer)
local TaskTypes        = require(script.Parent.Types.TaskTypes)

local Scheduler = SchedulerModule.Scheduler

-- Capture defaults before any potential override so TaskAPI.scheduler("default")
-- can restore the original Roblox scheduler implementations.
local defaultDefer  = Scheduler.defer
local defaultDelay  = Scheduler.delay
local defaultCancel = Scheduler.cancel

-- ── Internal types ─────────────────────────────────────────────────────────────

type HookFn    = (reason: string?) -> ()
type FinallyFn = (status: string, err: any?) -> ()

type TokenRecord = {
	cancelled: boolean,
	reason:    string?,
	hooks:     { HookFn },
	destroyed: boolean,
}

type TaskRecord = {
	status:          "pending" | "fulfilled" | "cancelled" | "error",
	name:            string?,
	id:              number,
	thread:          thread?,
	tokenHandle:     any,
	lastResult:      any?,
	lastError:       any?,
	cancelReason:    string?,
	finallyHandlers: { FinallyFn },
	firingFinally:   boolean,
	pendingFinally:  { FinallyFn }?,
	destroyed:       boolean,
}

type GroupRecord = {
	name:             string?,
	tasks:            { [any]: true },
	lastCancelReason: string?,
	destroyed:        boolean,
}

-- Weak keys: abandoned handles are GC'd without explicit cleanup.
local tokenRecords: { [any]: TokenRecord } = setmetatable({}, { __mode = "k" } :: { __mode: "k" }) :: any
local taskRecords:  { [any]: TaskRecord  } = setmetatable({}, { __mode = "k" } :: { __mode: "k" }) :: any
local groupRecords: { [any]: GroupRecord } = setmetatable({}, { __mode = "k" } :: { __mode: "k" }) :: any

-- ── Public types ───────────────────────────────────────────────────────────────

export type Connection = TaskTypes.Connection
export type Token      = TaskTypes.Token
export type Task       = TaskTypes.Task
export type TaskGroup  = TaskTypes.TaskGroup

-- ── Diagnostics ────────────────────────────────────────────────────────────────

export type TraceEvent = {
	event: string,
	name:  string?,
	id:    number,
	extra: any?,
}

local tracer        = TracerModule.create()
local nextTaskIndex = 0

local function emitTrace(event: string, taskRecord: TaskRecord, extra: any?)
	if not tracer.hasHandler() then return end
	tracer.emit({ event = event, name = taskRecord.name, id = taskRecord.id, extra = extra })
end

-- ── Cancellation reasons ───────────────────────────────────────────────────────

local Reason = table.freeze({
	ModeExit     = "ModeExit",
	GuardFlipped = "GuardFlipped",
	Superseded   = "Superseded",
	Timeout      = "Timeout",
	User         = "User",
	Shutdown     = "Shutdown",
	Capacity     = "Capacity",
})

-- ── Token ──────────────────────────────────────────────────────────────────────

local tokenMethods = {}

function tokenMethods:cancelled(): boolean
	local tokenRecord = tokenRecords[self]
	return tokenRecord ~= nil and tokenRecord.cancelled
end

function tokenMethods:reason(): string?
	local tokenRecord = tokenRecords[self]
	return tokenRecord and tokenRecord.reason or nil
end

function tokenMethods:onCancel(callback: HookFn): Connection
	local tokenRecord = tokenRecords[self]
	assert(tokenRecord and not tokenRecord.destroyed, "Token.onCancel: invalid or destroyed token")
	if tokenRecord.cancelled then
		local cancelReason = tokenRecord.reason
		Scheduler.defer(function() callback(cancelReason) end)
		return ConnectionModule.dead()
	end
	table.insert(tokenRecord.hooks, callback)

	local function isStillConnected(): boolean
		for _, hook in ipairs(tokenRecord.hooks) do
			if hook == callback then return true end
		end
		return false
	end

	local function performDisconnect()
		for i, hook in ipairs(tokenRecord.hooks) do
			if hook == callback then table.remove(tokenRecord.hooks, i); break end
		end
	end

	return ConnectionModule.create(isStillConnected, performDisconnect)
end

local TOKEN_META = {
	__metatable = "Token",
	__newindex  = function(_, key: string) error("Token: '" .. key .. "' is read-only", 2) end,
	__index     = tokenMethods,
}

local function newToken(): any
	local token = setmetatable({}, TOKEN_META)
	tokenRecords[token] = { cancelled = false, reason = nil, hooks = {}, destroyed = false }
	return token
end

local function fireCancel(tokenRecord: TokenRecord, reason: string?)
	if tokenRecord.cancelled then return end
	tokenRecord.cancelled = true
	tokenRecord.reason    = reason
	local hooks = tokenRecord.hooks
	tokenRecord.hooks = {}
	for _, fn in ipairs(hooks) do fn(reason) end
end

-- ── Task ───────────────────────────────────────────────────────────────────────

local taskMethods  = {}
local setStatus: (taskRecord: TaskRecord, status: string, payload: any?) -> ()

local TASK_META = {
	__metatable = "Task",
	__newindex  = function(_, key: string) error("Task: '" .. key .. "' is read-only", 2) end,
	__index     = taskMethods,
}

local function newTask(name: string?): any
	nextTaskIndex += 1
	local taskHandle = setmetatable({}, TASK_META)
	taskRecords[taskHandle] = {
		status          = "pending",
		name            = name,
		id              = nextTaskIndex,
		thread          = nil,
		tokenHandle     = nil,
		lastResult      = nil,
		lastError       = nil,
		cancelReason    = nil,
		finallyHandlers = {},
		firingFinally   = false,
		pendingFinally  = nil,
		destroyed       = false,
	}
	return taskHandle
end

setStatus = function(taskRecord: TaskRecord, status: string, payload: any?)
	if taskRecord.status ~= "pending" then return end
	taskRecord.status = status :: any
	if status == "fulfilled" then
		taskRecord.lastResult = payload
	elseif status == "error" then
		taskRecord.lastError = payload
	elseif status == "cancelled" then
		taskRecord.cancelReason = payload :: string?
	end

	local errorPayload: any = if status == "error"     then taskRecord.lastError
		elseif status == "cancelled" then taskRecord.cancelReason
		else nil

	taskRecord.firingFinally = true
	local currentHandlers = taskRecord.finallyHandlers
	taskRecord.finallyHandlers = {}
	for _, fn in ipairs(currentHandlers) do
		local ok, err = pcall(fn, status, errorPayload)
		if not ok then
			-- Swallow handler errors so one bad finally doesn't block the others.
			_ = err
		end
	end
	taskRecord.firingFinally = false

	-- Fire handlers that were registered during the loop above (via finally() re-entry).
	if taskRecord.pendingFinally then
		local pendingHandlerList = taskRecord.pendingFinally
		taskRecord.pendingFinally = nil
		for _, fn in ipairs(pendingHandlerList) do
			local capturedFn = fn
			Scheduler.defer(function() capturedFn(status, errorPayload) end)
		end
	end
end

function taskMethods:token(): Token
	local taskRecord = taskRecords[self]
	assert(taskRecord, "Task.token: invalid task handle")
	return taskRecord.tokenHandle :: any
end

function taskMethods:cancel(reason: string?)
	local taskRecord = taskRecords[self]
	if not taskRecord or taskRecord.status ~= "pending" then return end
	local internalTokenRecord = tokenRecords[taskRecord.tokenHandle]
	if internalTokenRecord then fireCancel(internalTokenRecord, reason or Reason.User) end
	setStatus(taskRecord, "cancelled", reason or Reason.User)
	emitTrace("Cancel", taskRecord, reason)
end

function taskMethods:status(): string
	local taskRecord = taskRecords[self]
	assert(taskRecord, "Task.status: invalid task handle")
	return taskRecord.status
end

function taskMethods:finally(fn: FinallyFn): Task
	local taskRecord = taskRecords[self]
	assert(taskRecord, "Task.finally: invalid task handle")

	if taskRecord.status ~= "pending" then
		-- Already terminal: deliver deferred so the caller finishes first.
		local terminalStatus = taskRecord.status
		local errorPayload: any = if terminalStatus == "error"      then taskRecord.lastError
			elseif terminalStatus == "cancelled" then taskRecord.cancelReason
			else nil
		Scheduler.defer(function() fn(terminalStatus, errorPayload) end)
		return self :: any
	end

	if taskRecord.firingFinally then
		-- Called from within setStatus: queue for after the current loop.
		if not taskRecord.pendingFinally then taskRecord.pendingFinally = {} end
		table.insert(taskRecord.pendingFinally :: { FinallyFn }, fn)
		return self :: any
	end

	table.insert(taskRecord.finallyHandlers, fn)
	return self :: any
end

function taskMethods:result(): any?
	local taskRecord = taskRecords[self]
	return taskRecord and taskRecord.lastResult or nil
end

function taskMethods:error(): any?
	local taskRecord = taskRecords[self]
	return taskRecord and taskRecord.lastError or nil
end

function taskMethods:name(): string?
	local taskRecord = taskRecords[self]
	return taskRecord and taskRecord.name or nil
end

function taskMethods:await(token: Token?): (boolean, any?)
	local taskRecord = taskRecords[self]
	assert(taskRecord, "Task.await: invalid task handle")

	-- Already terminal: return immediately without yielding.
	if taskRecord.status == "fulfilled" then return true,  taskRecord.lastResult    end
	if taskRecord.status == "cancelled" then return false, taskRecord.cancelReason  end
	if taskRecord.status == "error"     then return false, taskRecord.lastError     end

	local coroutineThread = coroutine.running()
	assert(coroutineThread, "Task.await: must be called from inside a running coroutine (a task job)")

	local resumed  = false
	local cancelPropagationConnection: Connection?

	-- When this task terminates, resume the waiting coroutine (deferred).
	taskMethods.finally(self :: any, function(status: string, _: any?)
		if resumed then return end
		resumed = true
		if cancelPropagationConnection then
			(cancelPropagationConnection :: any):Disconnect()
			cancelPropagationConnection = nil
		end
		local ok  = status == "fulfilled"
		local val: any = if ok                    then taskRecord.lastResult
			elseif status == "cancelled" then taskRecord.cancelReason
			else taskRecord.lastError
		Scheduler.defer(function() coroutine.resume(coroutineThread, ok, val) end)
	end)

	-- Watch caller's token: if it's cancelled, cancel the task we're awaiting.
	if token then
		local internalTokenRecord = tokenRecords[token :: any]
		assert(internalTokenRecord, "Task.await: invalid token handle")
		if internalTokenRecord.cancelled then
			if not resumed then taskMethods.cancel(self :: any, internalTokenRecord.reason) end
		else
			cancelPropagationConnection = tokenMethods.onCancel(token :: any, function(reason: string?)
				if not resumed then taskMethods.cancel(self :: any, reason) end
			end)
		end
	end

	return coroutine.yield()
end

-- ── TaskGroup ──────────────────────────────────────────────────────────────────

local groupMethods = {}

local GROUP_META = {
	__metatable = "TaskGroup",
	__newindex  = function(_, key: string) error("TaskGroup: '" .. key .. "' is read-only", 2) end,
	__index     = groupMethods,
}

local function newGroup(name: string?): any
	local groupHandle = setmetatable({}, GROUP_META)
	groupRecords[groupHandle] = {
		name             = name,
		tasks            = {},
		lastCancelReason = nil,
		destroyed        = false,
	}
	return groupHandle
end

-- ── Module API (forward ref so groupMethods can call TaskAPI.start) ────────────

local TaskAPI: {
	start:        (fn: (token: Token) -> any?, opts: { name: string?, scheduler: string? }?) -> Task,
	chain:        (fn: (token: Token) -> any?) -> Task,
	timeout:      (inner: Task | (() -> Task), seconds: number, reason: string?) -> Task,
	retry:        (makeTask: (token: Token) -> any?, opts: { count: number, backoff: "fixed" | "expo", base: number, jitter: number? }) -> Task,
	delay:        (seconds: number, fn: (() -> ())?) -> Task,
	scheduler:    (phase: string) -> (),
	group:        (opts: { name: string? }?) -> TaskGroup,
	all:          (tasks: { Task }) -> Task,
	any:          (tasks: { Task }) -> Task,
	wrapRoblox:   (signal: RBXScriptSignal, untilSignal: RBXScriptSignal?) -> Task,
	setTracer:    (fn: ((TraceEvent) -> ())?) -> (),
	Reason:       typeof(Reason),
} = {} :: any

-- ── GroupMethods (need TaskAPI reference) ─────────────────────────────────────

function groupMethods:add(taskHandle: Task): TaskGroup
	local groupRecord = groupRecords[self]
	assert(groupRecord and not groupRecord.destroyed, "TaskGroup.add: group is destroyed")
	local taskRecord = taskRecords[taskHandle :: any]
	assert(taskRecord, "TaskGroup.add: not a valid Task handle")
	if taskRecord.status ~= "pending" then return self :: any end
	groupRecord.tasks[taskHandle] = true
	-- Auto-prune when the task reaches a terminal state.
	taskMethods.finally(taskHandle :: any, function()
		groupRecord.tasks[taskHandle] = nil
	end)
	return self :: any
end

type TaskStartOptions = {
	name: string?,
	scheduler: string?
}
function groupMethods:start(fn: (token: Token) -> any?, opts: TaskStartOptions?): Task
	local groupRecord = groupRecords[self]
	assert(groupRecord and not groupRecord.destroyed, "TaskGroup.start: group is destroyed")
	local newTaskHandle = TaskAPI.start(fn, opts)
	groupMethods.add(self, newTaskHandle)
	return newTaskHandle
end

function groupMethods:cancelAll(reason: string?)
	local groupRecord = groupRecords[self]
	assert(groupRecord, "TaskGroup.cancelAll: invalid group")
	groupRecord.lastCancelReason = reason or Reason.ModeExit
	local snapshot: { any } = {}
	for taskHandle in pairs(groupRecord.tasks) do table.insert(snapshot, taskHandle) end
	for _, taskHandle in ipairs(snapshot) do
		taskMethods.cancel(taskHandle, reason or Reason.ModeExit)
	end
end

function groupMethods:joinAll(): Task
	local groupRecord = groupRecords[self]
	assert(groupRecord, "TaskGroup.joinAll: invalid group")
	-- Snapshot: tasks added after this call are NOT included.
	local snapshot: { any } = {}
	for taskHandle in pairs(groupRecord.tasks) do table.insert(snapshot, taskHandle) end

	if #snapshot == 0 then
		return TaskAPI.start(function() return nil end)
	end

	return TaskAPI.start(function(outerToken: Token)
		local coroutineThread = coroutine.running()
		local remaining       = #snapshot
		local done            = false

		local function maybeResume()
			if done then return end
			done = true
			Scheduler.defer(function() coroutine.resume(coroutineThread) end)
		end

		for _, taskHandle in ipairs(snapshot) do
			taskMethods.finally(taskHandle, function()
				remaining -= 1
				if remaining == 0 then maybeResume() end
			end)
		end

		tokenMethods.onCancel(outerToken, function() maybeResume() end)

		coroutine.yield()
		return nil
	end)
end

function groupMethods:race(): Task
	local groupRecord = groupRecords[self]
	assert(groupRecord, "TaskGroup.race: invalid group")
	local snapshot: { any } = {}
	for taskHandle in pairs(groupRecord.tasks) do table.insert(snapshot, taskHandle) end

	if #snapshot == 0 then
		return TaskAPI.start(function() return nil end)
	end

	return TaskAPI.start(function(outerToken: Token)
		local coroutineThread = coroutine.running()
		local decided         = false
		local raceSucceeded   = true
		local raceResult: any = nil

		for _, taskHandle in ipairs(snapshot) do
			local captured = taskHandle
			taskMethods.finally(taskHandle, function(status: string)
				if decided then return end
				decided       = true
				local record  = taskRecords[captured]
				raceSucceeded = status == "fulfilled"
				raceResult    = if raceSucceeded     then (record and record.lastResult)
					elseif status == "cancelled" then (record and record.cancelReason)
					else (record and record.lastError)
				Scheduler.defer(function() coroutine.resume(coroutineThread) end)
			end)
		end

		tokenMethods.onCancel(outerToken, function()
			if not decided then
				decided       = true
				raceSucceeded = false
				raceResult    = Reason.User
				Scheduler.defer(function() coroutine.resume(coroutineThread) end)
			end
		end)

		coroutine.yield()
		if not raceSucceeded and raceResult then error(raceResult) end
		return nil
	end)
end

function groupMethods:size(): number
	local groupRecord = groupRecords[self]
	if not groupRecord then return 0 end
	local count = 0
	for _ in pairs(groupRecord.tasks) do count += 1 end
	return count
end

function groupMethods:name(): string?
	local groupRecord = groupRecords[self]
	return groupRecord and groupRecord.name or nil
end

-- ── TaskAPI.start ─────────────────────────────────────────────────────────────

function TaskAPI.start(
	fn:   (token: Token) -> any?,
	opts: { name: string?, scheduler: string? }?
): Task
	local name           = opts and opts.name or nil
	local token          = newToken()
	local taskHandle     = newTask(name)
	local taskRecord     = taskRecords[taskHandle]
	taskRecord.tokenHandle = token

	local coroutineThread = coroutine.create(function()
		local ok, result = pcall(fn, token :: any)
		if ok then
			-- Guard: cancel() may have already set status to "cancelled".
			if taskRecord.status == "pending" then
				setStatus(taskRecord, "fulfilled", result)
				emitTrace("Done", taskRecord)
			end
		else
			if taskRecord.status == "pending" then
				setStatus(taskRecord, "error", result)
				emitTrace("Error", taskRecord, result)
			end
			-- If already "cancelled", the error is the cancel-induced unwind; ignore.
		end
	end)
	taskRecord.thread = coroutineThread

	emitTrace("Start", taskRecord)
	-- Deferred first resume ensures start() always returns before the job runs.
	Scheduler.defer(function() coroutine.resume(coroutineThread) end)

	return taskHandle :: any
end

function TaskAPI.chain(fn: (token: Token) -> any?): Task
	return TaskAPI.start(fn)
end

-- ── TaskAPI.delay ─────────────────────────────────────────────────────────────

function TaskAPI.delay(seconds: number, fn: (() -> ())?): Task
	assert(seconds >= 0, "Task.delay: seconds must be non-negative")
	return TaskAPI.start(function(token: Token)
		local coroutineThread = coroutine.running()
		local fired           = false

		local delayThread = Scheduler.delay(seconds, function()
			fired = true
			coroutine.resume(coroutineThread, true)
		end)

		tokenMethods.onCancel(token, function()
			if not fired then Scheduler.cancel(delayThread) end
			-- If the coroutine is suspended in yield below, resume it so the
			-- task can exit and reach terminal state.
			if coroutine.status(coroutineThread) == "suspended" then
				coroutine.resume(coroutineThread, false)
			end
		end)

		local completed: boolean = coroutine.yield()
		if completed and fn then fn() end
		return nil
	end)
end

-- ── TaskAPI.timeout ───────────────────────────────────────────────────────────

function TaskAPI.timeout(inner: any, seconds: number, reason: string?): Task
	assert(seconds > 0, "Task.timeout: seconds must be positive")
	return TaskAPI.start(function(outerToken: Token)
		local innerTask: any = if type(inner) == "function"
			then (inner :: () -> Task)()
			else inner
		assert(
			taskRecords[innerTask],
			"Task.timeout: inner must be a Task handle or a thunk returning one"
		)

		local timerTask = TaskAPI.delay(seconds)
		local decided   = false

		-- If the timer fires first, cancel the inner task.
		taskMethods.finally(timerTask :: any, function()
			if decided then return end
			decided = true
			taskMethods.cancel(innerTask, reason or Reason.Timeout)
		end)

		local ok, result = taskMethods.await(innerTask, outerToken)

		-- Inner finished first; stop the timer.
		if not decided then
			decided = true
			taskMethods.cancel(timerTask :: any, Reason.Superseded)
		end

		if not ok then error(result) end
		return result
	end)
end

-- ── TaskAPI.retry ─────────────────────────────────────────────────────────────

local function computeBackoff(
	opts:    { count: number, backoff: "fixed" | "expo", base: number, jitter: number? },
	attempt: number
): number
	local delay: number = if opts.backoff == "expo"
		then opts.base * (2 ^ (attempt - 1))
		else opts.base
	delay = math.min(delay, 30) -- cap to prevent unbounded waits
	if opts.jitter and opts.jitter > 0 then
		delay = delay * (1 + math.random() * (opts.jitter :: number))
	end
	return delay
end

function TaskAPI.retry(
	makeTask: (token: Token) -> any?,
	opts:     { count: number, backoff: "fixed" | "expo", base: number, jitter: number? }
): Task
	assert(opts.count > 0, "Task.retry: count must be positive")
	assert(opts.base  >= 0, "Task.retry: base must be non-negative")

	return TaskAPI.start(function(outerToken: Token)
		local lastError: any
		for attempt = 1, opts.count do
			-- Wrap the user's fn in its own task so we can await it cleanly.
			local innerTask = TaskAPI.start(function(innerToken: Token)
				return makeTask(innerToken)
			end)

			-- Propagate outer cancellation into this attempt's task.
			local cancelConn = tokenMethods.onCancel(outerToken, function(reason: string?)
				taskMethods.cancel(innerTask :: any, reason)
			end)

			local ok, result = taskMethods.await(innerTask :: any, outerToken)
			;(cancelConn :: any):Disconnect()

			if ok then return result end
			if tokenMethods.cancelled(outerToken) then return end

			lastError = result

			-- Backoff before next attempt (skip after the final attempt).
			if attempt < opts.count then
				local backoffTask = TaskAPI.delay(computeBackoff(opts, attempt))
				taskMethods.await(backoffTask :: any, outerToken)
				if tokenMethods.cancelled(outerToken) then return end
			end
		end
		error(lastError or "Task.retry: all attempts failed")
	end)
end

-- ── TaskAPI.group ─────────────────────────────────────────────────────────────

function TaskAPI.group(opts: { name: string? }?): TaskGroup
	return newGroup(opts and opts.name or nil) :: any
end

-- ── TaskAPI.all ───────────────────────────────────────────────────────────────

function TaskAPI.all(tasks: { Task }): Task
	assert(type(tasks) == "table" and #tasks > 0, "Task.all: tasks must be a non-empty array")
	local taskCount = #tasks
	return TaskAPI.start(function(outerToken: Token)
		local coroutineThread = coroutine.running()
		local results         = table.create(taskCount)
		local completed       = 0
		local done            = false

		local function fail(errorValue: any)
			if done then return end
			done = true
			for _, taskHandle in ipairs(tasks) do
				if taskMethods.status(taskHandle) == "pending" then
					taskMethods.cancel(taskHandle :: any, Reason.Superseded)
				end
			end
			Scheduler.defer(function() coroutine.resume(coroutineThread, false, errorValue) end)
		end

		for i, taskHandle in ipairs(tasks) do
			local taskIndex = i
			taskMethods.finally(taskHandle :: any, function(status: string)
				if done then return end
				local taskRecord = taskRecords[taskHandle :: any]
				if status == "fulfilled" then
					results[taskIndex] = taskRecord and taskRecord.lastResult
					completed += 1
					if completed == taskCount then
						done = true
						Scheduler.defer(function() coroutine.resume(coroutineThread, true, results) end)
					end
				else
					fail(taskRecord and (taskRecord.lastError or taskRecord.cancelReason))
				end
			end)
		end

		tokenMethods.onCancel(outerToken, function(reason: string?)
			fail(reason)
		end)

		local ok, result = coroutine.yield()
		if not ok then error(result) end
		return result
	end)
end

-- ── TaskAPI.any ───────────────────────────────────────────────────────────────

function TaskAPI.any(tasks: { Task }): Task
	assert(type(tasks) == "table" and #tasks > 0, "Task.any: tasks must be a non-empty array")
	return TaskAPI.start(function(outerToken: Token)
		local coroutineThread = coroutine.running()
		local decided         = false

		for _, taskHandle in ipairs(tasks) do
			local captured = taskHandle
			taskMethods.finally(taskHandle :: any, function(status: string)
				if decided then return end
				decided = true
				local taskRecord = taskRecords[captured :: any]
				local ok         = status == "fulfilled"
				local val = if ok                    then (taskRecord and taskRecord.lastResult)
					elseif status == "cancelled" then (taskRecord and taskRecord.cancelReason)
					else (taskRecord and taskRecord.lastError)
				Scheduler.defer(function() coroutine.resume(coroutineThread, ok, val) end)
			end)
		end

		tokenMethods.onCancel(outerToken, function(reason: string?)
			if not decided then
				decided = true
				Scheduler.defer(function() coroutine.resume(coroutineThread, false, reason) end)
			end
		end)

		local ok, result = coroutine.yield()
		if not ok then error(result) end
		return result
	end)
end

-- ── TaskAPI.wrapRoblox ────────────────────────────────────────────────────────

function TaskAPI.wrapRoblox(signal: RBXScriptSignal, untilSignal: RBXScriptSignal?): Task
	assert(typeof(signal) == "RBXScriptSignal", "Task.wrapRoblox: expected RBXScriptSignal")
	return TaskAPI.start(function(token: Token)
		local coroutineThread = coroutine.running()
		local fired           = false

		local signalConnection:      RBXScriptConnection
		local untilConnection: RBXScriptConnection?

		signalConnection = signal:Connect(function(...)
			if fired then return end
			fired = true
			signalConnection:Disconnect()
			if untilConnection then (untilConnection :: RBXScriptConnection):Disconnect() end
			local args = table.pack(...)
			Scheduler.defer(function() coroutine.resume(coroutineThread, args) end)
		end)

		if untilSignal then
			untilConnection = (untilSignal :: RBXScriptSignal):Connect(function()
				if fired then return end
				fired = true
				signalConnection:Disconnect()
				;(untilConnection :: RBXScriptConnection):Disconnect()
				Scheduler.defer(function() coroutine.resume(coroutineThread, nil) end)
			end)
		end

		tokenMethods.onCancel(token, function()
			if not fired then
				fired = true
				signalConnection:Disconnect()
				if untilConnection then (untilConnection :: RBXScriptConnection):Disconnect() end
				if coroutine.status(coroutineThread) == "suspended" then
					Scheduler.defer(function() coroutine.resume(coroutineThread, nil) end)
				end
			end
		end)

		return coroutine.yield()
	end)
end

-- ── TaskAPI.scheduler ─────────────────────────────────────────────────────────

function TaskAPI.scheduler(phase: string)
	if phase == "default" or phase == "" then
		SchedulerModule.override({
			defer  = defaultDefer,
			delay  = defaultDelay,
			cancel = defaultCancel,
		})
	end
	-- Additional phases ("Frame", "Heartbeat", "Stepped", "mock") are integration
	-- points for FSM/Rule scheduling and test harnesses. Call SchedulerModule.override
	-- directly with custom implementations for those phases.
end

-- ── TaskAPI.setTracer ─────────────────────────────────────────────────────────

function TaskAPI.setTracer(fn: ((TraceEvent) -> ())?)
	tracer.setHandler(fn)
end

-- ── Populate and export ────────────────────────────────────────────────────────

TaskAPI.Reason = Reason

table.freeze(tokenMethods)
table.freeze(taskMethods)
table.freeze(groupMethods)
return table.freeze(TaskAPI)

