--!strict

local Connection = require(script.Parent.Parent.Connection)
local ErrorHandler = require(script.Parent.Parent.ErrorHandler)
local Scheduler = require(script.Parent.Parent.Scheduler)
local Types = require(script.Parent._Types)
local Validation = require(script.Parent._Validation)

type Status = Types.Status
type Token = Types.Token
type Task<T> = Types.Task<T>
type TaskGroup = Types.TaskGroup
type TaskOptions = Types.TaskOptions
type GroupOptions = Types.GroupOptions
type TraceEvent = Types.TraceEvent
type StatusSet = Types.StatusSet
type ReasonSet = Types.ReasonSet
type BackoffSet = Types.BackoffSet


type FinallyCallback = (status: Status, value: unknown?) -> ()
type CancellationCallback = (reason: string?) -> ()

export type TokenRecord = {
	Cancelled: boolean,
	Reason: string?,
	CancellationCallbacks: { CancellationCallback },
}

export type TaskRecord = {
	Status: Status,
	Value: unknown?,
	Error: unknown?,
	Reason: string?,
	Name: string?,
	Token: Token,
	TokenRecord: TokenRecord,
	FinallyCallbacks: { FinallyCallback },
}

export type GroupRecord = {
	Name: string?,
	Destroyed: boolean,
	PendingTasks: { [Task<any>]: boolean },
}


local taskHandleMethods = {}
local tokenHandleMethods = {}
local groupHandleMethods = {}

local taskRecords: { [Task<any>]: TaskRecord } = setmetatable({}, { __mode = "k" }) :: any
local tokenRecords: { [Token]: TokenRecord } = setmetatable({}, { __mode = "k" }) :: any
local groupRecords: { [TaskGroup]: GroupRecord } = setmetatable({}, { __mode = "k" }) :: any

local taskMetatable = table.freeze({ __index = taskHandleMethods, __metatable = "Task" })
local tokenMetatable = table.freeze({ __index = tokenHandleMethods, __metatable = "Task.Token" })
local groupMetatable = table.freeze({ __index = groupHandleMethods, __metatable = "Task.Group" })

local activeTracer: ((TraceEvent) -> ())? = nil

local Records = {}


-- ── Enum ──────────────────────────────────────────────────────────────────────

local pendingStatus: "Pending" = "Pending"
local fulfilledStatus: "Fulfilled" = "Fulfilled"
local cancelledStatus: "Cancelled" = "Cancelled"
local erroredStatus: "Errored" = "Errored"

local statusEnum: StatusSet = table.freeze({
	Pending = pendingStatus,
	Fulfilled = fulfilledStatus,
	Cancelled = cancelledStatus,
	Errored = erroredStatus,
})

Records.Status = statusEnum

Records.Reason = table.freeze({
	ModeExit = "ModeExit",
	GuardFalse = "GuardFalse",
	Superseded = "Superseded",
	Timeout = "Timeout",
	User = "User",
	Shutdown = "Shutdown",
	Capacity = "Capacity",
}) :: ReasonSet

local fixedBackoff: "Fixed" = "Fixed"
local expoBackoff: "Expo" = "Expo"

local backoffEnum: BackoffSet = table.freeze({
	Fixed = fixedBackoff,
	Expo = expoBackoff,
})

Records.Backoff = backoffEnum


-- ── Tracer ────────────────────────────────────────────────────────────────────

function Records.SetTracer(tracer: ((TraceEvent) -> ())?): ()
	if tracer ~= nil and typeof(tracer) ~= "function" then
		Validation.raiseUsageError("Task.SetTracer: tracer must be a function or nil")
	end

	activeTracer = tracer
end

function Records.EmitTrace(eventName: "Start" | "Done" | "Cancel" | "Error", taskRecord: TaskRecord): ()
	local tracer = activeTracer

	if tracer == nil then
		return
	end

	ErrorHandler.Protect(function()
		tracer({
			Event = eventName,
			Name = taskRecord.Name,
			Status = taskRecord.Status,
		})
	end, "Task", "Tracer", taskRecord.Name)
end


-- ── Record creation ───────────────────────────────────────────────────────────

function Records.CreateTokenRecord(): (Token, TokenRecord)
	local token = setmetatable({}, tokenMetatable) :: any
	local tokenRecord: TokenRecord = {
		Cancelled = false,
		Reason = nil,
		CancellationCallbacks = {},
	}

	tokenRecords[token] = tokenRecord

	return token, tokenRecord
end

