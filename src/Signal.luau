--!strict
--!optimize 2

-- Signal<Payload>: hot push-based event stream. Single typed payload.
--
-- Safety model
--   Instances are frozen opaque handles. All mutable state lives in
--   module-private weak tables keyed by identity — rawget finds nothing,
--   rawset fails on frozen tables, getmetatable returns the string "Signal".
--   External code has no surface to corrupt internal state.
--
-- Lifetime
--   source destroyed  → all derived (child) signals destroyed
--   derived destroyed → disconnects from source; source is unaffected
--   merge / zip / race → any input destroyed → output destroyed
--
-- Delivery
--   Synchronous in connection order. Re-entrant fires are safe: the
--   SubscriberList depth counter defers node sweeps until the outermost
--   fire() returns.
--
-- Replay
--   Applies to direct subscribers only. Operators (map, filter, …) use an
--   internal rawAppend that skips replay to avoid double-delivery.
--   Add explicit :replayCount()/:replayTime() to derived signals as needed.
--
-- Network
--   In-process only. Remote bridging belongs in a separate module.

local ConnectionModule    = require(script.Parent.Internal.Connection)
local SubscriberListModule = require(script.Parent.Internal.SubscriberList)
local SchedulerModule     = require(script.Parent.Internal.Scheduler)
local SignalTypes         = require(script.Parent.Types.SignalTypes)

local Scheduler = SchedulerModule.Scheduler

-- ── Internal types ─────────────────────────────────────────────────────────────

type ReplayEntry = { payload: any, captureTime: number }

type SignalRecord = {
	subscriberList:  SubscriberListModule.SubscriberList,
	destroyed:       boolean,
	isNever:         boolean,
	destroyHooks:    { () -> () }?,
	replay: {
		entries: { ReplayEntry },
		policy:  { count: number?, time: number? },
	}?,
}

-- Weak keys: abandoned handles are collected by GC without explicit cleanup.
local signalState: { [any]: SignalRecord } =
	setmetatable({}, { __mode = "k" } :: { __mode: "k" }) :: any

-- ── Public types ───────────────────────────────────────────────────────────────

export type Connection      = SignalTypes.Connection
export type ThrottleOptions = SignalTypes.ThrottleOptions
export type SequenceOptions = SignalTypes.SequenceOptions
export type SequencePayload = SignalTypes.SequencePayload
export type Signal<Payload> = SignalTypes.Signal<Payload>

-- ── Signal state helpers ───────────────────────────────────────────────────────

local function newSignalRecord(): SignalRecord
	return {
		subscriberList = SubscriberListModule.create(),
		destroyed      = false,
		isNever        = false,
		destroyHooks   = nil,
		replay         = nil,
	}
end

local function addDestroyHook(signalRecord: SignalRecord, hook: () -> ())
	if not signalRecord.destroyHooks then signalRecord.destroyHooks = {} end
	table.insert(signalRecord.destroyHooks :: { () -> () }, hook)
end

-- ── Signal method table ────────────────────────────────────────────────────────

local signalMethods = {}

local SIGNAL_META = {
	__metatable = "Signal",
	__newindex  = function(_, key: string)
		error(`Signal: '{key}' is read-only`, 2)
	end,
	__index = signalMethods,
}

local function newSignal(): Signal<any>
	local handle = setmetatable({}, SIGNAL_META)
	signalState[handle] = newSignalRecord()
	return handle :: any
end

local function newNeverSignal(): Signal<any>
	local handle = setmetatable({}, SIGNAL_META)
	local record        = newSignalRecord()
	record.isNever      = true
	signalState[handle] = record
	return handle :: any
end

-- ── Internal append (no replay) ───────────────────────────────────────────────

-- Used by operators to subscribe to a source signal without triggering replay,
-- avoiding double-delivery to the derived signal's own subscribers.
local function rawAppend(signalRecord: SignalRecord, listener: (any) -> ()): Connection
	local isStillConnected, performDisconnect =
		SubscriberListModule.append(signalRecord.subscriberList, listener :: any)
	return ConnectionModule.create(isStillConnected, performDisconnect)
end

-- ── Core methods ───────────────────────────────────────────────────────────────

