--!strict

local Connection = require(script.Parent.Parent.Connection)
local ErrorHandler = require(script.Parent.Parent.ErrorHandler)
local Scheduler = require(script.Parent.Parent.Scheduler)
local Validation = require(script.Parent._Validation)

export type Status = "Pending" | "Fulfilled" | "Cancelled" | "Errored"
export type CancellationReason = string
export type Backoff = "Fixed" | "Expo"

export type Token = {
	Cancelled: (self: Token) -> boolean,
	Reason: (self: Token) -> string?,
	OnCancel: (self: Token, callback: (reason: string?) -> ()) -> Connection.Connection,
}

export type Task<T> = {
	Token: (self: Task<T>) -> Token,
	Cancel: (self: Task<T>, reason: string?) -> (),
	Status: (self: Task<T>) -> Status,
	IsPending: (self: Task<T>) -> boolean,
	IsFulfilled: (self: Task<T>) -> boolean,
	IsCancelled: (self: Task<T>) -> boolean,
	IsErrored: (self: Task<T>) -> boolean,
	IsDone: (self: Task<T>) -> boolean,
	Finally: (self: Task<T>, callback: (status: Status, value: unknown?) -> ()) -> Task<T>,
	Await: (self: Task<T>, token: Token?) -> (boolean, T | unknown),
	Unwrap: (self: Task<T>, token: Token?) -> T,
	Result: (self: Task<T>) -> (boolean, T?),
	Error: (self: Task<T>) -> (boolean, unknown?),
	Name: (self: Task<T>) -> string?,
}

export type TaskGroup = {
	Add: (self: TaskGroup, task: Task<any>) -> TaskGroup,
	Start: (self: TaskGroup, taskBody: (Token) -> any, options: TaskOptions?) -> Task<any>,
	CancelAll: (self: TaskGroup, reason: string?) -> (),
	JoinAll: (self: TaskGroup) -> Task<nil>,
	Race: (self: TaskGroup) -> Task<any>,
	Destroy: (self: TaskGroup, reason: string?) -> (),
	Size: (self: TaskGroup) -> number,
	Name: (self: TaskGroup) -> string?,
}

export type TaskOptions = { Name: string? }
export type GroupOptions = { Name: string? }

export type TraceEvent = {
	Event: "Start" | "Done" | "Cancel" | "Error",
	Name: string?,
	Status: Status?,
}

export type StatusSet = {
	Pending: "Pending",
	Fulfilled: "Fulfilled",
	Cancelled: "Cancelled",
	Errored: "Errored",
}

export type ReasonSet = {
	ModeExit: string,
	GuardFalse: string,
	Superseded: string,
	Timeout: string,
	User: string,
	Shutdown: string,
	Capacity: string,
}

export type BackoffSet = {
	Fixed: "Fixed",
	Expo: "Expo",
}

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

local Runtime = {}

Runtime.Status = (table.freeze({
	Pending = "Pending",
	Fulfilled = "Fulfilled",
	Cancelled = "Cancelled",
	Errored = "Errored",
}) :: any) :: StatusSet

Runtime.Reason = table.freeze({
	ModeExit = "ModeExit",
	GuardFalse = "GuardFalse",
	Superseded = "Superseded",
	Timeout = "Timeout",
	User = "User",
	Shutdown = "Shutdown",
	Capacity = "Capacity",
}) :: ReasonSet

Runtime.Backoff = (table.freeze({
	Fixed = "Fixed",
	Expo = "Expo",
}) :: any) :: BackoffSet

function Runtime.SetTracer(tracer: ((TraceEvent) -> ())?): ()
	if tracer ~= nil and typeof(tracer) ~= "function" then
		Validation.raiseUsageError("Task.SetTracer: tracer must be a function or nil")
	end

	activeTracer = tracer
end

function Runtime.EmitTrace(eventName: "Start" | "Done" | "Cancel" | "Error", taskRecord: TaskRecord): ()
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

