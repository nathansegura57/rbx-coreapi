--!strict

local Connection = require(script.Parent.Connection)
local ErrorHandler = require(script.Parent.ErrorHandler)


export type ScheduledCallback = () -> ()
export type StepCallback = (deltaTimeSeconds: number) -> ()
export type ScheduledHandle = unknown

export type Driver = {
	Defer: ((callback: ScheduledCallback) -> ScheduledHandle?)?,
	Delay: ((delaySeconds: number, callback: ScheduledCallback) -> ScheduledHandle?)?,
	Cancel: ((scheduledHandle: ScheduledHandle?) -> ())?,
	Now: (() -> number)?,
	OnStep: ((callback: StepCallback) -> Connection.Connection)?,
}

export type SchedulerModule = {
	Defer: (callback: ScheduledCallback) -> ScheduledHandle?,
	Delay: (delaySeconds: number, callback: ScheduledCallback) -> ScheduledHandle?,
	Cancel: (scheduledHandle: ScheduledHandle?) -> (),
	Now: () -> number,
	OnStep: (callback: StepCallback) -> Connection.Connection,

	SetDriver: (driver: Driver) -> (),
	ResetDriver: () -> (),
}

local Scheduler = {} :: SchedulerModule


type ActiveDriver = {
	Defer: (callback: ScheduledCallback) -> ScheduledHandle?,
	Delay: (delaySeconds: number, callback: ScheduledCallback) -> ScheduledHandle?,
	Cancel: (scheduledHandle: ScheduledHandle?) -> (),
	Now: () -> number,
	OnStep: ((callback: StepCallback) -> Connection.Connection)?,
}

type UntrustedDriverTable = {
	[string]: unknown,
}


local capturedTaskDefer = task.defer
local capturedTaskDelay = task.delay
local capturedTaskCancel = task.cancel
local capturedTime = time


local defaultDriver: ActiveDriver
local activeDriver: ActiveDriver


function Scheduler.Defer(callback: ScheduledCallback): ScheduledHandle?
	local validatedCallback = getValidatedScheduledCallback(callback, "Scheduler.Defer: callback must be a function")
	local protectedCallback = createScheduledCallbackProtectedByErrorHandler(validatedCallback, "Defer")

	return callActiveDeferDriver(protectedCallback)
end

function Scheduler.Delay(delaySeconds: number, callback: ScheduledCallback): ScheduledHandle?
	local validatedDelaySeconds = getValidatedDelaySeconds(delaySeconds)
	local validatedCallback = getValidatedScheduledCallback(callback, "Scheduler.Delay: callback must be a function")
	local protectedCallback = createScheduledCallbackProtectedByErrorHandler(validatedCallback, "Delay")

	return callActiveDelayDriver(validatedDelaySeconds, protectedCallback)
end

function Scheduler.Cancel(scheduledHandle: ScheduledHandle?): ()
	if scheduledHandle == nil then
		return
	end

	callActiveCancelDriver(scheduledHandle)
end

function Scheduler.Now(): number
	return callActiveNowDriverOrReturnFallbackTime()
end

function Scheduler.OnStep(callback: StepCallback): Connection.Connection
	local validatedCallback = getValidatedStepCallback(callback)
	local protectedCallback = createStepCallbackProtectedByErrorHandler(validatedCallback)

	return callActiveStepDriver(protectedCallback)
end

function Scheduler.SetDriver(driver: Driver): ()
	local validatedDriver = getValidatedDriverTable(driver)

	activeDriver = createActiveDriverFromPartialDriver(validatedDriver)
end

function Scheduler.ResetDriver(): ()
	activeDriver = defaultDriver
end


function createDefaultDriver(): ActiveDriver
	return {
		Defer = function(callback: ScheduledCallback): ScheduledHandle?
			return capturedTaskDefer(callback)
		end,

		Delay = function(delaySeconds: number, callback: ScheduledCallback): ScheduledHandle?
			return capturedTaskDelay(delaySeconds, callback)
		end,

		Cancel = function(scheduledHandle: ScheduledHandle?): ()
			if scheduledHandle ~= nil then
				capturedTaskCancel(scheduledHandle :: thread)
			end
		end,

		Now = function(): number
			return capturedTime()
		end,

		OnStep = createDefaultStepDriverIfRunServiceIsAvailable(),
	}
end

function createDefaultStepDriverIfRunServiceIsAvailable(): ((callback: StepCallback) -> Connection.Connection)?
	local runServiceWasAvailable, runService = pcall(function(): any
		return game:GetService("RunService")
	end)

	if not runServiceWasAvailable then
		return nil
	end

	if runService == nil then
		return nil
	end

	return function(callback: StepCallback): Connection.Connection
		return connectStepCallbackToRunServiceHeartbeat(runService, callback)
	end
end

function connectStepCallbackToRunServiceHeartbeat(runService: any, callback: StepCallback): Connection.Connection
	local heartbeatConnection = runService.Heartbeat:Connect(callback)

	return Connection.New(function()
		heartbeatConnection:Disconnect()
	end)
end


function createScheduledCallbackProtectedByErrorHandler(
	callback: ScheduledCallback,
	phaseName: string
): ScheduledCallback
	return function()
		ErrorHandler.Protect(callback, "Scheduler", phaseName)
	end
