--!strict

local Connection = require(script.Parent.Parent.Connection)

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

return table.freeze({})
