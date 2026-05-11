--!strict
local Connection = require(script.Parent.Connection)
local ErrorHandler = require(script.Parent.ErrorHandler)
local Scheduler = require(script.Parent.Scheduler)

-- ── Types ────────────────────────────────────────────────────────────────────

export type Status = "Pending" | "Fulfilled" | "Cancelled" | "Errored"

export type Task<T> = {
	Token: (self: Task<T>) -> Token,
	Cancel: (self: Task<T>, reason: string?) -> (),
	Status: (self: Task<T>) -> Status,
	IsPending: (self: Task<T>) -> boolean,
	IsFulfilled: (self: Task<T>) -> boolean,
	IsCancelled: (self: Task<T>) -> boolean,
	IsErrored: (self: Task<T>) -> boolean,
	IsDone: (self: Task<T>) -> boolean,
	Finally: (self: Task<T>, fn: (status: Status, value: unknown?) -> ()) -> Task<T>,
	Await: (self: Task<T>, token: Token?) -> (boolean, T | unknown),
	Unwrap: (self: Task<T>, token: Token?) -> T,
	Result: (self: Task<T>) -> (boolean, T?),
	Error: (self: Task<T>) -> (boolean, unknown?),
	Name: (self: Task<T>) -> string?,
}

export type Token = {
	Cancelled: (self: Token) -> boolean,
	Reason: (self: Token) -> string?,
	OnCancel: (self: Token, fn: (reason: string?) -> ()) -> Connection.Connection,
}

export type TaskGroup = {
	Add: (self: TaskGroup, task: Task<any>) -> TaskGroup,
	Start: (self: TaskGroup, fn: (token: Token) -> any, opts: TaskOptions?) -> Task<any>,
	CancelAll: (self: TaskGroup, reason: string?) -> (),
	JoinAll: (self: TaskGroup) -> Task<nil>,
	Race: (self: TaskGroup) -> Task<any>,
	Destroy: (self: TaskGroup, reason: string?) -> (),
	Size: (self: TaskGroup) -> number,
	Name: (self: TaskGroup) -> string?,
}

export type TaskOptions = {
	Name: string?,
}

export type RetryOptions = {
	Count: number,
	Backoff: "Fixed" | "Expo",
	Base: number,
	Jitter: number?,
}

export type SettledResult = {
	Status: Status,
	Value: unknown?,
	Error: unknown?,
	Reason: string?,
}

export type TraceEvent = {
	Event: string,
	Name: string?,
	Status: Status?,
}

type GroupOptions = {
	Name: string?,
}

-- ── Internal record types ─────────────────────────────────────────────────────

type FinallyEntry = { Fn: (Status, unknown?) -> () }

type OnCancelEntry = { Fn: (string?) -> (), Connected: boolean }

type TaskRecord = {
	Status: Status,
	HasResult: boolean,
	ResultValue: any,
	HasError: boolean,
	ErrorValue: any,
	Reason: string?,
	FinallyHandlers: { FinallyEntry },
	TokenHandle: any,
	Name: string?,
}

type TokenRecord = {
	Cancelled: boolean,
	Reason: string?,
	OnCancelHandlers: { OnCancelEntry },
}

type GroupRecord = {
	Destroyed: boolean,
	Name: string?,
	PendingTasks: { [any]: boolean },
}

-- ── Private storage ───────────────────────────────────────────────────────────

local taskRecords: { [any]: TaskRecord } = setmetatable({}, { __mode = "k" } :: any)
local tokenRecords: { [any]: TokenRecord } = setmetatable({}, { __mode = "k" } :: any)
local groupRecords: { [any]: GroupRecord } = setmetatable({}, { __mode = "k" } :: any)

-- ── Opaque handle metatables ──────────────────────────────────────────────────

local taskMethods = {}
local tokenMethods = {}
local groupMethods = {}

local taskMeta = {
	__metatable = "Task",
	__index = taskMethods,
	__newindex = function(_, k: string)
		error("Task: '" .. k .. "' is read-only", 2)
	end,
}

local tokenMeta = {
	__metatable = "Token",
	__index = tokenMethods,
	__newindex = function(_, k: string)
		error("Token: '" .. k .. "' is read-only", 2)
	end,
}

local groupMeta = {
	__metatable = "Group",
	__index = groupMethods,
	__newindex = function(_, k: string)
		error("Group: '" .. k .. "' is read-only", 2)
	end,
}

-- ── Tracer ────────────────────────────────────────────────────────────────────

local _tracer: ((TraceEvent) -> ())? = nil

local function emitTrace(event: string, rec: TaskRecord)
	if _tracer == nil then
		return
	end
	local fn = _tracer :: (TraceEvent) -> ()
	local ok, err = pcall(fn, {
		Event = event,
		Name = rec.Name,
		Status = rec.Status,
	})
	if not ok then
		ErrorHandler.Report({ Module = "Task", Phase = "Trace", Error = err })
	end
end

-- ── Internal helpers ──────────────────────────────────────────────────────────

local function newTaskHandle(rec: TaskRecord): any
	local handle = setmetatable({}, taskMeta)
	taskRecords[handle] = rec
	return handle
end

local function newTokenHandle(rec: TokenRecord): any
	local handle = setmetatable({}, tokenMeta)
	tokenRecords[handle] = rec
	return handle