function signalMethods:connect(listener: (any) -> ()): Connection
	local signalRecord = signalState[self]
	assert(signalRecord and not signalRecord.destroyed, "Signal.connect: signal is destroyed")

	local isStillConnected, performDisconnect =
		SubscriberListModule.append(signalRecord.subscriberList, listener :: any)
	local connection = ConnectionModule.create(isStillConnected, performDisconnect)

	-- Replay: deliver buffered emissions to the new subscriber via defer so the
	-- subscriber finishes initialising before it receives past values.
	local replay = signalRecord.replay
	if replay and #replay.entries > 0 then
		local windowSeconds = replay.policy.time
		local currentTime   = windowSeconds and time() or nil
		for _, entry in ipairs(replay.entries) do
			if not currentTime or (currentTime - entry.captureTime) <= (windowSeconds :: number) then
				local payload = entry.payload
				Scheduler.defer(function()
					if isStillConnected() then listener(payload) end
				end)
			end
		end
	end

	return connection
end

function signalMethods:once(listener: (any) -> ()): Connection
	local connection: Connection
	connection = signalMethods.connect(self :: any, function(payload: any)
		connection:Disconnect()
		listener(payload)
	end)
	return connection
end

function signalMethods:fire(payload: any)
	local signalRecord = signalState[self]
	if not signalRecord or signalRecord.destroyed then return end
	assert(not signalRecord.isNever, "Signal.fire: cannot fire a never signal")

	if not signalRecord.subscriberList.headNode then
		-- Still record to replay buffer even with no subscribers.
		local replay = signalRecord.replay
		if replay then
			local currentTime = time()
			table.insert(replay.entries, { payload = payload, captureTime = currentTime })
			local policy = replay.policy
			if policy.count then
				while #replay.entries > (policy.count :: number) do
					table.remove(replay.entries, 1)
				end
			elseif policy.time then
				local windowSeconds = policy.time :: number
				while #replay.entries > 0 and (currentTime - replay.entries[1].captureTime) > windowSeconds do
					table.remove(replay.entries, 1)
				end
			end
		end
		return
	end

	local replay = signalRecord.replay
	if replay then
		local currentTime = time()
		table.insert(replay.entries, { payload = payload, captureTime = currentTime })
		local policy = replay.policy
		if policy.count then
			while #replay.entries > (policy.count :: number) do
				table.remove(replay.entries, 1)
			end
		elseif policy.time then
			local windowSeconds = policy.time :: number
			while #replay.entries > 0 and (currentTime - replay.entries[1].captureTime) > windowSeconds do
				table.remove(replay.entries, 1)
			end
		end
	end

	SubscriberListModule.fire(signalRecord.subscriberList, payload, nil)
end

function signalMethods:destroy()
	local signalRecord = signalState[self]
	if not signalRecord or signalRecord.destroyed then return end
	signalRecord.destroyed = true

	SubscriberListModule.destroyAll(signalRecord.subscriberList)
	signalRecord.replay = nil

	local hooks = signalRecord.destroyHooks
	signalRecord.destroyHooks = nil
	if hooks then
		for _, hook in ipairs(hooks) do hook() end
	end

	signalState[self] = nil
end

-- ── Operator helpers ───────────────────────────────────────────────────────────

-- Creates a derived signal wired to a source signal.
-- Returns (derivedHandle, derivedRecord) so the caller can finish wiring.
local function newDerivedSignal(
	sourceRecord: SignalRecord,
	sourceListener: (any) -> ()
): Signal<any>
	local derived         = newSignal()
	local derivedRecord   = signalState[derived] :: SignalRecord
	local sourceConn      = rawAppend(sourceRecord, sourceListener)
	addDestroyHook(sourceRecord,  function() signalMethods.destroy(derived) end)
	addDestroyHook(derivedRecord, function() sourceConn:Disconnect() end)
	return derived
end

-- ── Operators ─────────────────────────────────────────────────────────────────

function signalMethods:map(mapper: (any) -> any): Signal<any>
	local sourceRecord = signalState[self]
	assert(sourceRecord and not sourceRecord.destroyed, "Signal.map: signal is destroyed")
	
	local derived: Signal<any>
	derived = newDerivedSignal(sourceRecord, function(payload)
		signalMethods.fire(derived, mapper(payload))
	end)
	
	return derived
end

