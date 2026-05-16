--!strict

local Transitions = require(script._Transitions)
local Types = require(script._Types)

export type ExitOrdering = Types.ExitOrdering
export type Deferral = Types.Deferral
export type ExitOrderingSet = Types.ExitOrderingSet
export type DeferralSet = Types.DeferralSet
export type TransitionEvent = Types.TransitionEvent
export type TransitionFrame = Types.TransitionFrame
export type UpdateFrame = Types.UpdateFrame
export type SwitchOptions = Types.SwitchOptions
export type SnapshotOptions = Types.SnapshotOptions
export type Snapshot = Types.Snapshot
export type GuardOptions = Types.GuardOptions
export type FSMTraceEvent = Types.FSMTraceEvent
export type Policy = Types.Policy
export type PartialPolicy = Types.PartialPolicy
export type FSM<ContextValue> = Types.FSM<ContextValue>
export type Mode<ContextValue> = Types.Mode<ContextValue>
export type FSMModuleType = Types.FSMModuleType

local FSM = {}

FSM.ExitOrdering = Transitions.ExitOrdering
FSM.Deferral = Transitions.Deferral

function FSM.New<ContextValue>(ctx: any, opts: PartialPolicy?): FSM<ContextValue>
	return Transitions.New(ctx, opts) :: any
end

function FSM.IsFSM(value: unknown): boolean
	return Transitions.IsFSM(value)
end

function FSM.IsMode(value: unknown): boolean
	return Transitions.IsMode(value)
end

function FSM.DefaultPolicy(): Policy
	return Transitions.DefaultPolicy() :: any
end

function FSM.ValidatePolicy(policy: PartialPolicy): (boolean, string?)
	return Transitions.ValidatePolicy(policy :: any)
end

function FSM.SetTracer(fn: ((FSMTraceEvent) -> ())?): ()
	Transitions.SetTracer(fn :: any)
end

return table.freeze(FSM) :: FSMModuleType