end

local function newGroupHandle(rec: GroupRecord): any
	local handle = setmetatable({}, groupMeta)
	groupRecords[handle] = rec
	return handle
end

local function isTaskHandle(value: unknown): boolean
	return type(value) == "table" and getmetatable(value :: any) == "Task"
		and taskRecords[value :: any] ~= nil
end

local function isTokenHandle(value: unknown): boolean
	return type(value) == "table" and getmetatable(value :: any) == "Token"
		and tokenRecords[value :: any] ~= nil
end

local function isGroupHandle(value: unknown): boolean
	return type(value) == "table" and getmetatable(value :: any) == "Group"
		and groupRecords[value :: any] ~= nil
end

local function runFinallyHandlers(taskHandle: any)
	local rec = taskRecords[taskHandle]
	local handlers = rec.FinallyHandlers
	rec.FinallyHandlers = {}
	local status = rec.Status
	local value: unknown?
	if status == "Fulfilled" then
		value = if rec.HasResult then rec.ResultValue else nil
	elseif status == "Errored" then
		value = if rec.HasError then rec.ErrorValue else nil
	elseif status == "Cancelled" then
		value = rec.Reason
	end
	for _, entry in handlers do
		local fn = entry.Fn
		Scheduler.Defer(function()
			local ok, err = pcall(fn, status, value)
			if not ok then
				ErrorHandler.Report({ Module = "Task", Phase = "Finally", Error = err })
			end
		end)
	end
end

local function cancelToken(tokenHandle: any, reason: string?)
	local rec = tokenRecords[tokenHandle]
	if rec == nil or rec.Cancelled then
		return
	end
	rec.Cancelled = true
	rec.Reason = reason
	local handlers = rec.OnCancelHandlers
	rec.OnCancelHandlers = {}
	for _, entry in handlers do
		if entry.Connected then
			local fn = entry.Fn
			local r = reason
			Scheduler.Defer(function()
				local ok, err = pcall(fn, r)
				if not ok then
					ErrorHandler.Report({ Module = "Task", Phase = "TokenCancel", Error = err })
				end
			end)
		end
	end
end

local function settleTask(taskHandle: any, status: Status, hasVal: boolean, val: any, reason: string?)
	local rec = taskRecords[taskHandle]
	if rec.Status ~= "Pending" then
		return
	end
	rec.Status = status
	if status == "Fulfilled" then
		rec.HasResult = hasVal
		rec.ResultValue = val
		emitTrace("Done", rec)
	elseif status == "Errored" then
		rec.HasError = hasVal
		rec.ErrorValue = val
		emitTrace("Error", rec)
	elseif status == "Cancelled" then
		rec.Reason = reason
		emitTrace("Cancel", rec)
	end
	runFinallyHandlers(taskHandle)
end

local function cancelTask(taskHandle: any, reason: string?)
	local rec = taskRecords[taskHandle]
	if rec == nil or rec.Status ~= "Pending" then
		return
	end
	local r = if reason ~= nil then reason else "User"
	cancelToken(rec.TokenHandle, r)
	settleTask(taskHandle, "Cancelled", false, nil, r)
end

-- ── Task.Reason constants ─────────────────────────────────────────────────────

local Task = {} :: any

Task.Reason = table.freeze({
	ModeExit = "ModeExit",
	GuardFalse = "GuardFalse",
	Superseded = "Superseded",
	Timeout = "Timeout",
	User = "User",
	Shutdown = "Shutdown",
	Capacity = "Capacity",
})

-- ── Constructors ──────────────────────────────────────────────────────────────

function Task.Start(fn: (token: Token) -> any, opts: TaskOptions?): any
	if type(fn) ~= "function" then
		error("Task.Start: fn must be a function", 2)
	end
	if opts ~= nil and type(opts) ~= "table" then
		error("Task.Start: opts must be a table or nil", 2)
	end
	local name: string? = nil
	if opts ~= nil then
		name = (opts :: any).Name
		if name ~= nil and type(name) ~= "string" then
			error("Task.Start: Name must be a string or nil", 2)
		end
	end

	local tokenRec: TokenRecord = {
		Cancelled = false,
		Reason = nil,
		OnCancelHandlers = {},
	}
	local tokenHandle = newTokenHandle(tokenRec)

	local taskRec: TaskRecord = {
		Status = "Pending",
		HasResult = false,
		ResultValue = nil,
		HasError = false,
		ErrorValue = nil,
		Reason = nil,
		FinallyHandlers = {},
		TokenHandle = tokenHandle,
		Name = name,
	}
	local taskHandle = newTaskHandle(taskRec)

	emitTrace("Start", taskRec)

	Scheduler.Defer(function()
		local co = coroutine.create(fn)
		local ok, result = coroutine.resume(co, tokenHandle)
		if ok then
			settleTask(taskHandle, "Fulfilled", true, result, nil)
		else
			settleTask(taskHandle, "Errored", true, result, nil)
		end
	end)

	return taskHandle
end

