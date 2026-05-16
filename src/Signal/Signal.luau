--!strict

local Connection = require(script.Parent.Connection)
local ErrorHandler = require(script.Parent.ErrorHandler)
local Scheduler = require(script.Parent.Scheduler)

local Combinators = require(script._Combinators)
local Operators = require(script._Operators)
local Records = require(script._Records)
local Replay = require(script._Replay)
local Types = require(script._Types)
local Validation = require(script._Validation)


type ListenerEntry = Types.ListenerEntry
type WaiterEntry = Types.WaiterEntry
type SignalRecord = Types.SignalRecord
type SignalMethods = Types.SignalMethods
type SignalModule = Types.SignalModule


-- ── Public types ──────────────────────────────────────────────────────────────

export type BaseReadableSignal<Value> = {
	Connect: (self: BaseReadableSignal<Value>, listener: (Value) -> ()) -> Connection.Connection,
	Once: (self: BaseReadableSignal<Value>, listener: (Value) -> ()) -> Connection.Connection,

	Wait: (self: BaseReadableSignal<Value>) -> Value,

	DisconnectAll: (self: BaseReadableSignal<Value>) -> (),
	Destroy: (self: BaseReadableSignal<Value>) -> (),
	IsDestroyed: (self: BaseReadableSignal<Value>) -> boolean,

	ReplayCount: (self: BaseReadableSignal<Value>, count: number) -> BaseReadableSignal<Value>,
	ReplayTime: (self: BaseReadableSignal<Value>, seconds: number) -> BaseReadableSignal<Value>,
	ClearReplay: (self: BaseReadableSignal<Value>) -> BaseReadableSignal<Value>,

	Filter: (self: BaseReadableSignal<Value>, predicate: (Value) -> boolean) -> BaseReadableSignal<Value>,
	Take: (self: BaseReadableSignal<Value>, count: number) -> BaseReadableSignal<Value>,
	Skip: (self: BaseReadableSignal<Value>, count: number) -> BaseReadableSignal<Value>,
	TakeWhile: (self: BaseReadableSignal<Value>, predicate: (Value) -> boolean) -> BaseReadableSignal<Value>,
	SkipWhile: (self: BaseReadableSignal<Value>, predicate: (Value) -> boolean) -> BaseReadableSignal<Value>,
	Debounce: (self: BaseReadableSignal<Value>, seconds: number) -> BaseReadableSignal<Value>,
	Throttle: (self: BaseReadableSignal<Value>, seconds: number, options: ThrottleOptions?) -> BaseReadableSignal<Value>,
	Delay: (self: BaseReadableSignal<Value>, seconds: number) -> BaseReadableSignal<Value>,
}

export type ReadableSignal<Value> = BaseReadableSignal<Value> & {
	Map: <MappedValue>(self: ReadableSignal<Value>, mapper: (Value) -> MappedValue) -> BaseReadableSignal<MappedValue>,
	Scan: <Accumulator>(self: ReadableSignal<Value>, reducer: (Accumulator, Value) -> Accumulator, seed: Accumulator) -> BaseReadableSignal<Accumulator>,
	MergeMap: <InnerValue>(self: ReadableSignal<Value>, selector: (Value) -> BaseReadableSignal<InnerValue>) -> BaseReadableSignal<InnerValue>,
	SwitchMap: <InnerValue>(self: ReadableSignal<Value>, selector: (Value) -> BaseReadableSignal<InnerValue>) -> BaseReadableSignal<InnerValue>,

	TakeUntil: <StopperValue>(self: ReadableSignal<Value>, stopper: BaseReadableSignal<StopperValue>) -> ReadableSignal<Value>,
	SkipUntil: <StarterValue>(self: ReadableSignal<Value>, starter: BaseReadableSignal<StarterValue>) -> ReadableSignal<Value>,
	SampleBy: <SamplerValue>(self: ReadableSignal<Value>, sampler: BaseReadableSignal<SamplerValue>) -> ReadableSignal<Value>,

	BufferCount: (self: ReadableSignal<Value>, count: number, step: number?) -> BaseReadableSignal<{ Value } & { n: number }>,
	BufferTime: (self: ReadableSignal<Value>, seconds: number) -> BaseReadableSignal<{ Value } & { n: number }>,
}

