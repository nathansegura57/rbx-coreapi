--!strict

local Combinators = require(script._Combinators)
local Constructors = require(script._Constructors)
local Records = require(script._Records)
local Types = require(script._Types)

export type Status = Types.Status
export type CancellationReason = Types.CancellationReason
export type Backoff = Types.Backoff
export type Token = Types.Token
export type Task<T> = Types.Task<T>
export type TaskGroup = Types.TaskGroup
export type TaskOptions = Types.TaskOptions
export type GroupOptions = Types.GroupOptions
export type RetryOptions = Combinators.RetryOptions
export type SettledResult = Combinators.SettledResult
export type TraceEvent = Types.TraceEvent

export type TaskModule = {
	Status: Types.StatusSet,
	Reason: Types.ReasonSet,
	Backoff: Types.BackoffSet,

	Start: <T>(taskBody: (Types.Token) -> T, options: Types.TaskOptions?) -> Types.Task<T>,
	Delay: (seconds: number, delayedCallback: (() -> any)?) -> Types.Task<any>,
	Sleep: (seconds: number, token: Types.Token?) -> (boolean, string?),
	Resolved: <T>(value: T) -> Types.Task<T>,
	Rejected: (errorValue: unknown) -> Types.Task<never>,
	Cancelled: (reason: string?) -> Types.Task<never>,

	All: <T>(tasks: { Types.Task<T> }) -> Types.Task<{ T }>,
	Race: <T>(tasks: { Types.Task<T> }) -> Types.Task<T>,
	Any: <T>(tasks: { Types.Task<T> }) -> Types.Task<T>,
	AllSettled: (tasks: { Types.Task<any> }) -> Types.Task<{ Combinators.SettledResult }>,
	Timeout: <T>(inner: Types.Task<T> | (() -> Types.Task<T>), seconds: number, reason: string?) -> Types.Task<T>,
	Retry: <T>(makeTask: (Types.Token) -> Types.Task<T>, options: Combinators.RetryOptions) -> Types.Task<T>,
	FromRoblox: (robloxSignal: RBXScriptSignal, untilSignal: RBXScriptSignal?) -> Types.Task<{ any }>,

	Group: (options: Types.GroupOptions?) -> Types.TaskGroup,

	IsTask: (value: unknown) -> boolean,
	IsToken: (value: unknown) -> boolean,
	IsGroup: (value: unknown) -> boolean,
	SetTracer: (tracer: ((Types.TraceEvent) -> ())?) -> (),
}

local Task = {} :: TaskModule

Task.Status = Records.Status
Task.Reason = Records.Reason
Task.Backoff = Records.Backoff

function Task.Start<T>(taskBody: (Types.Token) -> T, options: Types.TaskOptions?): Types.Task<T>
	return Constructors.Start(taskBody, options)
end

function Task.Delay(seconds: number, delayedCallback: (() -> any)?): Types.Task<any>
	return Constructors.Delay(seconds, delayedCallback)
end

function Task.Sleep(seconds: number, token: Types.Token?): (boolean, string?)
	return Constructors.Sleep(seconds, token)
end

function Task.Resolved<T>(value: T): Types.Task<T>
	return Constructors.Resolved(value)
end

function Task.Rejected(errorValue: unknown): Types.Task<never>
	return Constructors.Rejected(errorValue)
end

function Task.Cancelled(reason: string?): Types.Task<never>
	return Constructors.Cancelled(reason)
end

function Task.All<T>(tasks: { Types.Task<T> }): Types.Task<{ T }>
	return Combinators.All(tasks)
end

function Task.Race<T>(tasks: { Types.Task<T> }): Types.Task<T>
	return Combinators.Race(tasks)
end

function Task.Any<T>(tasks: { Types.Task<T> }): Types.Task<T>
	return Combinators.Any(tasks)
end

function Task.AllSettled(tasks: { Types.Task<any> }): Types.Task<{ Combinators.SettledResult }>
	return Combinators.AllSettled(tasks)
end

function Task.Timeout<T>(inner: Types.Task<T> | (() -> Types.Task<T>), seconds: number, reason: string?): Types.Task<T>
	return Combinators.Timeout(inner, seconds, reason)
end

function Task.Retry<T>(makeTask: (Types.Token) -> Types.Task<T>, options: Combinators.RetryOptions): Types.Task<T>
	return Combinators.Retry(makeTask, options)
end

function Task.FromRoblox(robloxSignal: RBXScriptSignal, untilSignal: RBXScriptSignal?): Types.Task<{ any }>
	return Combinators.FromRoblox(robloxSignal, untilSignal)
end

function Task.Group(options: Types.GroupOptions?): Types.TaskGroup
	local groupName = Records.ValidateGroupOptions(options, "Task.Group")
	local group = Records.CreateGroupRecord(groupName)
	return group
end

function Task.IsTask(value: unknown): boolean
	return Records.ValueIsLiveTask(value)
end

function Task.IsToken(value: unknown): boolean
	return Records.ValueIsLiveToken(value)
end

function Task.IsGroup(value: unknown): boolean
	return Records.ValueIsLiveGroup(value)
end

function Task.SetTracer(tracer: ((Types.TraceEvent) -> ())?): ()
	Records.SetTracer(tracer)
end

return table.freeze(Task)
