--!strict

local Execution = require(script._Execution)
local Types = require(script._Types)

export type Concurrency = Types.Concurrency
export type Overflow = Types.Overflow
export type Schedule = Types.Schedule
export type ConcurrencySet = Types.ConcurrencySet
export type OverflowSet = Types.OverflowSet
export type ScheduleSet = Types.ScheduleSet
export type RuleFrame = Types.RuleFrame
export type Guard<ContextValue, Payload> = Types.Guard<ContextValue, Payload>
export type Effect<ContextValue, Payload> = Types.Effect<ContextValue, Payload>
export type RetryOptions = Types.RetryOptions
export type Policy = Types.Policy
export type PartialPolicy = Types.PartialPolicy
export type Metrics = Types.Metrics
export type TraceEvent = Types.TraceEvent
export type Rule<ContextValue, Payload> = Types.Rule<ContextValue, Payload>
export type RuleModule = Types.RuleModule

local Rule = {}

Rule.Concurrency = Execution.Concurrency
Rule.Overflow = Execution.Overflow
Rule.Schedule = Execution.Schedule

function Rule.New<ContextValue, Payload>(name: string): Rule<ContextValue, Payload>
	return Execution.New(name) :: any
end

function Rule.IsRule(value: unknown): boolean
	return Execution.IsRule(value)
end

function Rule.DefaultPolicy(): Policy
	return Execution.DefaultPolicy() :: any
end

function Rule.ValidatePolicy(policy: PartialPolicy): (boolean, string?)
	return Execution.ValidatePolicy(policy :: any)
end

function Rule.SetTracer(tracer: ((TraceEvent) -> ())?): ()
	Execution.SetTracer(tracer :: any)
end

function Rule._getAttachedRules(scope: unknown): { Rule<any, any> }
	return Execution._getAttachedRules(scope) :: any
end

return table.freeze(Rule) :: RuleModule