export type Signal<Value> = ReadableSignal<Value> & {
	Fire: (self: Signal<Value>, payload: Value) -> (),
}

export type ReplayPolicy = Types.ReplayPolicy
export type ReplayPolicySet = Types.ReplayPolicySet
export type ThrottleOptions = Types.ThrottleOptions
export type SequenceOptions = Types.SequenceOptions

export type SequenceResult = {
	Time: number,
	Completed: boolean,
}


-- ── Enum ──────────────────────────────────────────────────────────────────────

local countReplayPolicy: "Count" = "Count"
local timeReplayPolicy: "Time" = "Time"

local replayPolicyEnum: ReplayPolicySet = table.freeze({
	Count = countReplayPolicy,
	Time = timeReplayPolicy,
})


-- ── Module ────────────────────────────────────────────────────────────────────

local Signal = {}
local signalMethods: SignalMethods = {}

Signal.ReplayPolicy = replayPolicyEnum


-- ── Core helpers ──────────────────────────────────────────────────────────────

local function disconnectAllListeners(signalRecord: SignalRecord): ()
	for _, listenerEntry in signalRecord.Listeners do
		listenerEntry.Connected = false
	end

	if signalRecord.FireDepth == 0 then
		table.clear(signalRecord.Listeners)
	end
end

local function resumeWaiterWithPayload(waiterThread: thread, payload: any): ()
	Scheduler.Defer(function()
		coroutine.resume(waiterThread, true, payload)
	end)
end

local function resumeWaiterWithDestroyedError(waiterThread: thread): ()
	Scheduler.Defer(function()
		coroutine.resume(waiterThread, false, nil)
	end)
end

local function runSignalCleanupCallbacks(signalRecord: SignalRecord): ()
	local cleanupCallbacks = table.clone(signalRecord.CleanupCallbacks)
	table.clear(signalRecord.CleanupCallbacks)

	for _, cleanupCallback in cleanupCallbacks do
		ErrorHandler.Protect(cleanupCallback, "Signal", "Cleanup")
	end
end


-- ── Timers ────────────────────────────────────────────────────────────────────

local function createSignalThatFiresOnceAfterDelay(signalModule: SignalModule, seconds: number): any
	local delaySeconds = Validation.ensureNonNegativeSeconds(seconds, "Signal.After: seconds must be non-negative")

	local signal = signalModule.New()
	local timerHandle = Scheduler.Delay(delaySeconds, function()
		local signalRecord = Records.getSignalRecord(signal)

		if signalRecord == nil or signalRecord.Destroyed then
			return
		end

		signal:Fire(nil)
		signal:Destroy()
	end)

	Records.attachTimerHandle(signal, timerHandle)

	return signal
end

local function createSignalThatFiresEveryInterval(signalModule: SignalModule, seconds: number): any
	local intervalSeconds = Validation.ensurePositiveSeconds(seconds, "Signal.Every: seconds must be positive")

	local signal = signalModule.New()
	local signalRecord = Records.getSignalRecord(signal)

	local function scheduleNextTick(): ()
		local timerHandle = Scheduler.Delay(intervalSeconds, function()
			local currentRecord = Records.getSignalRecord(signal)

			if currentRecord == nil or currentRecord.Destroyed then
				return
			end

			signal:Fire(nil)

			if not currentRecord.Destroyed then
				table.clear(currentRecord.TimerHandles)
				scheduleNextTick()
			end
		end)

		if signalRecord ~= nil then
			table.clear(signalRecord.TimerHandles)
			table.insert(signalRecord.TimerHandles, timerHandle)
		end
	end

	scheduleNextTick()

	return signal
end


-- ── Roblox bridge ─────────────────────────────────────────────────────────────