function signalMethods:filter(predicate: (any) -> boolean): Signal<any>
	local sourceRecord = signalState[self]
	assert(sourceRecord and not sourceRecord.destroyed, "Signal.filter: signal is destroyed")
	
	local derived: Signal<any>
	derived = newDerivedSignal(sourceRecord, function(payload)
		if predicate(payload) then signalMethods.fire(derived, payload) end
	end)
	
	return derived
end

function signalMethods:scan(reducer: (any, any) -> any, seed: any): Signal<any>
	local sourceRecord = signalState[self]
	assert(sourceRecord and not sourceRecord.destroyed, "Signal.scan: signal is destroyed")
	
	local accumulator = seed
	
	local derived: Signal<any>
	derived = newDerivedSignal(sourceRecord, function(payload)
		accumulator = reducer(accumulator, payload)
		signalMethods.fire(derived, accumulator)
	end)
	
	return derived
end

function signalMethods:flatMap(selector: (any) -> any): Signal<any>
	local sourceRecord = signalState[self]
	assert(sourceRecord and not sourceRecord.destroyed, "Signal.flatMap: signal is destroyed")
	local derived         = newSignal()
	local derivedRecord   = signalState[derived] :: SignalRecord
	local innerConnections: { Connection } = {}

	local sourceConn = rawAppend(sourceRecord, function(payload)
		local innerSignal   = selector(payload)
		local innerRecord   = signalState[innerSignal]
		assert(innerRecord and not innerRecord.destroyed, "Signal.flatMap: selector returned a destroyed signal")
		local innerConn: Connection
		innerConn = rawAppend(innerRecord, function(innerPayload)
			for index, existingConn in ipairs(innerConnections) do
				if existingConn == innerConn then
					table.remove(innerConnections, index)
					break
				end
			end
			signalMethods.fire(derived, innerPayload)
		end)
		table.insert(innerConnections, innerConn)
	end)

	addDestroyHook(sourceRecord,  function() signalMethods.destroy(derived) end)
	addDestroyHook(derivedRecord, function()
		sourceConn:Disconnect()
		for _, connection in ipairs(innerConnections) do connection:Disconnect() end
		table.clear(innerConnections)
	end)
	return derived
end

function signalMethods:take(count: number): Signal<any>
	assert(count > 0, "Signal.take: count must be positive")
	
	local sourceRecord = signalState[self]
	assert(sourceRecord and not sourceRecord.destroyed, "Signal.take: signal is destroyed")
	
	local received   = 0
	
	local derived: Signal<any>
	derived = newDerivedSignal(sourceRecord, function(payload)
		received += 1
		signalMethods.fire(derived, payload)
		if received >= count then signalMethods.destroy(derived) end
	end)
	
	return derived
end

function signalMethods:skip(count: number): Signal<any>
	assert(count > 0, "Signal.skip: count must be positive")
	
	local sourceRecord = signalState[self]
	assert(sourceRecord and not sourceRecord.destroyed, "Signal.skip: signal is destroyed")
	
	local skipped    = 0
	
	local derived: Signal<any>
	derived = newDerivedSignal(sourceRecord, function(payload)
		if skipped < count then skipped += 1; return end
		signalMethods.fire(derived, payload)
	end)
	
	return derived
end

function signalMethods:takeWhile(predicate: (any) -> boolean): Signal<any>
	local sourceRecord = signalState[self]
	assert(sourceRecord and not sourceRecord.destroyed, "Signal.takeWhile: signal is destroyed")
	
	local derived: Signal<any>
	derived = newDerivedSignal(sourceRecord, function(payload)
		if predicate(payload) then
			signalMethods.fire(derived, payload)
		else
			signalMethods.destroy(derived)
		end
	end)
	
	return derived
end

function signalMethods:skipWhile(predicate: (any) -> boolean): Signal<any>
	local sourceRecord = signalState[self]
	assert(sourceRecord and not sourceRecord.destroyed, "Signal.skipWhile: signal is destroyed")
	
	local passing    = false
	
	local derived: Signal<any>
	derived = newDerivedSignal(sourceRecord, function(payload)
		if not passing and not predicate(payload) then passing = true end
		if passing then signalMethods.fire(derived, payload) end
	end)
	
	return derived
end

