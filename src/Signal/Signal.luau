--!strict

local Connection = require(script.Parent.Connection)

local Combinators = require(script._Combinators)
local Core = require(script._Core)
local Operators = require(script._Operators)
local Records = require(script._Records)
local Replay = require(script._Replay)
local RobloxBridge = require(script._RobloxBridge)
local Timers = require(script._Timers)
local Types = require(script._Types)


type SignalMethods = Types.SignalMethods


local Signal = {}
local signalMethods: SignalMethods = {}


export type CoreSignal<Value> = {
	Connect: (self: CoreSignal<Value>, listener: (Value) -> ()) -> Connection.Connection,
	Once: (self: CoreSignal<Value>, listener: (Value) -> ()) -> Connection.Connection,

	Fire: (self: CoreSignal<Value>, payload: Value) -> (),
	Wait: (self: CoreSignal<Value>) -> Value,

	DisconnectAll: (self: CoreSignal<Value>) -> (),
	Destroy: (self: CoreSignal<Value>) -> (),
	IsDestroyed: (self: CoreSignal<Value>) -> boolean,

	ReplayCount: (self: CoreSignal<Value>, count: number) -> CoreSignal<Value>,
	ReplayTime: (self: CoreSignal<Value>, seconds: number) -> CoreSignal<Value>,
	ClearReplay: (self: CoreSignal<Value>) -> CoreSignal<Value>,

	Filter: (self: CoreSignal<Value>, predicate: (Value) -> boolean) -> CoreSignal<Value>,
	Take: (self: CoreSignal<Value>, count: number) -> CoreSignal<Value>,
	Skip: (self: CoreSignal<Value>, count: number) -> CoreSignal<Value>,
	TakeWhile: (self: CoreSignal<Value>, predicate: (Value) -> boolean) -> CoreSignal<Value>,
	SkipWhile: (self: CoreSignal<Value>, predicate: (Value) -> boolean) -> CoreSignal<Value>,
	Debounce: (self: CoreSignal<Value>, seconds: number) -> CoreSignal<Value>,
	Throttle: (self: CoreSignal<Value>, seconds: number, options: ThrottleOptions?) -> CoreSignal<Value>,
	Delay: (self: CoreSignal<Value>, seconds: number) -> CoreSignal<Value>,
}

export type Signal<Value> = CoreSignal<Value> & {
	Map: <MappedValue>(self: Signal<Value>, mapper: (Value) -> MappedValue) -> CoreSignal<MappedValue>,
	Scan: <Accumulator>(self: Signal<Value>, reducer: (Accumulator, Value) -> Accumulator, seed: Accumulator) -> CoreSignal<Accumulator>,
	MergeMap: <InnerValue>(self: Signal<Value>, selector: (Value) -> CoreSignal<InnerValue>) -> CoreSignal<InnerValue>,
	SwitchMap: <InnerValue>(self: Signal<Value>, selector: (Value) -> CoreSignal<InnerValue>) -> CoreSignal<InnerValue>,

	TakeUntil: <StopperValue>(self: Signal<Value>, stopper: CoreSignal<StopperValue>) -> Signal<Value>,
	SkipUntil: <StarterValue>(self: Signal<Value>, starter: CoreSignal<StarterValue>) -> Signal<Value>,
	SampleBy: <SamplerValue>(self: Signal<Value>, sampler: CoreSignal<SamplerValue>) -> Signal<Value>,

	BufferCount: (self: Signal<Value>, count: number, step: number?) -> CoreSignal<{ Value } & { n: number }>,
	BufferTime: (self: Signal<Value>, seconds: number) -> CoreSignal<{ Value } & { n: number }>,
}

export type ReplayPolicy = Types.ReplayPolicy
export type ReplayPolicySet = Types.ReplayPolicySet
export type ThrottleOptions = Types.ThrottleOptions
export type SequenceOptions = Types.SequenceOptions

export type SequenceResult = {
	Time: number,
	Completed: boolean,
}


Signal.ReplayPolicy = table.freeze({
	Count = "Count" :: "Count",
	Time = "Time" :: "Time",
})


function Signal.New<Value>(): Signal<Value>
	return Records.createSignalHandle(signalMethods, false) :: Signal<Value>
end

function Signal.Never<Value>(): Signal<Value>
	return Records.createSignalHandle(signalMethods, true) :: Signal<Value>
end

function Signal.After(seconds: number): Signal<nil>
	return Timers.createSignalThatFiresOnceAfterDelay(Signal, seconds) :: Signal<nil>
end

function Signal.Every(seconds: number): Signal<nil>
	return Timers.createSignalThatFiresEveryInterval(Signal, seconds) :: Signal<nil>
end

function Signal.FromRoblox(robloxSignal: RBXScriptSignal, mapper: ((...any) -> any)?): Signal<any>
	return RobloxBridge.createSignalFromRobloxSignal(Signal, robloxSignal, mapper)
end

function Signal.IsSignal(value: unknown): boolean
	return Records.isLiveSignalHandle(value)
end

function Signal.Merge<Value>(signals: { CoreSignal<Value> }): Signal<Value>
	return Combinators.mergeSignals(Signal, signals) :: Signal<Value>
end

function Signal.Zip<Value>(signals: { CoreSignal<Value> }): Signal<{ Value }>
	return Combinators.zipSignals(Signal, signals) :: Signal<{ Value }>
end

function Signal.Race<Value>(signals: { CoreSignal<Value> }): Signal<Value>
	return Combinators.raceSignals(Signal, signals) :: Signal<Value>
end

function Signal.Sequence<Value>(signals: { CoreSignal<Value> }, options: SequenceOptions?): Signal<SequenceResult>
	return Combinators.sequenceSignals(Signal, signals, options) :: Signal<SequenceResult>
end


Core.defineCoreInstanceMethods(signalMethods)
Replay.defineReplayPolicyMethods(signalMethods)
Operators.defineReactiveOperatorMethods(Signal :: any, signalMethods)


return table.freeze(Signal)