local function createSignalFromRobloxSignal(signalModule: SignalModule, rbxSignal: RBXScriptSignal, mapper: ((...any) -> any)?): any
	if typeof(rbxSignal) ~= "RBXScriptSignal" then
		ErrorHandler.RaiseUsageError("Signal.FromRoblox: expected RBXScriptSignal")
	end

	if mapper ~= nil and type(mapper) ~= "function" then
		ErrorHandler.RaiseUsageError("Signal.FromRoblox: mapper must be a function or nil")
	end

	local signal = signalModule.New()

	local robloxConnection = (rbxSignal :: any):Connect(function(...)
		local signalRecord = Records.getSignalRecord(signal)

		if signalRecord == nil or signalRecord.Destroyed then
			return
		end

		local payload: any = table.pack(...)

		if mapper ~= nil then
			local mapperSucceeded, mappedPayload = ErrorHandler.Protect(function()
				return mapper(table.unpack(payload, 1, payload.n))
			end, "Signal", "FromRoblox")

			if not mapperSucceeded then
				return
			end

			payload = mappedPayload
		end

		signal:Fire(payload)
	end)

	Records.attachCleanupCallback(signal, function()
		robloxConnection:Disconnect()
	end)

	return signal
end


-- ── Factory ───────────────────────────────────────────────────────────────────

function Signal.New<Value>(): Signal<Value>
	return Records.createSignalHandle(signalMethods, false) :: Signal<Value>
end

function Signal.Never<Value>(): Signal<Value>
	return Records.createSignalHandle(signalMethods, true) :: Signal<Value>
end

function Signal.After(seconds: number): Signal<nil>
	return createSignalThatFiresOnceAfterDelay(Signal, seconds) :: Signal<nil>
end

function Signal.Every(seconds: number): Signal<nil>
	return createSignalThatFiresEveryInterval(Signal, seconds) :: Signal<nil>
end

function Signal.FromRoblox(robloxSignal: RBXScriptSignal, mapper: ((...any) -> any)?): Signal<any>
	return createSignalFromRobloxSignal(Signal, robloxSignal, mapper) :: Signal<any>
end

function Signal.IsSignal(value: unknown): boolean
	return Records.isLiveSignalHandle(value)
end

function Signal.Merge<Value>(signals: { BaseReadableSignal<Value> }): Signal<Value>
	return Combinators.mergeSignals(Signal, signals) :: Signal<Value>
end

function Signal.Zip<Value>(signals: { BaseReadableSignal<Value> }): Signal<{ Value }>
	return Combinators.zipSignals(Signal, signals) :: Signal<{ Value }>
end

function Signal.Race<Value>(signals: { BaseReadableSignal<Value> }): Signal<Value>
	return Combinators.raceSignals(Signal, signals) :: Signal<Value>
end

function Signal.Sequence<Value>(signals: { BaseReadableSignal<Value> }, options: SequenceOptions?): Signal<SequenceResult>
	return Combinators.sequenceSignals(Signal, signals, options) :: Signal<SequenceResult>
end


-- ── Instance methods ──────────────────────────────────────────────────────────