function Task.Defer(fn: (token: Token) -> any, opts: TaskOptions?): any
	if type(fn) ~= "function" then
		error("Task.Defer: fn must be a function", 2)
	end
	if opts ~= nil and type(opts) ~= "table" then
		error("Task.Defer: opts must be a table or nil", 2)
	end
	local name: string? = nil
	if opts ~= nil then
		name = (opts :: any).Name
		if name ~= nil and type(name) ~= "string" then
			error("Task.Defer: Name must be a string or nil", 2)
		end
	end

	local tokenRec: TokenRecord = {
		Cancelled = false,
		Reason = nil,
		OnCancelHandlers = {},
	}
	local tokenHandle = newTokenHandle(tokenRec)

	local taskRec: TaskRecord = {
		Status = "Pending",
		HasResult = false,
		ResultValue = nil,
		HasError = false,
		ErrorValue = nil,
		Reason = nil,
		FinallyHandlers = {},
		TokenHandle = tokenHandle,
		Name = name,
	}
	local taskHandle = newTaskHandle(taskRec)

	emitTrace("Start", taskRec)

	Scheduler.Defer(function()
		local co = coroutine.create(fn)
		local ok, result = coroutine.resume(co, tokenHandle)
		if ok then
			settleTask(taskHandle, "Fulfilled", true, result, nil)
		else
			settleTask(taskHandle, "Errored", true, result, nil)
		end
	end)

	return taskHandle
end

function Task.Delay(seconds: number, fn: (() -> any)?): any
	if type(seconds) ~= "number" or seconds < 0 then
		error("Task.Delay: seconds must be non-negative", 2)
	end
	if fn ~= nil and type(fn) ~= "function" then
		error("Task.Delay: fn must be a function or nil", 2)
	end

	local tokenRec: TokenRecord = {
		Cancelled = false,
		Reason = nil,
		OnCancelHandlers = {},
	}
	local tokenHandle = newTokenHandle(tokenRec)

	local taskRec: TaskRecord = {
		Status = "Pending",
		HasResult = false,
		ResultValue = nil,
		HasError = false,
		ErrorValue = nil,
		Reason = nil,
		FinallyHandlers = {},
		TokenHandle = tokenHandle,
		Name = nil,
	}
	local taskHandle = newTaskHandle(taskRec)

	emitTrace("Start", taskRec)

	local timerHandle: any = nil
	local settled = false

	local cancelConn = tokenHandle:OnCancel(function(_reason: string?)
		if settled then return end
		settled = true
		Scheduler.Cancel(timerHandle)
	end)

	timerHandle = Scheduler.Delay(seconds, function()
		cancelConn:Disconnect()
		if settled then return end
		settled = true
		if fn ~= nil then
			local ok, result = pcall(fn :: () -> any)
			if ok then
				settleTask(taskHandle, "Fulfilled", true, result, nil)
			else
				settleTask(taskHandle, "Errored", true, result, nil)
			end
		else
			settleTask(taskHandle, "Fulfilled", true, nil, nil)
		end
	end)

	return taskHandle
end

function Task.Sleep(seconds: number, token: Token?): (boolean, string?)
	if type(seconds) ~= "number" or seconds < 0 then
		error("Task.Sleep: seconds must be non-negative", 2)
	end
	if token ~= nil and not isTokenHandle(token) then
		error("Task.Sleep: invalid token", 2)
	end
	local thread = coroutine.running()
	if thread == nil or not coroutine.isyieldable() then
		error("Task.Sleep: must be called from a yieldable coroutine", 2)
	end

	local settled = false
	local timerHandle: any = nil
	local cancelConn: Connection.Connection? = nil

	if token ~= nil then
		local tokenRec = tokenRecords[token :: any]
		if tokenRec.Cancelled then
			return false, tokenRec.Reason
		end
		cancelConn = (token :: any):OnCancel(function(reason: string?)
			if settled then return end
			settled = true
			Scheduler.Cancel(timerHandle)
			Scheduler.Defer(function()
				coroutine.resume(thread, false, reason)
			end)
		end)
	end

	timerHandle = Scheduler.Delay(seconds, function()
		if cancelConn ~= nil then
			cancelConn:Disconnect()
		end
		if settled then return end
		settled = true
		coroutine.resume(thread, true, nil)
	end)

	return coroutine.yield() :: any
end

function Task.Resolved(value: any): any
	local tokenRec: TokenRecord = {
		Cancelled = false,
		Reason = nil,
		OnCancelHandlers = {},
	}
	local tokenHandle = newTokenHandle(tokenRec)

	local taskRec: TaskRecord = {
		Status = "Fulfilled",
		HasResult = true,
		ResultValue = value,
		HasError = false,
		ErrorValue = nil,
		Reason = nil,
		FinallyHandlers = {},
		TokenHandle = tokenHandle,
		Name = nil,
	}
	return newTaskHandle(taskRec)
end

function Task.Rejected(errorValue: unknown): any
	local tokenRec: TokenRecord = {
		Cancelled = false,
		Reason = nil,
		OnCancelHandlers = {},
	}
	local tokenHandle = newTokenHandle(tokenRec)

	local taskRec: TaskRecord = {
		Status = "Errored",
		HasResult = false,
		ResultValue = nil,
		HasError = true,
		ErrorValue = errorValue,
		Reason = nil,
		FinallyHandlers = {},
		TokenHandle = tokenHandle,
		Name = nil,
	}
	return newTaskHandle(taskRec)
end

