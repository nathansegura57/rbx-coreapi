--!strict

local Scheduler = require(script.Parent.Parent.Scheduler)
local Runtime = require(script.Parent._Records)
local Validation = require(script.Parent._Validation)

local Constructors = {}

function Constructors.Start<T>(taskBody: (Runtime.Token) -> T, options: Runtime.TaskOptions?): Runtime.Task<T>
	Validation.ensureValueIsFunction(taskBody, "Task.Start: fn must be a function")

	local taskName = Runtime.ValidateTaskOptions(options, "Task.Start")
	local task, taskRecord = Runtime.CreatePendingTaskRecord(taskName)

	Scheduler.Defer(function()
		if taskRecord.Status ~= Runtime.Status.Pending then
			return
		end

		local bodySucceeded, bodyResult = pcall(function()
			return taskBody(taskRecord.Token)
		end)

		if taskRecord.Status ~= Runtime.Status.Pending then
			return
		end

		if bodySucceeded then
			Runtime.SettlePendingTask(taskRecord, Runtime.Status.Fulfilled, bodyResult)
		else
			Runtime.SettlePendingTask(taskRecord, Runtime.Status.Errored, bodyResult)
		end
	end)

	return task :: Runtime.Task<T>
end

function Constructors.Delay(seconds: number, delayedCallback: (() -> any)?): Runtime.Task<any>
	Validation.ensureValueIsNonNegativeNumber(seconds, "Task.Delay: seconds must be non-negative")

	if delayedCallback ~= nil then
		Validation.ensureValueIsFunction(delayedCallback, "Task.Delay: fn must be a function or nil")
	end

	local task, taskRecord = Runtime.CreatePendingTaskRecord(nil)
	local delayHandle = Scheduler.Delay(seconds, function()
		if taskRecord.Status ~= Runtime.Status.Pending then
			return
		end

		if delayedCallback == nil then
			Runtime.SettlePendingTask(taskRecord, Runtime.Status.Fulfilled, nil)
			return
		end

		local callbackSucceeded, callbackResult = pcall(delayedCallback)

		if callbackSucceeded then
			Runtime.SettlePendingTask(taskRecord, Runtime.Status.Fulfilled, callbackResult)
		else
			Runtime.SettlePendingTask(taskRecord, Runtime.Status.Errored, callbackResult)
		end
	end)

	task:Finally(function()
		Scheduler.Cancel(delayHandle)
	end)

	return task
end

function Constructors.Sleep(seconds: number, token: Runtime.Token?): (boolean, string?)
	Validation.ensureValueIsNonNegativeNumber(seconds, "Task.Sleep: seconds must be non-negative")

	if token ~= nil and not Runtime.ValueIsLiveToken(token) then
		Validation.raiseUsageError("Task.Sleep: invalid token")
	end

	if not coroutine.isyieldable() then
		Validation.raiseUsageError("Task.Sleep: must be called from a yieldable coroutine")
	end

	if token ~= nil and token:Cancelled() then
		return false, token:Reason()
	end

	local runningCoroutine = coroutine.running()
	local completed = false
	local cancellationConnection = nil :: any

	local function resumeSleep(success: boolean, reason: string?): ()
		if completed then
			return
		end

		completed = true

		if cancellationConnection ~= nil then
			cancellationConnection:Disconnect()
		end

		coroutine.resume(runningCoroutine, success, reason)
	end

	local delayHandle = Scheduler.Delay(seconds, function()
		resumeSleep(true, nil)
	end)

	if token ~= nil then
		cancellationConnection = token:OnCancel(function(reason)
			Scheduler.Cancel(delayHandle)
			resumeSleep(false, reason)
		end)
	end

	return coroutine.yield()
end

function Constructors.Resolved<T>(value: T): Runtime.Task<T>
	local task, taskRecord = Runtime.CreatePendingTaskRecord(nil)
	Runtime.SettlePendingTask(taskRecord, Runtime.Status.Fulfilled, value)
	return task :: Runtime.Task<T>
end

function Constructors.Rejected(errorValue: unknown): Runtime.Task<never>
	local task, taskRecord = Runtime.CreatePendingTaskRecord(nil)
	Runtime.SettlePendingTask(taskRecord, Runtime.Status.Errored, errorValue)
	return task :: Runtime.Task<never>
end

function Constructors.Cancelled(reason: string?): Runtime.Task<never>
	local task, taskRecord = Runtime.CreatePendingTaskRecord(nil)
	Runtime.SettlePendingTask(taskRecord, Runtime.Status.Cancelled, reason or Runtime.Reason.User)
	return task :: Runtime.Task<never>
end

return table.freeze(Constructors)