function Runtime.CreateTokenRecord(): (Token, TokenRecord)
	local token = setmetatable({}, tokenMetatable) :: any
	local tokenRecord: TokenRecord = {
		Cancelled = false,
		Reason = nil,
		CancellationCallbacks = {},
	}

	tokenRecords[token] = tokenRecord

	return token, tokenRecord
end

function Runtime.CreatePendingTaskRecord(name: string?): (Task<any>, TaskRecord)
	local token, tokenRecord = Runtime.CreateTokenRecord()
	local task = setmetatable({}, taskMetatable) :: any
	local taskRecord: TaskRecord = {
		Status = Runtime.Status.Pending,
		Value = nil,
		Error = nil,
		Reason = nil,
		Name = name,
		Token = token,
		TokenRecord = tokenRecord,
		FinallyCallbacks = {},
	}

	taskRecords[task] = taskRecord
	Runtime.EmitTrace("Start", taskRecord)

	return task, taskRecord
end

function Runtime.CreateGroupRecord(name: string?): (TaskGroup, GroupRecord)
	local group = setmetatable({}, groupMetatable) :: any
	local groupRecord: GroupRecord = {
		Name = name,
		Destroyed = false,
		PendingTasks = {},
	}

	groupRecords[group] = groupRecord

	return group, groupRecord
end

function Runtime.ValueIsLiveTask(value: unknown): boolean
	return taskRecords[value :: any] ~= nil
end

function Runtime.ValueIsLiveToken(value: unknown): boolean
	return tokenRecords[value :: any] ~= nil
end

function Runtime.ValueIsLiveGroup(value: unknown): boolean
	return groupRecords[value :: any] ~= nil
end

function Runtime.GetTaskRecord(task: Task<any>, usageErrorMessage: string): TaskRecord
	local taskRecord = taskRecords[task]

	if taskRecord == nil then
		Validation.raiseUsageError(usageErrorMessage)
	end

	return taskRecord
end

function Runtime.GetTokenRecord(token: Token, usageErrorMessage: string): TokenRecord
	local tokenRecord = tokenRecords[token]

	if tokenRecord == nil then
		Validation.raiseUsageError(usageErrorMessage)
	end

	return tokenRecord
end

function Runtime.GetGroupRecord(group: TaskGroup, usageErrorMessage: string): GroupRecord
	local groupRecord = groupRecords[group]

	if groupRecord == nil then
		Validation.raiseUsageError(usageErrorMessage)
	end

	return groupRecord
end

function Runtime.CancelToken(tokenRecord: TokenRecord, reason: string?): ()
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

function Runtime.SettlePendingTask(taskRecord: TaskRecord, status: Status, value: unknown?): ()
	if taskRecord.Status ~= Runtime.Status.Pending then
		return
	end

	taskRecord.Status = status

	if status == Runtime.Status.Fulfilled then
		taskRecord.Value = value
	elseif status == Runtime.Status.Cancelled then
		taskRecord.Reason = value :: string?
		Runtime.CancelToken(taskRecord.TokenRecord, taskRecord.Reason)
	elseif status == Runtime.Status.Errored then
		taskRecord.Error = value
	end

	Runtime.EmitTrace(if status == Runtime.Status.Errored then "Error" elseif status == Runtime.Status.Cancelled then "Cancel" else "Done", taskRecord)
	Runtime.ScheduleFinallyCallbacks(taskRecord)
end

function Runtime.CancelTask(task: Task<any>, reason: string?): ()
	local taskRecord = Runtime.GetTaskRecord(task, "Task.Cancel: invalid task handle")
	Runtime.SettlePendingTask(taskRecord, Runtime.Status.Cancelled, reason or Runtime.Reason.User)
end