function Task.Cancelled(reason: string?): any
	local tokenRec: TokenRecord = {
		Cancelled = true,
		Reason = reason,
		OnCancelHandlers = {},
	}
	local tokenHandle = newTokenHandle(tokenRec)

	local taskRec: TaskRecord = {
		Status = "Cancelled",
		HasResult = false,
		ResultValue = nil,
		HasError = false,
		ErrorValue = nil,
		Reason = reason,
		FinallyHandlers = {},
		TokenHandle = tokenHandle,
		Name = nil,
	}
	return newTaskHandle(taskRec)
end

-- ── Combinators ───────────────────────────────────────────────────────────────

-- Creates a pending task + a settle function for event-driven combinators.
local function newManualTask(name: string?): (any, (status: Status, hasVal: boolean, val: any, reason: string?) -> ())
	local tokenRec: TokenRecord = {
		Cancelled = false,
		Reason = nil,
		OnCancelHandlers = {},
	}
	local tokenHandle = newTokenHandle(tokenRec)

	local taskRec: TaskRecord = {
		Status = "Pending",
		HasResult = false,
		ResultValue = nil,
		HasError = false,
		ErrorValue = nil,
		Reason = nil,
		FinallyHandlers = {},
		TokenHandle = tokenHandle,
		Name = name,
	}
	local taskHandle = newTaskHandle(taskRec)
	emitTrace("Start", taskRec)

	local function settle(status: Status, hasVal: boolean, val: any, reason: string?)
		settleTask(taskHandle, status, hasVal, val, reason)
	end

	return taskHandle, settle
end

function Task.Timeout(inner: any, seconds: number, reason: string?): any
	if type(seconds) ~= "number" or seconds <= 0 then
		error("Task.Timeout: seconds must be positive", 2)
	end
	local innerTask: any
	if type(inner) == "function" then
		local ok, result = pcall(inner)
		if not ok then
			error("Task.Timeout: thunk errored: " .. tostring(result), 2)
		end
		innerTask = result
		if not isTaskHandle(innerTask) then
			error("Task.Timeout: thunk must return a Task", 2)
		end
	elseif isTaskHandle(inner) then
		innerTask = inner
	else
		error("Task.Timeout: inner must be a Task or function returning a Task", 2)
	end

	local outerHandle, settle = newManualTask(nil)
	local done = false

	local timeoutReason = if reason ~= nil then reason else Task.Reason.Timeout

	local timerHandle = Scheduler.Delay(seconds, function()
		if done then return end
		done = true
		cancelTask(innerTask, timeoutReason)
		settle("Cancelled", false, nil, timeoutReason)
	end)

	innerTask:Finally(function(status: Status, value: unknown?)
		if done then return end
		done = true
		Scheduler.Cancel(timerHandle)
		if status == "Fulfilled" then
			local rec = taskRecords[innerTask]
			settle("Fulfilled", rec.HasResult, rec.ResultValue, nil)
		elseif status == "Errored" then
			local rec = taskRecords[innerTask]
			settle("Errored", rec.HasError, rec.ErrorValue, nil)
		else
			local rec = taskRecords[innerTask]
			settle("Cancelled", false, nil, rec.Reason)
		end
	end)

	return outerHandle
end

function Task.Retry(makeTask: (token: Token) -> any, opts: RetryOptions): any
	if type(opts) ~= "table" then
		error("Task.Retry: opts must be a table", 2)
	end
	local count = (opts :: any).Count
	local backoff = (opts :: any).Backoff
	local base = (opts :: any).Base
	local jitter = (opts :: any).Jitter

	if type(count) ~= "number" or count < 1 or math.floor(count) ~= count then
		error("Task.Retry: Count must be a positive integer", 2)
	end
	if backoff ~= "Fixed" and backoff ~= "Expo" then
		error("Task.Retry: Backoff must be 'Fixed' or 'Expo'", 2)
	end
	if type(base) ~= "number" or base < 0 then
		error("Task.Retry: Base must be >= 0", 2)
	end
	if jitter ~= nil and (type(jitter) ~= "number" or jitter < 0) then
		error("Task.Retry: Jitter must be >= 0 or nil", 2)
	end
	if type(makeTask) ~= "function" then
		error("Task.Retry: makeTask must be a function", 2)
	end

	local outerTokenRec: TokenRecord = {
		Cancelled = false,
		Reason = nil,
		OnCancelHandlers = {},
	}
	local outerTokenHandle = newTokenHandle(outerTokenRec)

	local taskRec: TaskRecord = {
		Status = "Pending",
		HasResult = false,
		ResultValue = nil,
		HasError = false,
		ErrorValue = nil,
		Reason = nil,
		FinallyHandlers = {},
		TokenHandle = outerTokenHandle,
		Name = nil,
	}
	local outerHandle = newTaskHandle(taskRec)
	emitTrace("Start", taskRec)

	Scheduler.Defer(function()
		local co = coroutine.create(function()
			local lastError: any = nil
			local lastReason: string? = nil

			for attempt = 1, count do
				if outerTokenRec.Cancelled then
					settleTask(outerHandle, "Cancelled", false, nil, outerTokenRec.Reason)
					return
				end

				local childTokenRec: TokenRecord = {
					Cancelled = false,
					Reason = nil,
					OnCancelHandlers = {},
				}
				local childTokenHandle = newTokenHandle(childTokenRec)

				local outerCancelConn = outerTokenHandle:OnCancel(function(r: string?)
					cancelToken(childTokenHandle, r)
				end)

				local ok, result = pcall(makeTask, childTokenHandle)
				outerCancelConn:Disconnect()

				if not ok then
					lastError = result
					lastReason = nil
				else
					local childTask: any = result
					if isTaskHandle(childTask) then
						local awaitOk, awaitVal = childTask:Await()
						if awaitOk then
							settleTask(outerHandle, "Fulfilled", true, awaitVal, nil)
							return
						else
							local childRec = taskRecords[childTask]
							if childRec and childRec.Status == "Errored" then
								lastError = awaitVal
								lastReason = nil
							else
								lastReason = tostring(awaitVal)
								lastError = nil
							end
						end
					else
						settleTask(outerHandle, "Fulfilled", true, result, nil)
						return
					end
				end

				if attempt < count then
					local delay: number
					if backoff == "Fixed" then
						delay = base
					else
						delay = math.min(base * 2 ^ (attempt - 1), 30)
					end
					if jitter ~= nil then
						delay = delay * (1 + math.random() * (jitter :: number))
					end
					if delay > 0 then
						local sleepOk, sleepReason = Task.Sleep(delay, outerTokenHandle)
						if not sleepOk then
							settleTask(outerHandle, "Cancelled", false, nil, sleepReason)
							return
						end
					end
				end
			end

			if lastError ~= nil then
				settleTask(outerHandle, "Errored", true, lastError, nil)
			else
				settleTask(outerHandle, "Cancelled", false, nil, lastReason)
			end
		end)
		coroutine.resume(co)
	end)

	return outerHandle