function signalMethods:takeUntil(stopper: any): Signal<any>
	local stopperRecord = signalState[stopper]
	assert(stopperRecord and not stopperRecord.destroyed, "Signal.takeUntil: stopper is destroyed")
	local sourceRecord = signalState[self]
	assert(sourceRecord and not sourceRecord.destroyed, "Signal.takeUntil: signal is destroyed")

	local derived         = newSignal()
	local derivedRecord   = signalState[derived] :: SignalRecord
	local sourceConn      = rawAppend(sourceRecord,  function(payload) signalMethods.fire(derived, payload) end)
	local stopperConn     = rawAppend(stopperRecord, function()        signalMethods.destroy(derived)       end)

	addDestroyHook(sourceRecord,  function() signalMethods.destroy(derived) end)
	addDestroyHook(derivedRecord, function()
		sourceConn:Disconnect()
		stopperConn:Disconnect()
	end)
	return derived
end

function signalMethods:skipUntil(stimulus: any): Signal<any>
	local stimulusRecord = signalState[stimulus]
	assert(stimulusRecord and not stimulusRecord.destroyed, "Signal.skipUntil: stimulus is destroyed")
	local sourceRecord = signalState[self]
	assert(sourceRecord and not sourceRecord.destroyed, "Signal.skipUntil: signal is destroyed")

	local derived         = newSignal()
	local derivedRecord   = signalState[derived] :: SignalRecord
	local active          = false

	local sourceConn: Connection = rawAppend(sourceRecord, function(payload)
		if active then signalMethods.fire(derived, payload) end
	end)

	local stimulusConn: Connection
	stimulusConn = rawAppend(stimulusRecord, function()
		active = true
		stimulusConn:Disconnect()
	end)

	addDestroyHook(sourceRecord,  function() signalMethods.destroy(derived) end)
	addDestroyHook(derivedRecord, function()
		sourceConn:Disconnect()
		stimulusConn:Disconnect()
	end)
	return derived
end

function signalMethods:debounce(seconds: number): Signal<any>
	assert(seconds > 0, "Signal.debounce: delay must be positive")
	local sourceRecord = signalState[self]
	assert(sourceRecord and not sourceRecord.destroyed, "Signal.debounce: signal is destroyed")

	local derived         = newSignal()
	local derivedRecord   = signalState[derived] :: SignalRecord
	local generationToken = 0
	local pendingThread: thread? = nil

	local sourceConn = rawAppend(sourceRecord, function(payload)
		generationToken += 1
		local capturedToken = generationToken
		if pendingThread then Scheduler.cancel(pendingThread) end
		pendingThread = Scheduler.delay(seconds, function()
			pendingThread = nil
			if capturedToken == generationToken then signalMethods.fire(derived, payload) end
		end)
	end)

	addDestroyHook(sourceRecord,  function() signalMethods.destroy(derived) end)
	addDestroyHook(derivedRecord, function()
		sourceConn:Disconnect()
		if pendingThread then Scheduler.cancel(pendingThread); pendingThread = nil end
	end)
	return derived
end

function signalMethods:throttle(seconds: number, options: ThrottleOptions?): Signal<any>
	assert(seconds > 0, "Signal.throttle: interval must be positive")
	local sourceRecord = signalState[self]
	assert(sourceRecord and not sourceRecord.destroyed, "Signal.throttle: signal is destroyed")

	local derived         = newSignal()
	local derivedRecord   = signalState[derived] :: SignalRecord
	local useLeading      = not (options and options.leading  == false)
	local useTrailing     = not (options and options.trailing == false)
	local lastEmitTime    = 0
	local pendingPayload: any = nil
	local trailingThread: thread? = nil

	local function emitNow(payload: any)
		trailingThread = nil
		lastEmitTime   = time()
		signalMethods.fire(derived, payload)
	end

	local sourceConn = rawAppend(sourceRecord, function(payload)
		local currentTime   = time()
		local timeSinceLast = currentTime - lastEmitTime
		if timeSinceLast >= seconds then
			if useLeading then
				lastEmitTime = currentTime
				signalMethods.fire(derived, payload)
			elseif useTrailing then
				pendingPayload = payload
				if not trailingThread then
					trailingThread = Scheduler.delay(seconds, function() emitNow(pendingPayload) end)
				end
			end
		elseif useTrailing then
			pendingPayload = payload
			if not trailingThread then
				trailingThread = Scheduler.delay(seconds - timeSinceLast, function() emitNow(pendingPayload) end)
			end
		end
	end)

	addDestroyHook(sourceRecord,  function() signalMethods.destroy(derived) end)
	addDestroyHook(derivedRecord, function()
		sourceConn:Disconnect()
		if trailingThread then Scheduler.cancel(trailingThread); trailingThread = nil end
	end)
	return derived