function Runtime.ScheduleFinallyCallbacks(taskRecord: TaskRecord): ()
	local callbacks = taskRecord.FinallyCallbacks
	taskRecord.FinallyCallbacks = {}

	local status = taskRecord.Status
	local settledValue = if status == Runtime.Status.Fulfilled then taskRecord.Value elseif status == Runtime.Status.Errored then taskRecord.Error else taskRecord.Reason

	for _, callback in callbacks do
		Scheduler.Defer(function()
			ErrorHandler.Protect(function()
				callback(status :: any, settledValue)
			end, "Task", "Finally", taskRecord.Name)
		end)
	end
end

function Runtime.ValidateTaskOptions(options: TaskOptions?, usagePrefix: string): string?
	Validation.ensureValueIsTableOrNil(options, `{usagePrefix}: opts must be a table or nil`)

	if options == nil then
		return nil
	end

	Validation.ensureValueIsStringOrNil(options.Name, `{usagePrefix}: Name must be a string or nil`)

	return options.Name
end

function Runtime.ValidateGroupOptions(options: GroupOptions?, usagePrefix: string): string?
	Validation.ensureValueIsTableOrNil(options, `{usagePrefix}: opts must be a table or nil`)

	if options == nil then
		return nil
	end

	Validation.ensureValueIsStringOrNil(options.Name, `{usagePrefix}: Name must be a string or nil`)

	return options.Name
end

function taskHandleMethods:Token(): Token
	return Runtime.GetTaskRecord(self :: any, "Task.Token: invalid task handle").Token
end

function taskHandleMethods:Cancel(reason: string?): ()
	Runtime.CancelTask(self :: any, reason)
end

function taskHandleMethods:Status(): Status
	return Runtime.GetTaskRecord(self :: any, "Task.Status: invalid task handle").Status
end

function taskHandleMethods:IsPending(): boolean
	return Runtime.GetTaskRecord(self :: any, "Task.IsPending: invalid task handle").Status == Runtime.Status.Pending
end

function taskHandleMethods:IsFulfilled(): boolean
	return Runtime.GetTaskRecord(self :: any, "Task.IsFulfilled: invalid task handle").Status == Runtime.Status.Fulfilled
end

function taskHandleMethods:IsCancelled(): boolean
	return Runtime.GetTaskRecord(self :: any, "Task.IsCancelled: invalid task handle").Status == Runtime.Status.Cancelled
end

function taskHandleMethods:IsErrored(): boolean
	return Runtime.GetTaskRecord(self :: any, "Task.IsErrored: invalid task handle").Status == Runtime.Status.Errored
end

function taskHandleMethods:IsDone(): boolean
	return Runtime.GetTaskRecord(self :: any, "Task.IsDone: invalid task handle").Status ~= Runtime.Status.Pending
end

function taskHandleMethods:Finally(callback: (status: Status, value: unknown?) -> ()): any
	Validation.ensureValueIsFunction(callback, "Task.Finally: fn must be a function")

	local taskRecord = Runtime.GetTaskRecord(self :: any, "Task.Finally: invalid task handle")

	if taskRecord.Status == Runtime.Status.Pending then
		table.insert(taskRecord.FinallyCallbacks, callback)
	else
		local status = taskRecord.Status
		local settledValue = if status == Runtime.Status.Fulfilled then taskRecord.Value elseif status == Runtime.Status.Errored then taskRecord.Error else taskRecord.Reason

		Scheduler.Defer(function()
			ErrorHandler.Protect(function()
				callback(status :: any, settledValue)
			end, "Task", "Finally", taskRecord.Name)
		end)
	end

	return self
end