end

function Task.All(tasks: { Task<any> }): any
	if type(tasks) ~= "table" then
		error("Task.All: tasks must be a non-empty dense array", 2)
	end
	local n = #tasks
	if n == 0 then
		error("Task.All: tasks must be a non-empty dense array", 2)
	end
	for i = 1, n do
		if not isTaskHandle(tasks[i]) then
			error("Task.All: task at index " .. i .. " is not a valid Task", 2)
		end
	end

	local outerHandle, settle = newManualTask(nil)
	local done = false
	local resultSlots: { { Value: any } } = table.create(n)
	local fulfilledCount = 0

	local function onChild(i: number, status: Status)
		if done then return end
		if status == "Fulfilled" then
			local childRec = taskRecords[tasks[i] :: any]
			resultSlots[i] = { Value = childRec.ResultValue }
			fulfilledCount += 1
			if fulfilledCount == n then
				done = true
				local packed = table.create(n)
				for j = 1, n do
					packed[j] = resultSlots[j].Value
				end
				settle("Fulfilled", true, packed, nil)
			end
		elseif status == "Errored" then
			done = true
			for j = 1, n do
				local t = tasks[j] :: any
				if taskRecords[t] and taskRecords[t].Status == "Pending" then
					cancelTask(t, Task.Reason.Superseded)
				end
			end
			local childRec = taskRecords[tasks[i] :: any]
			settle("Errored", childRec.HasError, childRec.ErrorValue, nil)
		else
			done = true
			for j = 1, n do
				local t = tasks[j] :: any
				if taskRecords[t] and taskRecords[t].Status == "Pending" then
					cancelTask(t, Task.Reason.Superseded)
				end
			end
			local childRec = taskRecords[tasks[i] :: any]
			settle("Cancelled", false, nil, childRec.Reason)
		end
	end

	for i = 1, n do
		local idx = i
		local t = tasks[i] :: any
		local rec = taskRecords[t]
		if rec.Status ~= "Pending" then
			Scheduler.Defer(function()
				onChild(idx, rec.Status)
			end)
		else
			t:Finally(function(status: Status, _value: unknown?)
				onChild(idx, status)
			end)
		end
	end

	return outerHandle
end

function Task.Race(tasks: { Task<any> }): any
	if type(tasks) ~= "table" then
		error("Task.Race: tasks must be a non-empty dense array", 2)
	end
	local n = #tasks
	if n == 0 then
		error("Task.Race: tasks must be a non-empty dense array", 2)
	end
	for i = 1, n do
		if not isTaskHandle(tasks[i]) then
			error("Task.Race: task at index " .. i .. " is not a valid Task", 2)
		end
	end

	local outerHandle, settle = newManualTask(nil)
	local done = false

	local function onChild(status: Status, taskHandle: any)
		if done then return end
		done = true
		local rec = taskRecords[taskHandle]
		if status == "Fulfilled" then
			settle("Fulfilled", rec.HasResult, rec.ResultValue, nil)
		elseif status == "Errored" then
			settle("Errored", rec.HasError, rec.ErrorValue, nil)
		else
			settle("Cancelled", false, nil, rec.Reason)
		end
	end

	for i = 1, n do
		local t = tasks[i] :: any
		local rec = taskRecords[t]
		if rec.Status ~= "Pending" then
			Scheduler.Defer(function()
				onChild(rec.Status, t)
			end)
		else
			t:Finally(function(status: Status, _value: unknown?)
				onChild(status, t)
			end)
		end
	end

	return outerHandle
end