function Records.CreatePendingTaskRecord(name: string?): (Task<any>, TaskRecord)
	local token, tokenRecord = Records.CreateTokenRecord()
	local task = setmetatable({}, taskMetatable) :: any
	local taskRecord: TaskRecord = {
		Status = Records.Status.Pending,
		Value = nil,
		Error = nil,
		Reason = nil,
		Name = name,
		Token = token,
		TokenRecord = tokenRecord,
		FinallyCallbacks = {},
	}

	taskRecords[task] = taskRecord
	Records.EmitTrace("Start", taskRecord)

	return task, taskRecord
end

function Records.CreateGroupRecord(name: string?): (TaskGroup, GroupRecord)
	local group = setmetatable({}, groupMetatable) :: any
	local groupRecord: GroupRecord = {
		Name = name,
		Destroyed = false,
		PendingTasks = {},
	}

	groupRecords[group] = groupRecord

	return group, groupRecord
end


-- ── Record lookup ─────────────────────────────────────────────────────────────

function Records.ValueIsLiveTask(value: unknown): boolean
	return taskRecords[value :: any] ~= nil
end

function Records.ValueIsLiveToken(value: unknown): boolean
	return tokenRecords[value :: any] ~= nil
end

function Records.ValueIsLiveGroup(value: unknown): boolean
	return groupRecords[value :: any] ~= nil
end

function Records.GetTaskRecord(task: Task<any>, usageErrorMessage: string): TaskRecord
	local taskRecord = taskRecords[task]

	if taskRecord == nil then
		Validation.raiseUsageError(usageErrorMessage)
	end

	return taskRecord
end

function Records.GetTokenRecord(token: Token, usageErrorMessage: string): TokenRecord
	local tokenRecord = tokenRecords[token]

	if tokenRecord == nil then
		Validation.raiseUsageError(usageErrorMessage)
	end

	return tokenRecord
end

function Records.GetGroupRecord(group: TaskGroup, usageErrorMessage: string): GroupRecord
	local groupRecord = groupRecords[group]

	if groupRecord == nil then
		Validation.raiseUsageError(usageErrorMessage)
	end

	return groupRecord
end


-- ── Task settlement ───────────────────────────────────────────────────────────

function Records.CancelToken(tokenRecord: TokenRecord, reason: string?): ()
	if tokenRecord.Cancelled then
		return
	end

	tokenRecord.Cancelled = true
	tokenRecord.Reason = reason

	local callbacks = tokenRecord.CancellationCallbacks
	tokenRecord.CancellationCallbacks = {}

	for _, callback in callbacks do
		Scheduler.Defer(function()
			ErrorHandler.Protect(function()
				callback(reason)
			end, "Task", "TokenCancel")
		end)
	end
end

function Records.SettlePendingTask(taskRecord: TaskRecord, status: Status, value: unknown?): ()
	if taskRecord.Status ~= Records.Status.Pending then
		return
	end

	taskRecord.Status = status

	if status == Records.Status.Fulfilled then
		taskRecord.Value = value
	elseif status == Records.Status.Cancelled then
		taskRecord.Reason = value :: string?
		Records.CancelToken(taskRecord.TokenRecord, taskRecord.Reason)
	elseif status == Records.Status.Errored then
		taskRecord.Error = value
	end

	Records.EmitTrace(if status == Records.Status.Errored then "Error" elseif status == Records.Status.Cancelled then "Cancel" else "Done", taskRecord)
	Records.ScheduleFinallyCallbacks(taskRecord)
end

function Records.CancelTask(task: Task<any>, reason: string?): ()
	local taskRecord = Records.GetTaskRecord(task, "Task.Cancel: invalid task handle")
	Records.SettlePendingTask(taskRecord, Records.Status.Cancelled, reason or Records.Reason.User)
end

function Records.ScheduleFinallyCallbacks(taskRecord: TaskRecord): ()
	local callbacks = taskRecord.FinallyCallbacks
	taskRecord.FinallyCallbacks = {}

	local status = taskRecord.Status
	local settledValue = if status == Records.Status.Fulfilled then taskRecord.Value elseif status == Records.Status.Errored then taskRecord.Error else taskRecord.Reason

	for _, callback in callbacks do
		Scheduler.Defer(function()
			ErrorHandler.Protect(function()
				callback(status :: any, settledValue)
			end, "Task", "Finally", taskRecord.Name)
		end)
	end
end