local function defineCoreInstanceMethods(methods: SignalMethods): ()
	function methods:Connect(listener: (any) -> ()): any
		Validation.ensureCallback(listener, "Signal.Connect: listener must be a function")

		local signalRecord = Records.getLiveSignalRecordOrError(self, "Signal.Connect: signal is destroyed")

		local listenerEntry: ListenerEntry = {
			Connected = true,
			Fn = listener,
		}

		table.insert(signalRecord.Listeners, listenerEntry)

		local connection = Records.createConnectionForListener(signalRecord, listenerEntry)

		Replay.scheduleReplayForNewListener(signalRecord, listenerEntry)

		return connection
	end

	function methods:Once(listener: (any) -> ()): any
		Validation.ensureCallback(listener, "Signal.Once: listener must be a function")

		local signalRecord = Records.getLiveSignalRecordOrError(self, "Signal.Once: signal is destroyed")

		local listenerEntry: ListenerEntry

		listenerEntry = {
			Connected = true,

			Fn = function(payload: any): ()
				if not listenerEntry.Connected then
					return
				end

				listenerEntry.Connected = false
				Records.compactDisconnectedListenersWhenSafe(signalRecord)

				listener(payload)
			end,
		}

		table.insert(signalRecord.Listeners, listenerEntry)

		local connection = Records.createConnectionForListener(signalRecord, listenerEntry)

		Replay.scheduleReplayForNewListener(signalRecord, listenerEntry)

		return connection
	end

	function methods:Fire(payload: any): ()
		local signalRecord = Records.getSignalRecord(self)

		if signalRecord == nil or signalRecord.Destroyed then
			return
		end

		if signalRecord.IsNever then
			ErrorHandler.RaiseUsageError("Signal.Fire: cannot fire a never signal")
		end

		Replay.storePayloadForActiveReplayPolicy(signalRecord, payload)

		signalRecord.FireDepth += 1

		local listenerSnapshot = signalRecord.Listeners
		local listenerCount = #listenerSnapshot

		for listenerIndex = 1, listenerCount do
			local listenerEntry = listenerSnapshot[listenerIndex]

			if listenerEntry.Connected then
				ErrorHandler.Protect(function()
					listenerEntry.Fn(payload)
				end, "Signal", "Listener")
			end
		end

		signalRecord.FireDepth -= 1

		if signalRecord.FireDepth == 0 then
			Records.compactDisconnectedListenersWhenSafe(signalRecord)
		end
	end

	function methods:Wait(): any
		local signalRecord = Records.getLiveSignalRecordOrError(self, "Signal.Wait: signal is destroyed")

		if not coroutine.isyieldable() then
			ErrorHandler.RaiseUsageError("Signal.Wait: must be called from a yieldable coroutine")
		end

		local waiterThread = coroutine.running() :: thread

		local waiterEntry: WaiterEntry = {
			Thread = waiterThread,
		}

		table.insert(signalRecord.Waiters, waiterEntry)

		local listenerEntry: ListenerEntry

		listenerEntry = {
			Connected = true,

			Fn = function(payload: any): ()
				if not listenerEntry.Connected then
					return
				end

				listenerEntry.Connected = false

				for waiterIndex = 1, #signalRecord.Waiters do
					if signalRecord.Waiters[waiterIndex] == waiterEntry then
						table.remove(signalRecord.Waiters, waiterIndex)
						break
					end
				end

				resumeWaiterWithPayload(waiterThread, payload)
			end,
		}

		table.insert(signalRecord.Listeners, listenerEntry)

		local waitSucceeded, waitedPayload = coroutine.yield()

		if not waitSucceeded then
			ErrorHandler.RaiseUsageError("Signal.Wait: signal destroyed")
		end

		return waitedPayload
	end

	function methods:DisconnectAll(): ()
		local signalRecord = Records.getSignalRecord(self)

		if signalRecord == nil then
			return
		end

		disconnectAllListeners(signalRecord)
	end

	function methods:Destroy(): ()
		local signalRecord = Records.getSignalRecord(self)

		if signalRecord == nil or signalRecord.Destroyed then
			return
		end

		signalRecord.Destroyed = true

		disconnectAllListeners(signalRecord)

		local waiters = table.clone(signalRecord.Waiters)
		table.clear(signalRecord.Waiters)

		for _, waiterEntry in waiters do
			resumeWaiterWithDestroyedError(waiterEntry.Thread)
		end

		table.clear(signalRecord.ReplayBuffer)
		signalRecord.ReplayPolicy = nil

		Records.clearTimerHandles(signalRecord)
		runSignalCleanupCallbacks(signalRecord)
	end

	function methods:IsDestroyed(): boolean
		local signalRecord = Records.getSignalRecord(self)

		return signalRecord == nil or signalRecord.Destroyed
	end
end


-- ── Method registration ───────────────────────────────────────────────────────

defineCoreInstanceMethods(signalMethods)
Replay.defineReplayPolicyMethods(signalMethods)
Operators.defineReactiveOperatorMethods(Signal :: any, signalMethods)


return table.freeze(Signal)