function Task.Any(tasks: { Task<any> }): any
	if type(tasks) ~= "table" then
		error("Task.Any: tasks must be a non-empty dense array", 2)
	end
	local n = #tasks
	if n == 0 then
		error("Task.Any: tasks must be a non-empty dense array", 2)
	end
	for i = 1, n do
		if not isTaskHandle(tasks[i]) then
			error("Task.Any: task at index " .. i .. " is not a valid Task", 2)
		end
	end

	local outerHandle, settle = newManualTask(nil)
	local done = false
	local settledCount = 0
	local failures: { SettledResult } = {}

	local function onChild(i: number, status: Status, taskHandle: any)
		if done then return end
		local rec = taskRecords[taskHandle]
		if status == "Fulfilled" then
			done = true
			for j = 1, n do
				local t = tasks[j] :: any
				if taskRecords[t] and taskRecords[t].Status == "Pending" then
					cancelTask(t, Task.Reason.Superseded)
				end
			end
			settle("Fulfilled", rec.HasResult, rec.ResultValue, nil)
		else
			settledCount += 1
			local entry: SettledResult = {
				Status = status,
				Value = nil,
				Error = if status == "Errored" then rec.ErrorValue else nil,
				Reason = if status == "Cancelled" then rec.Reason else nil,
			}
			failures[i] = entry
			if settledCount == n then
				done = true
				settle("Errored", true, { Failures = failures }, nil)
			end
		end
	end

	for i = 1, n do
		local idx = i
		local t = tasks[i] :: any
		local rec = taskRecords[t]
		if rec.Status ~= "Pending" then
			Scheduler.Defer(function()
				onChild(idx, rec.Status, t)
			end)
		else
			t:Finally(function(status: Status, _value: unknown?)
				onChild(idx, status, t)
			end)
		end
	end

	return outerHandle
end

function Task.AllSettled(tasks: { Task<any> }): any
	if type(tasks) ~= "table" then
		error("Task.AllSettled: tasks must be a non-empty dense array", 2)
	end
	local n = #tasks
	if n == 0 then
		error("Task.AllSettled: tasks must be a non-empty dense array", 2)
	end
	for i = 1, n do
		if not isTaskHandle(tasks[i]) then
			error("Task.AllSettled: task at index " .. i .. " is not a valid Task", 2)
		end
	end

	local outerHandle, settle = newManualTask(nil)
	local settledCount = 0
	local results: { SettledResult } = table.create(n)

	local function onChild(i: number, status: Status, taskHandle: any)
		local rec = taskRecords[taskHandle]
		local entry: SettledResult = {
			Status = status,
			Value = if status == "Fulfilled" then rec.ResultValue else nil,
			Error = if status == "Errored" then rec.ErrorValue else nil,
			Reason = if status == "Cancelled" then rec.Reason else nil,
		}
		results[i] = entry
		settledCount += 1
		if settledCount == n then
			settle("Fulfilled", true, results, nil)
		end
	end

	for i = 1, n do
		local idx = i
		local t = tasks[i] :: any
		local rec = taskRecords[t]
		if rec.Status ~= "Pending" then
			Scheduler.Defer(function()
				onChild(idx, rec.Status, t)
			end)
		else
			t:Finally(function(status: Status, _value: unknown?)
				onChild(idx, status, t)
			end)
		end
	end

	return outerHandle
end

function Task.FromRoblox(rbxSignal: RBXScriptSignal, untilSignal: RBXScriptSignal?): any
	if typeof(rbxSignal) ~= "RBXScriptSignal" then
		error("Task.FromRoblox: rbxSignal must be an RBXScriptSignal", 2)
	end
	if untilSignal ~= nil and typeof(untilSignal) ~= "RBXScriptSignal" then
		error("Task.FromRoblox: untilSignal must be an RBXScriptSignal", 2)
	end

	local outerHandle, settle = newManualTask(nil)
	local done = false
	local mainConn: RBXScriptConnection
	local untilConn: RBXScriptConnection?

	local rec = taskRecords[outerHandle]
	local tokenHandle = rec.TokenHandle

	local function cleanup()
		mainConn:Disconnect()
		if untilConn ~= nil then
			untilConn:Disconnect()
		end
	end

	mainConn = rbxSignal:Connect(function(...)
		if done then return end
		done = true
		cleanup()
		local args = table.pack(...)
		settle("Fulfilled", true, args, nil)
	end)

	if untilSignal ~= nil then
		untilConn = untilSignal:Connect(function()
			if done then return end
			done = true
			cleanup()
			settle("Fulfilled", true, nil, nil)
		end)
	end

	tokenHandle:OnCancel(function(reason: string?)
		if done then return end
		done = true
		cleanup()
		settleTask(outerHandle, "Cancelled", false, nil, reason)
	end)

	return outerHandle
end

-- ── Group ─────────────────────────────────────────────────────────────────────

function Task.Group(opts: GroupOptions?): any
	if opts ~= nil and type(opts) ~= "table" then
		error("Task.Group: opts must be a table or nil", 2)
	end
	local name: string? = nil
	if opts ~= nil then
		name = (opts :: any).Name
		if name ~= nil and type(name) ~= "string" then
			error("Task.Group: Name must be a string or nil", 2)
		end
	end

	local rec: GroupRecord = {
		Destroyed = false,
		Name = name,
		PendingTasks = {},
	}
	return newGroupHandle(rec)
end

-- ── Predicates ────────────────────────────────────────────────────────────────

