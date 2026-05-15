--!strict

local Runtime = require(script._Runtime)
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

Rule.Concurrency = Runtime.Concurrency
Rule.Overflow = Runtime.Overflow
Rule.Schedule = Runtime.Schedule

function Rule.New<ContextValue, Payload>(name: string): Rule<ContextValue, Payload>
	return Runtime.New(name) :: any
end

function Rule.IsRule(value: unknown): boolean
	return Runtime.IsRule(value)
end

function Rule.DefaultPolicy(): Policy
	return Runtime.DefaultPolicy() :: any
end

function Rule.ValidatePolicy(policy: PartialPolicy): (boolean, string?)
	return Runtime.ValidatePolicy(policy :: any)
end

function Rule.SetTracer(tracer: ((TraceEvent) -> ())?): ()
	Runtime.SetTracer(tracer :: any)
end

function Rule._getAttachedRules(scope: unknown): { Rule<any, any> }
	return Runtime._getAttachedRules(scope) :: any
end

return table.freeze(Rule) :: RuleModule

