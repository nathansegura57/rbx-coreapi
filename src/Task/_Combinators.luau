--!strict

local Scheduler = require(script.Parent.Parent.Scheduler)
local Runtime = require(script.Parent._Records)
local Constructors = require(script.Parent._Constructors)
local Validation = require(script.Parent._Validation)

export type SettledResult = {
	Status: Runtime.Status,
	Value: unknown?,
	Error: unknown?,
	Reason: string?,
}

export type RetryOptions = {
	Count: number,
	Backoff: Runtime.Backoff,
	Base: number,
	Jitter: number?,
}

local Combinators = {}

function Combinators.All<T>(tasks: { Runtime.Task<T> }): Runtime.Task<{ T }>
	local taskArray = Validation.ensureArrayIsNonEmptyDense(tasks, "Task.All: tasks must be a non-empty dense array")

	for index, task in taskArray do
		if not Runtime.ValueIsLiveTask(task) then
			Validation.raiseUsageError(`Task.All: task at index {index} is not a valid Task`)
		end
	end

	local combinedTask, combinedRecord = Runtime.CreatePendingTaskRecord(nil)
	local remaining = #taskArray
	local values = table.create(#taskArray)

	for index, task in taskArray do
		task:Finally(function(status, value)
			if combinedRecord.Status ~= Runtime.Status.Pending then
				return
			end

			if status == Runtime.Status.Fulfilled then
				values[index] = value
				remaining -= 1

				if remaining == 0 then
					Runtime.SettlePendingTask(combinedRecord, Runtime.Status.Fulfilled, values)
				end
				return
			end

			for _, siblingTask in taskArray do
				if siblingTask ~= task then
					siblingTask:Cancel(Runtime.Reason.Superseded)
				end
			end

			if status == Runtime.Status.Cancelled then
				Runtime.SettlePendingTask(combinedRecord, Runtime.Status.Cancelled, value)
			else
				Runtime.SettlePendingTask(combinedRecord, Runtime.Status.Errored, value)
			end
		end)
	end

	return combinedTask :: Runtime.Task<{ T }>
end

function Combinators.Race<T>(tasks: { Runtime.Task<T> }): Runtime.Task<T>
	local taskArray = Validation.ensureArrayIsNonEmptyDense(tasks, "Task.Race: tasks must be a non-empty dense array")

	for index, task in taskArray do
		if not Runtime.ValueIsLiveTask(task) then
			Validation.raiseUsageError(`Task.Race: task at index {index} is not a valid Task`)
		end
	end

	local racedTask, racedRecord = Runtime.CreatePendingTaskRecord(nil)

	for _, task in taskArray do
		task:Finally(function(status, value)
			if status == Runtime.Status.Fulfilled then
				Runtime.SettlePendingTask(racedRecord, Runtime.Status.Fulfilled, value)
			elseif status == Runtime.Status.Cancelled then
				Runtime.SettlePendingTask(racedRecord, Runtime.Status.Cancelled, value)
			else
				Runtime.SettlePendingTask(racedRecord, Runtime.Status.Errored, value)
			end
		end)
	end

	return racedTask :: Runtime.Task<T>
end

function Combinators.Any<T>(tasks: { Runtime.Task<T> }): Runtime.Task<T>
	local taskArray = Validation.ensureArrayIsNonEmptyDense(tasks, "Task.Any: tasks must be a non-empty dense array")

	for index, task in taskArray do
		if not Runtime.ValueIsLiveTask(task) then
			Validation.raiseUsageError(`Task.Any: task at index {index} is not a valid Task`)
		end
	end

	local anyTask, anyRecord = Runtime.CreatePendingTaskRecord(nil)
	local remaining = #taskArray
	local failures = {}

	for index, task in taskArray do
		task:Finally(function(status, value)
			if anyRecord.Status ~= Runtime.Status.Pending then
				return
			end

			if status == Runtime.Status.Fulfilled then
				Runtime.SettlePendingTask(anyRecord, Runtime.Status.Fulfilled, value)
				return
			end

			failures[index] = { Status = status, Error = if status == Runtime.Status.Errored then value else nil, Reason = if status == Runtime.Status.Cancelled then value else nil }
			remaining -= 1

			if remaining == 0 then
				Runtime.SettlePendingTask(anyRecord, Runtime.Status.Errored, { Failures = failures })
			end
		end)
	end

	return anyTask :: Runtime.Task<T>
end

function Combinators.AllSettled(tasks: { Runtime.Task<any> }): Runtime.Task<{ SettledResult }>
	local taskArray = Validation.ensureArrayIsNonEmptyDense(tasks, "Task.AllSettled: tasks must be a non-empty dense array")

	for index, task in taskArray do
		if not Runtime.ValueIsLiveTask(task) then
			Validation.raiseUsageError(`Task.AllSettled: task at index {index} is not a valid Task`)
		end
	end

	local resultTask, resultRecord = Runtime.CreatePendingTaskRecord(nil)
	local remaining = #taskArray
	local results = table.create(#taskArray)

	for index, task in taskArray do
		task:Finally(function(status, value)
			results[index] = {
				Status = status,
				Value = if status == Runtime.Status.Fulfilled then value else nil,
				Error = if status == Runtime.Status.Errored then value else nil,
				Reason = if status == Runtime.Status.Cancelled then value else nil,
			}

			remaining -= 1

			if remaining == 0 then
				Runtime.SettlePendingTask(resultRecord, Runtime.Status.Fulfilled, results)
			end
		end)
	end

	return resultTask :: Runtime.Task<{ SettledResult }>
end

function Combinators.Timeout<T>(inner: Runtime.Task<T> | (() -> Runtime.Task<T>), seconds: number, reason: string?): Runtime.Task<T>
	Validation.ensureValueIsPositiveNumber(seconds, "Task.Timeout: seconds must be positive")

	local innerTask: Runtime.Task<T>

	if typeof(inner) == "function" then
		local thunkSucceeded, thunkResult = pcall(inner)

		if not thunkSucceeded then
			return Constructors.Rejected(`Task.Timeout: thunk errored: {tostring(thunkResult)}`) :: Runtime.Task<T>
		end

		if not Runtime.ValueIsLiveTask(thunkResult) then
			Validation.raiseUsageError("Task.Timeout: thunk must return a Task")
		end

		innerTask = thunkResult :: Runtime.Task<T>
	elseif Runtime.ValueIsLiveTask(inner) then
		innerTask = inner :: Runtime.Task<T>
	else
		Validation.raiseUsageError("Task.Timeout: inner must be a Task or function returning a Task")
	end

	local timeoutTask, timeoutRecord = Runtime.CreatePendingTaskRecord(nil)
	local timeoutReason = reason or Runtime.Reason.Timeout

	local timeoutHandle = Scheduler.Delay(seconds, function()
		innerTask:Cancel(timeoutReason)
		Runtime.SettlePendingTask(timeoutRecord, Runtime.Status.Cancelled, timeoutReason)
	end)

	innerTask:Finally(function(status, value)
		Scheduler.Cancel(timeoutHandle)

		if status == Runtime.Status.Fulfilled then
			Runtime.SettlePendingTask(timeoutRecord, Runtime.Status.Fulfilled, value)
		elseif status == Runtime.Status.Cancelled then
			Runtime.SettlePendingTask(timeoutRecord, Runtime.Status.Cancelled, value)
		else
			Runtime.SettlePendingTask(timeoutRecord, Runtime.Status.Errored, value)
		end
	end)

	return timeoutTask :: Runtime.Task<T>
end

function Combinators.Retry<T>(makeTask: (Runtime.Token) -> Runtime.Task<T>, options: RetryOptions): Runtime.Task<T>
	Validation.ensureValueIsFunction(makeTask, "Task.Retry: makeTask must be a function")
	Validation.ensureValueIsTableOrNil(options, "Task.Retry: opts must be a table")

	if options == nil then
		Validation.raiseUsageError("Task.Retry: opts must be a table")
	end

	Validation.ensureValueIsPositiveInteger(options.Count, "Task.Retry: Count must be a positive integer")
	Validation.ensureValueIsNonNegativeNumber(options.Base, "Task.Retry: Base must be >= 0")
	Validation.ensureValueIsNonNegativeNumberOrNil(options.Jitter, "Task.Retry: Jitter must be >= 0 or nil")

	if options.Backoff ~= Runtime.Backoff.Fixed and options.Backoff ~= Runtime.Backoff.Expo then
		Validation.raiseUsageError("Task.Retry: Backoff must be 'Fixed' or 'Expo'")
	end

	return Constructors.Start(function(token)
		local lastFailure: unknown = nil

		for attemptIndex = 1, options.Count do
			if token:Cancelled() then
				return nil :: any
			end

			local childTask = makeTask(token)

			if not Runtime.ValueIsLiveTask(childTask) then
				error("Task.Retry: makeTask must return a Task")
			end

			local attemptSucceeded, attemptValue = childTask:Await(token)

			if attemptSucceeded then
				return attemptValue :: T
			end

			lastFailure = attemptValue

			if attemptIndex < options.Count then
				local multiplier = if options.Backoff == Runtime.Backoff.Expo then 2 ^ (attemptIndex - 1) else 1
				local delaySeconds = options.Base * multiplier
				local jitter = options.Jitter or 0

				if jitter > 0 and delaySeconds > 0 then
					delaySeconds *= 1 + ((math.random() * 2 - 1) * jitter)
					delaySeconds = math.max(0, delaySeconds)
				end

				Constructors.Sleep(delaySeconds, token)
			end
		end

		error(lastFailure)
	end)
end

function Combinators.FromRoblox(robloxSignal: RBXScriptSignal, untilSignal: RBXScriptSignal?): Runtime.Task<{ any }>
	if typeof(robloxSignal) ~= "RBXScriptSignal" then
		Validation.raiseUsageError("Task.FromRoblox: rbxSignal must be an RBXScriptSignal")
	end

	if untilSignal ~= nil and typeof(untilSignal) ~= "RBXScriptSignal" then
		Validation.raiseUsageError("Task.FromRoblox: untilSignal must be an RBXScriptSignal")
	end

	local task, taskRecord = Runtime.CreatePendingTaskRecord(nil)
	local mainConnection: RBXScriptConnection? = nil
	local untilConnection: RBXScriptConnection? = nil

	local function disconnectRobloxConnections(): ()
		if mainConnection ~= nil then mainConnection:Disconnect() end
		if untilConnection ~= nil then untilConnection:Disconnect() end
	end

	mainConnection = robloxSignal:Connect(function(...)
		disconnectRobloxConnections()
		Runtime.SettlePendingTask(taskRecord, Runtime.Status.Fulfilled, table.pack(...))
	end)

	if untilSignal ~= nil then
		untilConnection = untilSignal:Connect(function()
			disconnectRobloxConnections()
			Runtime.SettlePendingTask(taskRecord, Runtime.Status.Fulfilled, nil)
		end)
	end

	task:Finally(disconnectRobloxConnections)

	return task :: Runtime.Task<{ any }>
end

return table.freeze(Combinators)

