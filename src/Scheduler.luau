--!strict

local Connection = require(script.Parent.Connection)
local ErrorHandler = require(script.Parent.ErrorHandler)

local Scheduler = {}

export type Driver = {
	Defer: ((() -> ()) -> any)?,
	Delay: ((number, () -> ()) -> any)?,
	Cancel: ((any) -> ())?,
	Now: (() -> number)?,
	OnStep: (((number) -> ()) -> Connection.Connection)?,
}

type ActiveDriver = {
	Defer: ((() -> ()) -> any),
	Delay: ((number, () -> ()) -> any),
	Cancel: ((any) -> ()),
	Now: (() -> number),
	OnStep: (((number) -> ()) -> Connection.Connection)?,
}

-- Roblox primitives captured once at module load so they cannot be swapped out
-- by later global mutations.
local _taskDefer = task.defer
local _taskDelay = task.delay
local _taskCancel = task.cancel
local _time = time

local _defaultOnStep: (((number) -> ()) -> Connection.Connection)? = nil
do
	local ok, rs = pcall(function(): any
		return game:GetService("RunService")
	end)
	if ok and rs ~= nil then
		_defaultOnStep = function(fn: (number) -> ()): Connection.Connection
			local rbxConn = (rs :: any).Heartbeat:Connect(fn)
			return Connection.New(function()
				rbxConn:Disconnect()
			end)
		end
	end
end

local defaultDriver: ActiveDriver = {
	Defer = function(fn: () -> ()): any
		return _taskDefer(fn)
	end,
	Delay = function(seconds: number, fn: () -> ()): any
		return _taskDelay(seconds, fn)
	end,
	Cancel = function(handle: any): ()
		if handle ~= nil then
			_taskCancel(handle)
		end
	end,
	Now = function(): number
		return _time()
	end,
	OnStep = _defaultOnStep,
}

local activeDriver: ActiveDriver = defaultDriver

-- Route a callback error through ErrorHandler without wrapping the Report call
-- itself, so Report errors (Throw policy) propagate naturally from the callback.
local function reportCallbackError(phase: string, err: unknown): ()
	ErrorHandler.Report({
		Module = "Scheduler",
		Phase = phase,
		Error = err,
	})
end

function Scheduler.Defer(fn: () -> ()): any?
	if type(fn) ~= "function" then
		error("Scheduler.Defer: fn must be a function")
	end
	local wrapped: () -> () = function()
		local ok, err = pcall(fn)
		if not ok then
			reportCallbackError("Defer", err)
		end
	end
	return activeDriver.Defer(wrapped)
end

function Scheduler.Delay(seconds: number, fn: () -> ()): any?
	if type(seconds) ~= "number" or not (seconds >= 0) then
		error("Scheduler.Delay: seconds must be non-negative")
	end
	if type(fn) ~= "function" then
		error("Scheduler.Delay: fn must be a function")
	end
	local wrapped: () -> () = function()
		local ok, err = pcall(fn)
		if not ok then
			reportCallbackError("Delay", err)
		end
	end
	return activeDriver.Delay(seconds, wrapped)
end

function Scheduler.Cancel(handle: any?): ()
	if handle == nil then
		return
	end
	local ok, err = pcall(activeDriver.Cancel, handle)
	if not ok then
		reportCallbackError("Cancel", err)
	end
end

function Scheduler.Now(): number
	local ok, result = pcall(activeDriver.Now)
	if not ok then
		-- Route error; if policy is Throw, Report throws and propagates from Now().
		reportCallbackError("Now", result)
		-- Reached only under non-Throw policy; return a safe fallback.
		return 0
	end
	if type(result) ~= "number" then
		error("Scheduler.Now: driver returned non-number")
	end
	return result :: number
end

function Scheduler.OnStep(fn: (dt: number) -> ()): Connection.Connection
	if type(fn) ~= "function" then
		error("Scheduler.OnStep: fn must be a function")
	end
	local onStepFn = activeDriver.OnStep
	if onStepFn == nil then
		error("Scheduler.OnStep: no step driver available")
	end
	local wrapped: (number) -> () = function(dt: number)
		local ok, err = pcall(fn, dt)
		if not ok then
			reportCallbackError("OnStep", err)
		end
	end
	local conn = onStepFn(wrapped)
	if not Connection.IsConnection(conn) then
		error("Scheduler.OnStep: driver must return Connection")
	end
	return conn
end

function Scheduler.SetDriver(driver: Driver): ()
	local raw = driver :: { [string]: unknown }
	if type(raw) ~= "table" then
		error("Scheduler.SetDriver: driver must be a table")
	end
	local fields = { "Defer", "Delay", "Cancel", "Now", "OnStep" }
	for _, field in fields do
		local value = raw[field]
		if value ~= nil and type(value) ~= "function" then
			error(`Scheduler.SetDriver: {field} must be a function or nil`)
		end
	end
	-- Build new active driver, keeping defaults for any omitted fields.
	activeDriver = {
		Defer = if driver.Defer ~= nil then driver.Defer else defaultDriver.Defer,
		Delay = if driver.Delay ~= nil then driver.Delay else defaultDriver.Delay,
		Cancel = if driver.Cancel ~= nil then driver.Cancel else defaultDriver.Cancel,
		Now = if driver.Now ~= nil then driver.Now else defaultDriver.Now,
		OnStep = if driver.OnStep ~= nil then driver.OnStep else defaultDriver.OnStep,
	}
end

function Scheduler.ResetDriver(): ()
	activeDriver = defaultDriver
end

return Scheduler

