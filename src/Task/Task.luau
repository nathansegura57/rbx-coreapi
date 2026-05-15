--!strict

local Runtime = require(script._Runtime)
local Constructors = require(script._Constructors)
local Combinators = require(script._Combinators)
local Groups = require(script._Groups)

export type Status = Runtime.Status
export type CancellationReason = Runtime.CancellationReason
export type Backoff = Runtime.Backoff
export type Token = Runtime.Token
export type Task<T> = Runtime.Task<T>
export type TaskGroup = Runtime.TaskGroup
export type TaskOptions = Runtime.TaskOptions
export type GroupOptions = Runtime.GroupOptions
export type RetryOptions = Combinators.RetryOptions
export type SettledResult = Combinators.SettledResult
export type TraceEvent = Runtime.TraceEvent

export type TaskModule = {
	Status: Runtime.StatusSet,
	Reason: Runtime.ReasonSet,
	Backoff: Runtime.BackoffSet,

	Start: <T>(taskBody: (Runtime.Token) -> T, options: Runtime.TaskOptions?) -> Runtime.Task<T>,
	Delay: (seconds: number, delayedCallback: (() -> any)?) -> Runtime.Task<any>,
	Sleep: (seconds: number, token: Runtime.Token?) -> (boolean, string?),
	Resolved: <T>(value: T) -> Runtime.Task<T>,
	Rejected: (errorValue: unknown) -> Runtime.Task<never>,
	Cancelled: (reason: string?) -> Runtime.Task<never>,

	All: <T>(tasks: { Runtime.Task<T> }) -> Runtime.Task<{ T }>,
	Race: <T>(tasks: { Runtime.Task<T> }) -> Runtime.Task<T>,
	Any: <T>(tasks: { Runtime.Task<T> }) -> Runtime.Task<T>,
	AllSettled: (tasks: { Runtime.Task<any> }) -> Runtime.Task<{ Combinators.SettledResult }>,
	Timeout: <T>(inner: Runtime.Task<T> | (() -> Runtime.Task<T>), seconds: number, reason: string?) -> Runtime.Task<T>,
	Retry: <T>(makeTask: (Runtime.Token) -> Runtime.Task<T>, options: Combinators.RetryOptions) -> Runtime.Task<T>,
	FromRoblox: (robloxSignal: RBXScriptSignal, untilSignal: RBXScriptSignal?) -> Runtime.Task<{ any }>,

	Group: (options: Runtime.GroupOptions?) -> Runtime.TaskGroup,

	IsTask: (value: unknown) -> boolean,
	IsToken: (value: unknown) -> boolean,
	IsGroup: (value: unknown) -> boolean,
	SetTracer: (tracer: ((Runtime.TraceEvent) -> ())?) -> (),
}

local Task = {} :: TaskModule

Task.Status = Runtime.Status
Task.Reason = Runtime.Reason
Task.Backoff = Runtime.Backoff

function Task.Start<T>(taskBody: (Runtime.Token) -> T, options: Runtime.TaskOptions?): Runtime.Task<T>
	return Constructors.Start(taskBody, options)
end

function Task.Delay(seconds: number, delayedCallback: (() -> any)?): Runtime.Task<any>
	return Constructors.Delay(seconds, delayedCallback)
end

function Task.Sleep(seconds: number, token: Runtime.Token?): (boolean, string?)
	return Constructors.Sleep(seconds, token)
end

function Task.Resolved<T>(value: T): Runtime.Task<T>
	return Constructors.Resolved(value)
end

function Task.Rejected(errorValue: unknown): Runtime.Task<never>
	return Constructors.Rejected(errorValue)
end

function Task.Cancelled(reason: string?): Runtime.Task<never>
	return Constructors.Cancelled(reason)
end

function Task.All<T>(tasks: { Runtime.Task<T> }): Runtime.Task<{ T }>
	return Combinators.All(tasks)
end

function Task.Race<T>(tasks: { Runtime.Task<T> }): Runtime.Task<T>
	return Combinators.Race(tasks)
end

function Task.Any<T>(tasks: { Runtime.Task<T> }): Runtime.Task<T>
	return Combinators.Any(tasks)
end

function Task.AllSettled(tasks: { Runtime.Task<any> }): Runtime.Task<{ Combinators.SettledResult }>
	return Combinators.AllSettled(tasks)
end

function Task.Timeout<T>(inner: Runtime.Task<T> | (() -> Runtime.Task<T>), seconds: number, reason: string?): Runtime.Task<T>
	return Combinators.Timeout(inner, seconds, reason)
end

function Task.Retry<T>(makeTask: (Runtime.Token) -> Runtime.Task<T>, options: Combinators.RetryOptions): Runtime.Task<T>
	return Combinators.Retry(makeTask, options)
end

function Task.FromRoblox(robloxSignal: RBXScriptSignal, untilSignal: RBXScriptSignal?): Runtime.Task<{ any }>
	return Combinators.FromRoblox(robloxSignal, untilSignal)
end

function Task.Group(options: Runtime.GroupOptions?): Runtime.TaskGroup
	return Groups.Create(options)
end

function Task.IsTask(value: unknown): boolean
	return Runtime.ValueIsLiveTask(value)
end

function Task.IsToken(value: unknown): boolean
	return Runtime.ValueIsLiveToken(value)
end

function Task.IsGroup(value: unknown): boolean
	return Runtime.ValueIsLiveGroup(value)
end

function Task.SetTracer(tracer: ((Runtime.TraceEvent) -> ())?): ()
	Runtime.SetTracer(tracer)
end

return table.freeze(Task)