function Task.IsTask(value: unknown): boolean
	return isTaskHandle(value)
end

function Task.IsToken(value: unknown): boolean
	return isTokenHandle(value)
end

function Task.IsGroup(value: unknown): boolean
	return isGroupHandle(value)
end

function Task.SetTracer(fn: ((TraceEvent) -> ())?): ()
	if fn ~= nil and type(fn) ~= "function" then
		error("Task.SetTracer: fn must be a function or nil", 2)
	end
	_tracer = fn
end

-- ── Task instance methods ─────────────────────────────────────────────────────

function taskMethods:Token(): any
	local rec = taskRecords[self]
	if rec == nil then
		error("Task.Token: invalid task handle", 2)
	end
	return rec.TokenHandle
end

function taskMethods:Cancel(reason: string?): ()
	local rec = taskRecords[self]
	if rec == nil then
		error("Task.Cancel: invalid task handle", 2)
	end
	if rec.Status ~= "Pending" then
		return
	end
	local r = if reason ~= nil then reason else Task.Reason.User
	cancelToken(rec.TokenHandle, r)
	settleTask(self, "Cancelled", false, nil, r)
end

function taskMethods:Status(): Status
	local rec = taskRecords[self]
	if rec == nil then
		error("Task.Status: invalid task handle", 2)
	end
	return rec.Status
end

function taskMethods:IsPending(): boolean
	local rec = taskRecords[self]
	if rec == nil then
		error("Task.IsPending: invalid task handle", 2)
	end
	return rec.Status == "Pending"
end

function taskMethods:IsFulfilled(): boolean
	local rec = taskRecords[self]
	if rec == nil then
		error("Task.IsFulfilled: invalid task handle", 2)
	end
	return rec.Status == "Fulfilled"
end

function taskMethods:IsCancelled(): boolean
	local rec = taskRecords[self]
	if rec == nil then
		error("Task.IsCancelled: invalid task handle", 2)
	end
	return rec.Status == "Cancelled"
end

function taskMethods:IsErrored(): boolean
	local rec = taskRecords[self]
	if rec == nil then
		error("Task.IsErrored: invalid task handle", 2)
	end
	return rec.Status == "Errored"
end

function taskMethods:IsDone(): boolean
	local rec = taskRecords[self]
	if rec == nil then
		error("Task.IsDone: invalid task handle", 2)
	end
	return rec.Status ~= "Pending"
end

function taskMethods:Finally(fn: (status: Status, value: unknown?) -> ()): any
	if type(fn) ~= "function" then
		error("Task.Finally: fn must be a function", 2)
	end
	local rec = taskRecords[self]
	if rec == nil then
		error("Task.Finally: invalid task handle", 2)
	end
	if rec.Status == "Pending" then
		table.insert(rec.FinallyHandlers, { Fn = fn })
	else
		local status = rec.Status
		local value: unknown?
		if status == "Fulfilled" then
			value = if rec.HasResult then rec.ResultValue else nil
		elseif status == "Errored" then
			value = if rec.HasError then rec.ErrorValue else nil
		elseif status == "Cancelled" then
			value = rec.Reason
		end
		Scheduler.Defer(function()
			local ok, err = pcall(fn, status, value)
			if not ok then
				ErrorHandler.Report({ Module = "Task", Phase = "Finally", Error = err })
			end
		end)
	end
	return self
end

function taskMethods:Await(token: Token?): (boolean, any)
	local rec = taskRecords[self]
	if rec == nil then
		error("Task.Await: invalid task handle", 2)
	end
	if token ~= nil and not isTokenHandle(token) then
		error("Task.Await: invalid token", 2)
	end

	if rec.Status ~= "Pending" then
		if rec.Status == "Fulfilled" then
			return true, rec.ResultValue
		elseif rec.Status == "Errored" then
			return false, rec.ErrorValue
		else
			return false, rec.Reason
		end
	end

	if not coroutine.isyieldable() then
		error("Task.Await: must be called from a yieldable coroutine", 2)
	end

	local thread = coroutine.running()
	local awaitDone = false
	local cancelConn: Connection.Connection? = nil

	if token ~= nil then
		local tokenRec = tokenRecords[token :: any]
		if tokenRec.Cancelled then
			return false, tokenRec.Reason
		end
		cancelConn = (token :: any):OnCancel(function(reason: string?)
			if awaitDone then return end
			awaitDone = true
			Scheduler.Defer(function()
				coroutine.resume(thread, false, reason)
			end)
		end)
	end

	self:Finally(function(status: Status, _value: unknown?)
		if awaitDone then return end
		awaitDone = true
		if cancelConn ~= nil then
			cancelConn:Disconnect()
		end
		local r = taskRecords[self]
		Scheduler.Defer(function()
			if status == "Fulfilled" then
				coroutine.resume(thread, true, r.ResultValue)
			elseif status == "Errored" then
				coroutine.resume(thread, false, r.ErrorValue)
			else
				coroutine.resume(thread, false, r.Reason)
			end
		end)
	end)

	return coroutine.yield() :: any
end

function taskMethods:Unwrap(token: Token?): any
	local ok, value = self:Await(token)
	if not ok then
		error(value, 2)
	end
	return value
end

function taskMethods:Result(): (boolean, any)
	local rec = taskRecords[self]
	if rec == nil then
		error("Task.Result: invalid task handle", 2)
	end
	if rec.Status == "Fulfilled" then
		return true, rec.ResultValue
	end
	return false, nil