function Records.ReadSettledTaskResult(taskRecord: TaskRecord): (boolean, any)
	if taskRecord.Status == Records.Status.Fulfilled then
		return true, taskRecord.Value
	end

	if taskRecord.Status == Records.Status.Errored then
		return false, taskRecord.Error
	end

	return false, taskRecord.Reason
end


-- ── Option validation ─────────────────────────────────────────────────────────

function Records.ValidateTaskOptions(options: TaskOptions?, usagePrefix: string): string?
	Validation.ensureValueIsTableOrNil(options, `{usagePrefix}: opts must be a table or nil`)

	if options == nil then
		return nil
	end

	Validation.ensureValueIsStringOrNil(options.Name, `{usagePrefix}: Name must be a string or nil`)

	return options.Name
end

function Records.ValidateGroupOptions(options: GroupOptions?, usagePrefix: string): string?
	Validation.ensureValueIsTableOrNil(options, `{usagePrefix}: opts must be a table or nil`)

	if options == nil then
		return nil
	end

	Validation.ensureValueIsStringOrNil(options.Name, `{usagePrefix}: Name must be a string or nil`)

	return options.Name
end


-- ── Task handle methods ───────────────────────────────────────────────────────

function taskHandleMethods:Token(): Token
	return Records.GetTaskRecord(self :: any, "Task.Token: invalid task handle").Token
end

function taskHandleMethods:Cancel(reason: string?): ()
	Records.CancelTask(self :: any, reason)
end

function taskHandleMethods:Status(): Status
	return Records.GetTaskRecord(self :: any, "Task.Status: invalid task handle").Status
end

function taskHandleMethods:IsPending(): boolean
	return Records.GetTaskRecord(self :: any, "Task.IsPending: invalid task handle").Status == Records.Status.Pending
end

function taskHandleMethods:IsFulfilled(): boolean
	return Records.GetTaskRecord(self :: any, "Task.IsFulfilled: invalid task handle").Status == Records.Status.Fulfilled
end

function taskHandleMethods:IsCancelled(): boolean
	return Records.GetTaskRecord(self :: any, "Task.IsCancelled: invalid task handle").Status == Records.Status.Cancelled
end

function taskHandleMethods:IsErrored(): boolean
	return Records.GetTaskRecord(self :: any, "Task.IsErrored: invalid task handle").Status == Records.Status.Errored
end

function taskHandleMethods:IsDone(): boolean
	return Records.GetTaskRecord(self :: any, "Task.IsDone: invalid task handle").Status ~= Records.Status.Pending
end

function taskHandleMethods:Finally(callback: (status: Status, value: unknown?) -> ()): any
	Validation.ensureValueIsFunction(callback, "Task.Finally: fn must be a function")

	local taskRecord = Records.GetTaskRecord(self :: any, "Task.Finally: invalid task handle")

	if taskRecord.Status == Records.Status.Pending then
		table.insert(taskRecord.FinallyCallbacks, callback)
	else
		local status = taskRecord.Status
		local settledValue = if status == Records.Status.Fulfilled then taskRecord.Value elseif status == Records.Status.Errored then taskRecord.Error else taskRecord.Reason

		Scheduler.Defer(function()
			ErrorHandler.Protect(function()
				callback(status :: any, settledValue)
			end, "Task", "Finally", taskRecord.Name)
		end)
	end

	return self
end

function taskHandleMethods:Await(token: Token?): (boolean, any)
	local taskRecord = Records.GetTaskRecord(self :: any, "Task.Await: invalid task handle")

	if token ~= nil and not Records.ValueIsLiveToken(token) then
		Validation.raiseUsageError("Task.Await: invalid token")
	end

	if taskRecord.Status ~= Records.Status.Pending then
		return Records.ReadSettledTaskResult(taskRecord)
	end

	local runningCoroutine = coroutine.running()

	if runningCoroutine == nil or not coroutine.isyieldable() then
		Validation.raiseUsageError("Task.Await: must be called from a yieldable coroutine")
	end

	local resumed = false
	local cancellationConnection: Connection.Connection? = nil

	local function resumeAwait(success: boolean, value: unknown?): ()
		if resumed then
			return
		end

		resumed = true

		if cancellationConnection ~= nil then
			cancellationConnection:Disconnect()
		end

		coroutine.resume(runningCoroutine, success, value)
	end

	if token ~= nil then
		local awaitTokenRecord = Records.GetTokenRecord(token, "Task.Await: invalid token")

		if awaitTokenRecord.Cancelled then
			return false, awaitTokenRecord.Reason
		end

		cancellationConnection = token:OnCancel(function(reason)
			resumeAwait(false, reason)
		end)
	end

	self:Finally(function(status, value)
		if status == Records.Status.Fulfilled then
			resumeAwait(true, value)
		else
			resumeAwait(false, value)
		end
	end)

	return coroutine.yield()
