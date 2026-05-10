--!strict

local ConnectionModule = require(script.Parent.Parent.Internal.Connection)

export type Connection = ConnectionModule.Connection

export type ThrottleOptions = {
	leading:  boolean?,
	trailing: boolean?,
}

export type SequenceOptions = {
	minTimeBetween:  number?,
	maxTimeBetween:  number?,
	minTotalTime:    number?,
	maxTotalTime:    number?,
	resetOnMismatch: boolean?,
	fireOnMismatch:  boolean?,
}

export type SequencePayload = { time: number, completed: boolean }

-- SignalCore<Payload>: non-transform methods shared by all signals.
type SignalCore<Payload> = {
	connect: (self: SignalCore<Payload>, listener: (Payload) -> ()) -> Connection,
	once:    (self: SignalCore<Payload>, listener: (Payload) -> ()) -> Connection,
	fire:    (self: SignalCore<Payload>, payload: Payload) -> (),
	destroy: (self: SignalCore<Payload>) -> (),
	
	-- transform
	filter: (self: SignalCore<Payload>, predicate: (Payload) -> boolean) -> SignalCore<Payload>,
	
	-- count-based
	take:  (self: SignalCore<Payload>, count: number) -> SignalCore<Payload>,
	skip:  (self: SignalCore<Payload>, count: number) -> SignalCore<Payload>,
	takeWhile: (self: SignalCore<Payload>, predicate: (Payload) -> boolean) -> SignalCore<Payload>,
	skipWhile: (self: SignalCore<Payload>, predicate: (Payload) -> boolean) -> SignalCore<Payload>,
	
	-- time-based
	debounce: (self: SignalCore<Payload>, seconds: number) -> SignalCore<Payload>,
	throttle: (self: SignalCore<Payload>, seconds: number, options: ThrottleOptions?) -> SignalCore<Payload>,
	delay:    (self: SignalCore<Payload>, seconds: number) -> SignalCore<Payload>,
	
	-- replay
	replayCount: (self: SignalCore<Payload>, count: number) -> SignalCore<Payload>,
	replayTime:  (self: SignalCore<Payload>, seconds: number) -> SignalCore<Payload>,
	clearReplays: (self: SignalCore<Payload>) -> SignalCore<Payload>,
}

-- Signal<Payload>: full type including all transform operators.
export type Signal<Payload> = SignalCore<Payload> & {
	-- transform
	map:         <Mapped>(self: Signal<Payload>, mapper: (Payload) -> Mapped) -> SignalCore<Mapped>,
	scan:        <Accumulator>(self: Signal<Payload>, reducer: (Accumulator, Payload) -> Accumulator, seed: Accumulator) -> SignalCore<Accumulator>,
	flatMap:     <Inner>(self: Signal<Payload>, selector: (Payload) -> SignalCore<Inner>) -> SignalCore<Inner>,
	
	-- signal-gated
	takeUntil:   <Stop>(self: Signal<Payload>, stopper: SignalCore<Stop>) -> Signal<Payload>,
	skipUntil:   <Stimulus>(self: Signal<Payload>, stimulus: SignalCore<Stimulus>) -> Signal<Payload>,
	
	-- buffering
	bufferCount: (self: Signal<Payload>, count: number, step: number?) -> SignalCore<{ Payload }>,
	bufferTime:  (self: Signal<Payload>, seconds: number) -> SignalCore<{ Payload }>,
	sampleBy:    <Tick>(self: Signal<Payload>, sampler: SignalCore<Tick>) -> Signal<Payload>,
}

return nil