end

function createStepCallbackProtectedByErrorHandler(callback: StepCallback): StepCallback
	return function(deltaTimeSeconds: number)
		ErrorHandler.Protect(function()
			callback(deltaTimeSeconds)
		end, "Scheduler", "OnStep")
	end
end


function callActiveDeferDriver(callback: ScheduledCallback): ScheduledHandle?
	local driverSucceeded, scheduledHandle = ErrorHandler.Protect(function()
		return activeDriver.Defer(callback)
	end, "Scheduler", "DeferDriver")

	if not driverSucceeded then
		return nil
	end

	return scheduledHandle
end

function callActiveDelayDriver(delaySeconds: number, callback: ScheduledCallback): ScheduledHandle?
	local driverSucceeded, scheduledHandle = ErrorHandler.Protect(function()
		return activeDriver.Delay(delaySeconds, callback)
	end, "Scheduler", "DelayDriver")

	if not driverSucceeded then
		return nil
	end

	return scheduledHandle
end

function callActiveCancelDriver(scheduledHandle: ScheduledHandle?): ()
	ErrorHandler.Protect(function()
		activeDriver.Cancel(scheduledHandle)
	end, "Scheduler", "CancelDriver")
end

function callActiveNowDriverOrReturnFallbackTime(): number
	local driverSucceeded, currentTimeSeconds = ErrorHandler.Protect(activeDriver.Now, "Scheduler", "NowDriver")

	if not driverSucceeded then
		return 0
	end

	if typeof(currentTimeSeconds) == "number" then
		return currentTimeSeconds
	end

	return raiseSchedulerUsageError("Scheduler.Now: driver returned non-number")
end

function callActiveStepDriver(callback: StepCallback): Connection.Connection
	local stepDriver = activeDriver.OnStep

	if stepDriver == nil then
		return raiseSchedulerUsageError("Scheduler.OnStep: no step driver available")
	end

	local driverSucceeded, connection = ErrorHandler.Protect(function()
		return stepDriver(callback)
	end, "Scheduler", "OnStepDriver")

	if not driverSucceeded then
		raiseSchedulerUsageError("Scheduler.OnStep: step driver failed before returning a Connection")
	end

	if Connection.IsConnection(connection) then
		return connection :: Connection.Connection
	end

	return raiseSchedulerUsageError("Scheduler.OnStep: driver must return Connection")
end


function createActiveDriverFromPartialDriver(driver: Driver): ActiveDriver
	return {
		Defer = if driver.Defer ~= nil then driver.Defer else defaultDriver.Defer,
		Delay = if driver.Delay ~= nil then driver.Delay else defaultDriver.Delay,
		Cancel = if driver.Cancel ~= nil then driver.Cancel else defaultDriver.Cancel,
		Now = if driver.Now ~= nil then driver.Now else defaultDriver.Now,
		OnStep = if driver.OnStep ~= nil then driver.OnStep else defaultDriver.OnStep,
	}
end

function getValidatedDriverTable(untrustedDriver: unknown): Driver
	if typeof(untrustedDriver) ~= "table" then
		raiseSchedulerUsageError("Scheduler.SetDriver: driver must be a table")
	end

	local driverTable = untrustedDriver :: UntrustedDriverTable

	assertDriverFieldIsFunctionOrNil(driverTable, "Defer")
	assertDriverFieldIsFunctionOrNil(driverTable, "Delay")
	assertDriverFieldIsFunctionOrNil(driverTable, "Cancel")
	assertDriverFieldIsFunctionOrNil(driverTable, "Now")
	assertDriverFieldIsFunctionOrNil(driverTable, "OnStep")

	return untrustedDriver :: Driver
end

function assertDriverFieldIsFunctionOrNil(driverTable: UntrustedDriverTable, fieldName: string): ()
	local untrustedFieldValue = driverTable[fieldName]

	if untrustedFieldValue == nil then
		return
	end

	if typeof(untrustedFieldValue) == "function" then
		return
	end

	raiseSchedulerUsageError(`Scheduler.SetDriver: {fieldName} must be a function or nil`)
end


function getValidatedScheduledCallback(
	untrustedCallback: unknown,
	usageErrorMessage: string
): ScheduledCallback
	if typeof(untrustedCallback) == "function" then
		return untrustedCallback :: ScheduledCallback
	end

	return raiseSchedulerUsageError(usageErrorMessage)
end

function getValidatedStepCallback(untrustedCallback: unknown): StepCallback
	if typeof(untrustedCallback) == "function" then
		return untrustedCallback :: StepCallback
	end

	return raiseSchedulerUsageError("Scheduler.OnStep: callback must be a function")
end

function getValidatedDelaySeconds(untrustedDelaySeconds: unknown): number
	if typeof(untrustedDelaySeconds) == "number" and untrustedDelaySeconds >= 0 then
		return untrustedDelaySeconds
	end

	return raiseSchedulerUsageError("Scheduler.Delay: delaySeconds must be a non-negative number")
end

function raiseSchedulerUsageError(message: string): never
	return ErrorHandler.RaiseUsageError(message)
end


defaultDriver = createDefaultDriver()
activeDriver = defaultDriver


return table.freeze(Scheduler)

