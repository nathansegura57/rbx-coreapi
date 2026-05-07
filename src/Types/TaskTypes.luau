--!strict

local ConnectionModule = require(script.Parent.Parent.Internal.Connection)

export type Connection = ConnectionModule.Connection

-- Token: cancellation signal propagated into running jobs.
export type Token = {
	cancelled: (self: Token) -> boolean,
	reason:    (self: Token) -> string?,
	onCancel:  (self: Token, callback: (reason: string?) -> ()) -> Connection,
}

-- Task: handle representing a running (or completed) async job.
-- await() MUST be called from inside a running coroutine (i.e. inside a task job).
-- await(token) propagates token's cancellation into this task if the token is
-- cancelled first. Returns (true, result) on success, (false, reason) on
-- cancellation or error.
export type Task = {
	token:   (self: Task) -> Token,
	cancel:  (self: Task, reason: string?) -> (),
	status:  (self: Task) -> "pending" | "fulfilled" | "cancelled" | "error",
	finally: (self: Task, callback: (status: string, err: any?) -> ()) -> Task,
	result:  (self: Task) -> any?,
	error:   (self: Task) -> any?,
	name:    (self: Task) -> string?,
	await:   (self: Task, token: Token?) -> (boolean, any?),
}

-- TaskGroup: aggregate and control multiple tasks as a unit.
-- joinAll() snapshots the current task set — tasks added after the call are excluded.
export type TaskGroup = {
	add:       (self: TaskGroup, task: Task) -> TaskGroup,
	start:     (self: TaskGroup, fn: (token: Token) -> any?, opts: { name: string? }?) -> Task,
	cancelAll: (self: TaskGroup, reason: string?) -> (),
	joinAll:   (self: TaskGroup) -> Task,
	race:      (self: TaskGroup) -> Task,
	size:      (self: TaskGroup) -> number,
	name:      (self: TaskGroup) -> string?,
}

return nil