end

function taskHandleMethods:Unwrap(token: Token?): any
	local success, value = self:Await(token)

	if success then
		return value
	end

	error(value, 2)
end

function taskHandleMethods:Result(): (boolean, any)
	local taskRecord = Records.GetTaskRecord(self :: any, "Task.Result: invalid task handle")

	if taskRecord.Status == Records.Status.Fulfilled then
		return true, taskRecord.Value
	end

	return false, nil
end

function taskHandleMethods:Error(): (boolean, any)
	local taskRecord = Records.GetTaskRecord(self :: any, "Task.Error: invalid task handle")

	if taskRecord.Status == Records.Status.Errored then
		return true, taskRecord.Error
	end

	return false, nil
end

function taskHandleMethods:Name(): string?
	return Records.GetTaskRecord(self :: any, "Task.Name: invalid task handle").Name
end


-- ── Token handle methods ──────────────────────────────────────────────────────

function tokenHandleMethods:Cancelled(): boolean
	return Records.GetTokenRecord(self :: any, "Token.Cancelled: invalid token handle").Cancelled
end

function tokenHandleMethods:Reason(): string?
	return Records.GetTokenRecord(self :: any, "Token.Reason: invalid token handle").Reason
end

function tokenHandleMethods:OnCancel(callback: (reason: string?) -> ()): Connection.Connection
	Validation.ensureValueIsFunction(callback, "Token.OnCancel: fn must be a function")

	local tokenRecord = Records.GetTokenRecord(self :: any, "Token.OnCancel: invalid token handle")

	if tokenRecord.Cancelled then
		Scheduler.Defer(function()
			ErrorHandler.Protect(function()
				callback(tokenRecord.Reason)
			end, "Task", "TokenCancel")
		end)

		local alreadyDisconnectedConnection = Connection.New(nil)
		alreadyDisconnectedConnection:Disconnect()
		return alreadyDisconnectedConnection
	end

	local callbackIsConnected = true
	table.insert(tokenRecord.CancellationCallbacks, callback)

	return Connection.New(function()
		if not callbackIsConnected then
			return
		end

		callbackIsConnected = false

		local callbackIndex = table.find(tokenRecord.CancellationCallbacks, callback)
		if callbackIndex ~= nil then
			table.remove(tokenRecord.CancellationCallbacks, callbackIndex)
		end
	end)
end


-- ── Group handle methods ──────────────────────────────────────────────────────

function groupHandleMethods:Add(task: Task<any>): any
	local groupRecord = Records.GetGroupRecord(self :: any, "Group.Add: invalid group handle")

	if groupRecord.Destroyed then
		Validation.raiseUsageError("Group.Add: group is destroyed")
	end

	if not Records.ValueIsLiveTask(task) then
		Validation.raiseUsageError("Group.Add: invalid task handle")
	end

	if not task:IsDone() then
		groupRecord.PendingTasks[task] = true
		task:Finally(function()
			groupRecord.PendingTasks[task] = nil
		end)
	end

	return self
end

function groupHandleMethods:CancelAll(reason: string?): ()
	local groupRecord = Records.GetGroupRecord(self :: any, "Group.CancelAll: invalid group handle")
	local cancellationReason = reason or Records.Reason.ModeExit

	for task in groupRecord.PendingTasks do
		task:Cancel(cancellationReason)
	end
end

function groupHandleMethods:Destroy(reason: string?): ()
	local groupRecord = Records.GetGroupRecord(self :: any, "Group.Destroy: invalid group handle")

	if groupRecord.Destroyed then
		return
	end

	groupRecord.Destroyed = true
	;(self :: any):CancelAll(reason or Records.Reason.ModeExit)
	table.clear(groupRecord.PendingTasks)
end

function groupHandleMethods:Size(): number
	local groupRecord = Records.GetGroupRecord(self :: any, "Group.Size: invalid group handle")
	local size = 0

	for _ in groupRecord.PendingTasks do
		size += 1
	end

	return size
end

function groupHandleMethods:Name(): string?
	return Records.GetGroupRecord(self :: any, "Group.Name: invalid group handle").Name
end


return table.freeze(Records)