function taskHandleMethods:Await(token: Token?): (boolean, any)
	local taskRecord = Runtime.GetTaskRecord(self :: any, "Task.Await: invalid task handle")

	if token ~= nil and not Runtime.ValueIsLiveToken(token) then
		Validation.raiseUsageError("Task.Await: invalid token")
	end

	if taskRecord.Status ~= Runtime.Status.Pending then
		return Runtime.ReadSettledTaskResult(taskRecord)
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
		local awaitTokenRecord = Runtime.GetTokenRecord(token, "Task.Await: invalid token")

		if awaitTokenRecord.Cancelled then
			return false, awaitTokenRecord.Reason
		end

		cancellationConnection = token:OnCancel(function(reason)
			resumeAwait(false, reason)
		end)
	end

	self:Finally(function(status, value)
		if status == Runtime.Status.Fulfilled then
			resumeAwait(true, value)
		else
			resumeAwait(false, value)
		end
	end)

	return coroutine.yield()
end

function Runtime.ReadSettledTaskResult(taskRecord: TaskRecord): (boolean, any)
	if taskRecord.Status == Runtime.Status.Fulfilled then
		return true, taskRecord.Value
	end

	if taskRecord.Status == Runtime.Status.Errored then
		return false, taskRecord.Error
	end

	return false, taskRecord.Reason
end

function taskHandleMethods:Unwrap(token: Token?): any
	local success, value = self:Await(token)

	if success then
		return value
	end

	error(value, 2)
end

function taskHandleMethods:Result(): (boolean, any)
	local taskRecord = Runtime.GetTaskRecord(self :: any, "Task.Result: invalid task handle")

	if taskRecord.Status == Runtime.Status.Fulfilled then
		return true, taskRecord.Value
	end

	return false, nil
end

function taskHandleMethods:Error(): (boolean, any)
	local taskRecord = Runtime.GetTaskRecord(self :: any, "Task.Error: invalid task handle")

	if taskRecord.Status == Runtime.Status.Errored then
		return true, taskRecord.Error
	end

	return false, nil
end

function taskHandleMethods:Name(): string?
	return Runtime.GetTaskRecord(self :: any, "Task.Name: invalid task handle").Name
end

function tokenHandleMethods:Cancelled(): boolean
	return Runtime.GetTokenRecord(self :: any, "Token.Cancelled: invalid token handle").Cancelled
end

function tokenHandleMethods:Reason(): string?
	return Runtime.GetTokenRecord(self :: any, "Token.Reason: invalid token handle").Reason
end

function tokenHandleMethods:OnCancel(callback: (reason: string?) -> ()): Connection.Connection
	Validation.ensureValueIsFunction(callback, "Token.OnCancel: fn must be a function")

	local tokenRecord = Runtime.GetTokenRecord(self :: any, "Token.OnCancel: invalid token handle")

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

function groupHandleMethods:Add(task: Task<any>): any
	local groupRecord = Runtime.GetGroupRecord(self :: any, "Group.Add: invalid group handle")

	if groupRecord.Destroyed then
		Validation.raiseUsageError("Group.Add: group is destroyed")
	end

	if not Runtime.ValueIsLiveTask(task) then
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
	local groupRecord = Runtime.GetGroupRecord(self :: any, "Group.CancelAll: invalid group handle")
	local cancellationReason = reason or Runtime.Reason.ModeExit

	for task in groupRecord.PendingTasks do
		task:Cancel(cancellationReason)
	end
end

function groupHandleMethods:Destroy(reason: string?): ()
	local groupRecord = Runtime.GetGroupRecord(self :: any, "Group.Destroy: invalid group handle")

	if groupRecord.Destroyed then
		return
	end

	groupRecord.Destroyed = true
	(self :: any):CancelAll(reason or Runtime.Reason.ModeExit)
	table.clear(groupRecord.PendingTasks)
end

function groupHandleMethods:Size(): number
	local groupRecord = Runtime.GetGroupRecord(self :: any, "Group.Size: invalid group handle")
	local size = 0

	for _ in groupRecord.PendingTasks do
		size += 1
	end

	return size
end

function groupHandleMethods:Name(): string?
	return Runtime.GetGroupRecord(self :: any, "Group.Name: invalid group handle").Name
end

return table.freeze(Runtime)