end

function signalMethods:delay(seconds: number): Signal<any>
	assert(seconds > 0, "Signal.delay: delay must be positive")
	local sourceRecord = signalState[self]
	assert(sourceRecord and not sourceRecord.destroyed, "Signal.delay: signal is destroyed")

	local derived         = newSignal()
	local derivedRecord   = signalState[derived] :: SignalRecord
	local activeThreads: { [thread]: true } = {}

	local sourceConn = rawAppend(sourceRecord, function(payload)
		local delayThread: thread
		delayThread = Scheduler.delay(seconds, function()
			activeThreads[delayThread] = nil
			signalMethods.fire(derived, payload)
		end)
		activeThreads[delayThread] = true
	end)

	addDestroyHook(sourceRecord,  function() signalMethods.destroy(derived) end)
	addDestroyHook(derivedRecord, function()
		sourceConn:Disconnect()
		for coroutineThread in pairs(activeThreads) do
			if coroutine.status(coroutineThread) ~= "dead" then
				Scheduler.cancel(coroutineThread)
			end
		end
		table.clear(activeThreads)
	end)
	return derived
end

function signalMethods:bufferCount(count: number, step: number?): Signal<any>
	assert(count > 0, "Signal.bufferCount: count must be positive")
	local sourceRecord = signalState[self]
	assert(sourceRecord and not sourceRecord.destroyed, "Signal.bufferCount: signal is destroyed")

	local slideSize = step or count
	assert(slideSize > 0, "Signal.bufferCount: step must be positive")

	local derived   = newSignal()
	local derivedRecord = signalState[derived] :: SignalRecord
	local buffer: { any } = {}

	local sourceConn = rawAppend(sourceRecord, function(payload)
		table.insert(buffer, payload)
		if #buffer >= count then
			local window  = table.move(buffer, 1, count, 1, {})
			local newBuff: { any } = {}
			table.move(buffer, slideSize + 1, #buffer, 1, newBuff)
			buffer = newBuff
			signalMethods.fire(derived, window)
		end
	end)

	addDestroyHook(sourceRecord,  function() signalMethods.destroy(derived) end)
	addDestroyHook(derivedRecord, function() sourceConn:Disconnect() end)
	return derived
end

function signalMethods:bufferTime(seconds: number): Signal<any>
	assert(seconds > 0, "Signal.bufferTime: interval must be positive")
	local sourceRecord = signalState[self]
	assert(sourceRecord and not sourceRecord.destroyed, "Signal.bufferTime: signal is destroyed")

	local derived        = newSignal()
	local derivedRecord  = signalState[derived] :: SignalRecord
	local buffer: { any }     = {}
	local flushThread: thread? = nil

	local function scheduleFlush()
		flushThread = Scheduler.delay(seconds, function()
			flushThread = nil
			if #buffer == 0 then return end
			local toEmit = buffer
			buffer = {}
			-- Reschedule BEFORE fire so emissions during fire accumulate cleanly.
			scheduleFlush()
			signalMethods.fire(derived, toEmit)
		end)
	end

	local sourceConn = rawAppend(sourceRecord, function(payload)
		table.insert(buffer, payload)
		if not flushThread then scheduleFlush() end
	end)

	addDestroyHook(sourceRecord,  function() signalMethods.destroy(derived) end)
	addDestroyHook(derivedRecord, function()
		sourceConn:Disconnect()
		if flushThread then Scheduler.cancel(flushThread); flushThread = nil end
	end)
	return derived
end

function signalMethods:sampleBy(sampler: any): Signal<any>
	local samplerRecord = signalState[sampler]
	assert(samplerRecord and not samplerRecord.destroyed, "Signal.sampleBy: sampler is destroyed")
	local sourceRecord = signalState[self]
	assert(sourceRecord and not sourceRecord.destroyed, "Signal.sampleBy: signal is destroyed")

	local derived       = newSignal()
	local derivedRecord = signalState[derived] :: SignalRecord
	local latestPayload: any = nil
	local hasLatest     = false

	local sourceConn  = rawAppend(sourceRecord,  function(payload) latestPayload = payload; hasLatest = true end)
	local samplerConn = rawAppend(samplerRecord, function()
		if not hasLatest then return end
		local payload    = latestPayload
		latestPayload    = nil
		hasLatest        = false
		signalMethods.fire(derived, payload)
	end)

	addDestroyHook(sourceRecord,  function() signalMethods.destroy(derived) end)
	addDestroyHook(derivedRecord, function()
		sourceConn:Disconnect()
		samplerConn:Disconnect()
	end)
	return derived
end

function signalMethods:replayCount(count: number): Signal<any>
	assert(count > 0, "Signal.replayCount: count must be positive")
	local signalRecord = signalState[self]
	assert(signalRecord and not signalRecord.destroyed, "Signal.replayCount: signal is destroyed")
	assert(not signalRecord.replay, "Signal: only one replay policy may be applied")
	signalRecord.replay = { entries = {}, policy = { count = count } }
	return self
end

function signalMethods:replayTime(seconds: number): Signal<any>
	assert(seconds > 0, "Signal.replayTime: seconds must be positive")
	local signalRecord = signalState[self]
	assert(signalRecord and not signalRecord.destroyed, "Signal.replayTime: signal is destroyed")
	assert(not signalRecord.replay, "Signal: only one replay policy may be applied")
	signalRecord.replay = { entries = {}, policy = { time = seconds } }
	return self
end

function signalMethods:clearReplays(): Signal<any>
	local signalRecord = signalState[self]
	if signalRecord and signalRecord.replay then
		table.clear(signalRecord.replay.entries)
		signalRecord.replay = nil
	end
	return self
end

-- ── Module API ─────────────────────────────────────────────────────────────────

local SignalAPI = {}

function SignalAPI.new<Payload>(): Signal<Payload>
	return newSignal()
end

-- A signal whose fire() always errors — used as a typed dead-end / placeholder.
function SignalAPI.never<Payload>(): Signal<Payload>
	return newNeverSignal()
end

-- Wraps an RBXScriptSignal. All arguments are packed into { any } as the payload.
-- Use SignalAPI.fromRoblox for a typed single-payload mapper instead.
function SignalAPI.wrapRoblox(rbxSignal: RBXScriptSignal): Signal<{ any }>
	assert(typeof(rbxSignal) == "RBXScriptSignal", "Signal.wrapRoblox: expected RBXScriptSignal")
	local derived       = newSignal()
	local derivedRecord = signalState[derived] :: SignalRecord
	local rbxConn       = rbxSignal:Connect(function(...) signalMethods.fire(derived, table.pack(...)) end)
	addDestroyHook(derivedRecord, function() rbxConn:Disconnect() end)
	return derived
end

-- Typed Roblox adapter: mapper(args...) → single typed payload.
function SignalAPI.fromRoblox<Payload>(
	rbxSignal: RBXScriptSignal,
	mapper: (...any) -> Payload
): Signal<Payload>
	assert(typeof(rbxSignal) == "RBXScriptSignal", "Signal.fromRoblox: expected RBXScriptSignal")
	local derived       = newSignal()
	local derivedRecord = signalState[derived] :: SignalRecord
	local rbxConn       = rbxSignal:Connect(function(...) signalMethods.fire(derived, mapper(...)) end)
	addDestroyHook(derivedRecord, function() rbxConn:Disconnect() end)
	return derived
end

-- Fires once after `seconds` seconds with nil payload, then self-destructs.
function SignalAPI.after(seconds: number): Signal<nil>
	assert(seconds >= 0, "Signal.after: delay must be non-negative")
	local derived       = newSignal()
	local derivedRecord = signalState[derived] :: SignalRecord
	local timerThread   = Scheduler.delay(seconds, function()
		signalMethods.fire(derived, nil :: any)
		signalMethods.destroy(derived)
	end)
	addDestroyHook(derivedRecord, function()
		if coroutine.status(timerThread) ~= "dead" then Scheduler.cancel(timerThread) end
	end)
	return derived
end

-- Fires every `seconds` seconds until destroyed.
function SignalAPI.every(seconds: number): Signal<nil>
	assert(seconds > 0, "Signal.every: interval must be positive")
	local derived       = newSignal()
	local derivedRecord = signalState[derived] :: SignalRecord
	local timerThread: thread

	local function scheduleNext()
		timerThread = Scheduler.delay(seconds, function()
			if derivedRecord.destroyed then return end
			signalMethods.fire(derived, nil :: any)
			if not derivedRecord.destroyed then scheduleNext() end
		end)
	end

	scheduleNext()
	addDestroyHook(derivedRecord, function()
		if timerThread and coroutine.status(timerThread) ~= "dead" then
			Scheduler.cancel(timerThread)
		end
	end)
	return derived
end

-- Merge: fires when any source fires. Destroyed when any source is destroyed.
function SignalAPI.merge<Payload>(signals: { Signal<Payload> }): Signal<Payload>
	local derived         = newSignal()
	local derivedRecord   = signalState[derived] :: SignalRecord
	local sourceConns: { Connection } = {}

	for _, signal in ipairs(signals) do
		local sourceRecord = signalState[signal :: any]
		assert(sourceRecord and not sourceRecord.destroyed, "Signal.merge: a source signal is destroyed")
		table.insert(sourceConns, rawAppend(sourceRecord, function(payload)
			signalMethods.fire(derived, payload)
		end))
		addDestroyHook(sourceRecord, function() signalMethods.destroy(derived) end)
	end

	addDestroyHook(derivedRecord, function()
		for _, connection in ipairs(sourceConns) do connection:Disconnect() end
		table.clear(sourceConns)
	end)
	return derived
end

function SignalAPI.mergeAll<Payload>(...: Signal<Payload>): Signal<Payload>
	return SignalAPI.merge(table.pack(...) :: any)
end

-- Zip: fires once all sources have each emitted one value this round.
-- Payload is { Payload } in source order. Resets per round.
function SignalAPI.zip(signals: { Signal<any> }): Signal<{ any }>
	local derived         = newSignal()
	local derivedRecord   = signalState[derived] :: SignalRecord
	local sourceCount     = #signals
	local roundBuffers: { any? } = table.create(sourceCount)
	local filledCount     = 0
	local sourceConns: { Connection } = {}

	for index, signal in ipairs(signals) do
		local sourceRecord = signalState[signal :: any]
		assert(sourceRecord and not sourceRecord.destroyed, "Signal.zip: a source signal is destroyed")
		local capturedIndex = index
		table.insert(sourceConns, rawAppend(sourceRecord, function(payload)
			if roundBuffers[capturedIndex] ~= nil then return end
			roundBuffers[capturedIndex] = payload
			filledCount += 1
			if filledCount == sourceCount then
				local result = table.move(roundBuffers, 1, sourceCount, 1, {})
				table.clear(roundBuffers)
				filledCount = 0
				signalMethods.fire(derived, result)
			end
		end))
		addDestroyHook(sourceRecord, function() signalMethods.destroy(derived) end)
	end

	addDestroyHook(derivedRecord, function()
		for _, connection in ipairs(sourceConns) do connection:Disconnect() end
		table.clear(sourceConns)
	end)
	return derived
end

function SignalAPI.zipAll(...: Signal<any>): Signal<{ any }>
	return SignalAPI.zip(table.pack(...) :: any)
end

-- Race: the first source to fire becomes the permanent source.
-- The winning payload is emitted once; all subsequent fires from the winner
-- flow through. Uses Scheduler.defer when attaching the follow-connection to
-- avoid the newly-appended node catching the same fire that triggered the win.
function SignalAPI.race<Payload>(signals: { Signal<Payload> }): Signal<Payload>
	local derived         = newSignal()
	local derivedRecord   = signalState[derived] :: SignalRecord
	local candidateConns: { Connection } = {}
	local decided         = false

	for _, signal in ipairs(signals) do
		local sourceRecord  = signalState[signal :: any]
		assert(sourceRecord and not sourceRecord.destroyed, "Signal.race: a source signal is destroyed")
		local capturedSignal = signal

		local candidateConn: Connection
		candidateConn = rawAppend(sourceRecord, function(payload)
			if decided then return end
			decided = true

			for _, connection in ipairs(candidateConns) do connection:Disconnect() end
			table.clear(candidateConns)

			signalMethods.fire(derived, payload)

			Scheduler.defer(function()
				if derivedRecord.destroyed then return end
				local winnerRecord = signalState[capturedSignal :: any]
				if not winnerRecord or winnerRecord.destroyed then return end
				local followConn = rawAppend(winnerRecord, function(followPayload)
					signalMethods.fire(derived, followPayload)
				end)
				addDestroyHook(derivedRecord, function() followConn:Disconnect() end)
			end)
		end)
		table.insert(candidateConns, candidateConn)
	end

	addDestroyHook(derivedRecord, function()
		for _, connection in ipairs(candidateConns) do connection:Disconnect() end
		table.clear(candidateConns)
	end)
	return derived
end

function SignalAPI.raceAll<Payload>(...: Signal<Payload>): Signal<Payload>
	return SignalAPI.race(table.pack(...) :: any)
end

-- Sequence: fires when the given signals fire in the listed order.
-- The same signal may appear multiple times for repeated-press patterns.
-- Payload: { time: number, completed: boolean }
function SignalAPI.sequence(
	signals: { Signal<any> },
	opts: SequenceOptions?
): Signal<SequencePayload>
	local derived       = newSignal()
	local derivedRecord = signalState[derived] :: SignalRecord
	local options       = opts or {} :: SequenceOptions

	local minimumTimeBetween = options.minTimeBetween or 0
	local maximumTimeBetween = options.maxTimeBetween or math.huge
	local minimumTotalTime   = options.minTotalTime   or 0
	local maximumTotalTime   = options.maxTotalTime   or math.huge
	local shouldResetOnMiss  = options.resetOnMismatch ~= false
	local shouldFireOnMiss   = options.fireOnMismatch  == true

	local totalSteps    = #signals
	local signalIndices: { [any]: { number } } = {}
	local sourceConns: { Connection } = {}

	local currentStep  = 1
	local cumulativeTime = 0.0
	local lastFireTime   = -1.0

	local function resetSequence()
		currentStep      = 1
		cumulativeTime   = 0
		lastFireTime     = -1
	end

	local function onSignalFired(firedSignal: any)
		local indices = signalIndices[firedSignal]
		if not table.find(indices, currentStep) then
			if shouldResetOnMiss then
				local elapsed = cumulativeTime
				resetSequence()
				if shouldFireOnMiss then
					signalMethods.fire(derived, { time = elapsed, completed = false } :: any)
				end
			end
			return
		end

		local currentTime    = time()
		local timeSinceLast  = if lastFireTime < 0 then 0 else currentTime - lastFireTime
		lastFireTime         = currentTime
		cumulativeTime      += timeSinceLast

		if timeSinceLast < minimumTimeBetween or timeSinceLast > maximumTimeBetween then
			local elapsed = cumulativeTime
			resetSequence()
			if shouldFireOnMiss then
				signalMethods.fire(derived, { time = elapsed, completed = false } :: any)
			end
			return
		end

		currentStep += 1
		if currentStep > totalSteps then
			local elapsed = cumulativeTime
			resetSequence()
			if elapsed >= minimumTotalTime and elapsed <= maximumTotalTime then
				signalMethods.fire(derived, { time = elapsed, completed = true } :: any)
			end
		end
	end

	for idx, signal in ipairs(signals) do
		local sourceRecord = signalState[signal :: any]
		assert(sourceRecord and not sourceRecord.destroyed, "Signal.sequence: a source signal is destroyed")
		if not signalIndices[signal] then
			signalIndices[signal] = {}
			local capturedSignal  = signal
			table.insert(sourceConns, rawAppend(sourceRecord, function()
				onSignalFired(capturedSignal)
			end))
			addDestroyHook(sourceRecord, function() signalMethods.destroy(derived) end)
		end
		table.insert(signalIndices[signal], idx)
	end

	addDestroyHook(derivedRecord, function()
		for _, connection in ipairs(sourceConns) do connection:Disconnect() end
		table.clear(sourceConns)
		table.clear(signalIndices)
	end)
	return derived
end

table.freeze(signalMethods)
return table.freeze(SignalAPI)

