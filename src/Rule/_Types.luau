--!strict

local Connection = require(script.Parent.Parent.Connection)
local Context = require(script.Parent.Parent.Context)
local ErrorHandler = require(script.Parent.Parent.ErrorHandler)
local Scheduler = require(script.Parent.Parent.Scheduler)
local Signal = require(script.Parent.Parent.Signal)
local Store = require(script.Parent.Parent.Store)
local Task = require(script.Parent.Parent.Task)

export type Concurrency = "Exhaust" | "Merge" | "Concat" | "Switch"
export type Overflow = "Drop" | "Latest" | "Fifo"
export type Schedule = "Immediate" | "Deferred"

export type ConcurrencySet = {
	Exhaust: "Exhaust",
	Merge: "Merge",
	Concat: "Concat",
	Switch: "Switch",
}

export type OverflowSet = {
	Drop: "Drop",
	Latest: "Latest",
	Fifo: "Fifo",
}

export type ScheduleSet = {
	Immediate: "Immediate",
	Deferred: "Deferred",
}

export type RuleFrame = {
	RuleName: string,
	Now: () -> number,
	Token: Task.Token?,
}

export type Guard<ContextValue, Payload> =
	Store.ReadableStore<boolean>
| ((context: ContextValue, payload: Payload, frame: RuleFrame) -> boolean)

export type Effect<ContextValue, Payload> =
	(context: ContextValue, payload: Payload, frame: RuleFrame) -> (() -> ())?
| (context: ContextValue, payload: Payload, frame: RuleFrame) -> Task.Task<any>?
| (context: ContextValue, payload: Payload, frame: RuleFrame) -> nil

export type RetryOptions = Task.RetryOptions

export type Policy = {
	Concurrency: Concurrency,
	Capacity: number,
	Overflow: Overflow,
	Cooldown: number?,
	Debounce: number?,
	Throttle: number?,
	Leading: boolean,
	Trailing: boolean,
	Schedule: Schedule,
	RecheckGuardBeforeRun: boolean,
	CancelTasksWhenGuardFalse: boolean,
	Once: boolean,
	ErrorPolicy: ErrorHandler.Policy?,
	Retry: RetryOptions?,
	Trace: boolean,
	Tag: string?,
}

export type PartialPolicy = {
	Concurrency: Concurrency?,
	Capacity: number?,
	Overflow: Overflow?,
	Cooldown: number?,
	Debounce: number?,
	Throttle: number?,
	Leading: boolean?,
	Trailing: boolean?,
	Schedule: Schedule?,
	RecheckGuardBeforeRun: boolean?,
	CancelTasksWhenGuardFalse: boolean?,
	Once: boolean?,
	ErrorPolicy: ErrorHandler.Policy?,
	Retry: RetryOptions?,
	Trace: boolean?,
	Tag: string?,
}

export type Metrics = {
	Runs: number,
	Skipped: number,
	Errors: number,
	AvgMs: number,
	CollectedErrors: { unknown },
}

export type TraceEvent = {
	Event: string,
	RuleName: string,
	Tag: string?,
}

export type Rule<ContextValue, Payload> = {
	On: (self: Rule<ContextValue, Payload>, signal: Signal.Signal<Payload>) -> Rule<ContextValue, Payload>,
	When: (self: Rule<ContextValue, Payload>, guard: Guard<ContextValue, Payload>) -> Rule<ContextValue, Payload>,
	Run: (self: Rule<ContextValue, Payload>, effect: Effect<ContextValue, Payload>) -> Rule<ContextValue, Payload>,
	Policy: (self: Rule<ContextValue, Payload>, policy: PartialPolicy) -> Rule<ContextValue, Payload>,
	WithContext: (self: Rule<ContextValue, Payload>, context: Context.Context<ContextValue>) -> Rule<ContextValue, Payload>,
	Attach: (self: Rule<ContextValue, Payload>, scope: unknown) -> Rule<ContextValue, Payload>,

	Enable: (self: Rule<ContextValue, Payload>, context: Context.Context<ContextValue>?) -> Rule<ContextValue, Payload>,
	Disable: (self: Rule<ContextValue, Payload>) -> (),
	Destroy: (self: Rule<ContextValue, Payload>) -> (),

	IsEnabled: (self: Rule<ContextValue, Payload>) -> boolean,
	IsDestroyed: (self: Rule<ContextValue, Payload>) -> boolean,
	Name: (self: Rule<ContextValue, Payload>) -> string,
	Metrics: (self: Rule<ContextValue, Payload>) -> Metrics,
	ResetMetrics: (self: Rule<ContextValue, Payload>) -> (),
}

export type RuleModule = {
	New: <ContextValue, Payload>(name: string) -> Rule<ContextValue, Payload>,
	IsRule: (value: unknown) -> boolean,
	DefaultPolicy: () -> Policy,
	ValidatePolicy: (policy: PartialPolicy) -> (boolean, string?),
	SetTracer: (tracer: ((TraceEvent) -> ())?) -> (),

	Concurrency: ConcurrencySet,
	Overflow: OverflowSet,
	Schedule: ScheduleSet,
}

return nil