end

function taskMethods:Error(): (boolean, any)
	local rec = taskRecords[self]
	if rec == nil then
		error("Task.Error: invalid task handle", 2)
	end
	if rec.Status == "Errored" then
		return true, rec.ErrorValue
	end
	return false, nil
end

function taskMethods:Name(): string?
	local rec = taskRecords[self]
	if rec == nil then
		error("Task.Name: invalid task handle", 2)
	end
	return rec.Name
end

-- ── Token instance methods ────────────────────────────────────────────────────

function tokenMethods:Cancelled(): boolean
	local rec = tokenRecords[self]
	if rec == nil then
		error("Token.Cancelled: invalid token handle", 2)
	end
	return rec.Cancelled
end

function tokenMethods:Reason(): string?
	local rec = tokenRecords[self]
	if rec == nil then
		error("Token.Reason: invalid token handle", 2)
	end
	return rec.Reason
end

function tokenMethods:OnCancel(fn: (reason: string?) -> ()): Connection.Connection
	if type(fn) ~= "function" then
		error("Token.OnCancel: fn must be a function", 2)
	end
	local rec = tokenRecords[self]
	if rec == nil then
		error("Token.OnCancel: invalid token handle", 2)
	end

	if rec.Cancelled then
		local r = rec.Reason
		Scheduler.Defer(function()
			local ok, err = pcall(fn, r)
			if not ok then
				ErrorHandler.Report({ Module = "Task", Phase = "TokenCancel", Error = err })
			end
		end)
		local conn = Connection.New(function() end)
		conn:Disconnect()
		return conn
	end

	local entry: OnCancelEntry = { Fn = fn, Connected = true }
	table.insert(rec.OnCancelHandlers, entry)

	return Connection.New(function()
		entry.Connected = false
	end)
end

-- ── Group instance methods ────────────────────────────────────────────────────

function groupMethods:Add(task: Task<any>): any
	local rec = groupRecords[self]
	if rec == nil or rec.Destroyed then
		error("Group.Add: group is destroyed", 2)
	end
	if not isTaskHandle(task) then
		error("Group.Add: invalid task handle", 2)
	end
	local taskRec = taskRecords[task :: any]
	if taskRec.Status ~= "Pending" then
		return self
	end
	rec.PendingTasks[task :: any] = true
	(task :: any):Finally(function(_status: Status, _value: unknown?)
		rec.PendingTasks[task :: any] = nil
	end)
	return self
end

function groupMethods:Start(fn: (token: Token) -> any, opts: TaskOptions?): any
	local rec = groupRecords[self]
	if rec == nil or rec.Destroyed then
		error("Group.Start: group is destroyed", 2)
	end
	local t = Task.Start(fn, opts)
	self:Add(t)
	return t
end

function groupMethods:CancelAll(reason: string?): ()
	local rec = groupRecords[self]
	if rec == nil then
		error("Group.CancelAll: invalid group handle", 2)
	end
	local r = if reason ~= nil then reason else Task.Reason.ModeExit
	local snapshot = {}
	for t in rec.PendingTasks do
		table.insert(snapshot, t)
	end
	for _, t in snapshot do
		cancelTask(t, r)
	end
end

function groupMethods:JoinAll(): any
	local rec = groupRecords[self]
	if rec == nil then
		error("Group.JoinAll: invalid group handle", 2)
	end
	local snapshot: { any } = {}
	for t in rec.PendingTasks do
		table.insert(snapshot, t)
	end

	if #snapshot == 0 then
		return Task.Resolved(nil)
	end

	local outerHandle, settle = newManualTask(nil)
	local remaining = #snapshot

	for _, t in snapshot do
		t:Finally(function(_status: Status, _value: unknown?)
			remaining -= 1
			if remaining == 0 then
				settle("Fulfilled", true, nil, nil)
			end
		end)
	end

	return outerHandle
end

function groupMethods:Race(): any
	local rec = groupRecords[self]
	if rec == nil then
		error("Group.Race: invalid group handle", 2)
	end
	local snapshot: { any } = {}
	for t in rec.PendingTasks do
		table.insert(snapshot, t)
	end

	if #snapshot == 0 then
		local outerHandle, _settle = newManualTask(nil)
		return outerHandle
	end

	return Task.Race(snapshot)
end

function groupMethods:Destroy(reason: string?): ()
	local rec = groupRecords[self]
	if rec == nil or rec.Destroyed then
		return
	end
	rec.Destroyed = true
	local r = if reason ~= nil then reason else Task.Reason.ModeExit
	local snapshot = {}
	for t in rec.PendingTasks do
		table.insert(snapshot, t)
	end
	for _, t in snapshot do
		cancelTask(t, r)
	end
	table.clear(rec.PendingTasks)
end

function groupMethods:Size(): number
	local rec = groupRecords[self]
	if rec == nil then
		error("Group.Size: invalid group handle", 2)
	end
	local count = 0
	for _ in rec.PendingTasks do
		count += 1
	end
	return count
end

function groupMethods:Name(): string?
	local rec = groupRecords[self]
	if rec == nil then
		error("Group.Name: invalid group handle", 2)
	end
	return rec.Name
end

return Task
