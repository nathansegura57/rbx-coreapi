--!strict

local Connection = require(script.Parent.Connection)
local ErrorHandler = require(script.Parent.ErrorHandler)
local Scheduler = require(script.Parent.Scheduler)

local Signal = {}

export type CoreSignal<T> = {
	Connect: (self: CoreSignal<T>, listener: (T) -> ()) -> Connection.Connection,
	Once: (self: CoreSignal<T>, listener: (T) -> ()) -> Connection.Connection,
	Fire: (self: CoreSignal<T>, payload: T) -> (),
	Wait: (self: CoreSignal<T>) -> T,
	DisconnectAll: (self: CoreSignal<T>) -> (),
	Destroy: (self: CoreSignal<T>) -> (),
	IsDestroyed: (self: CoreSignal<T>) -> boolean,

	Filter: (self: CoreSignal<T>, predicate: (T) -> boolean) -> CoreSignal<T>,
	Take: (self: CoreSignal<T>, count: number) -> CoreSignal<T>,
	Skip: (self: CoreSignal<T>, count: number) -> CoreSignal<T>,
	TakeWhile: (self: CoreSignal<T>, predicate: (T) -> boolean) -> CoreSignal<T>,
	SkipWhile: (self: CoreSignal<T>, predicate: (T) -> boolean) -> CoreSignal<T>,
	Debounce: (self: CoreSignal<T>, seconds: number) -> CoreSignal<T>,
	Throttle: (self: CoreSignal<T>, seconds: number, opts: ThrottleOptions?) -> CoreSignal<T>,
	Delay: (self: CoreSignal<T>, seconds: number) -> CoreSignal<T>,

	ReplayCount: (self: CoreSignal<T>, count: number) -> CoreSignal<T>,
	ReplayTime: (self: CoreSignal<T>, seconds: number) -> CoreSignal<T>,
	ClearReplay: (self: CoreSignal<T>) -> CoreSignal<T>,
}

export type Signal<T> = CoreSignal<T> & {
	Map: <U>(self: Signal<T>, mapper: (T) -> U) -> CoreSignal<U>,
	Scan: <U>(self: Signal<T>, reducer: (U, T) -> U, seed: U) -> CoreSignal<U>,
	MergeMap: <U>(self: Signal<T>, mapper: (T) -> CoreSignal<U>) -> CoreSignal<U>,
	SwitchMap: <U>(self: Signal<T>, mapper: (T) -> CoreSignal<U>) -> CoreSignal<U>,
	TakeUntil: <U>(self: Signal<T>, stopper: CoreSignal<U>) -> Signal<T>,
	SkipUntil: <U>(self: Signal<T>, starter: CoreSignal<U>) -> Signal<T>,
	BufferCount: (self: Signal<T>, count: number, step: number?) -> CoreSignal<{ T } & { n: number }>,
	BufferTime: (self: Signal<T>, seconds: number) -> CoreSignal<{ T } & { n: number }>,
	SampleBy: <U>(self: Signal<T>, sampler: CoreSignal<U>) -> Signal<T>,
}

export type ThrottleOptions = {
	Leading: boolean?,
	Trailing: boolean?,
}

export type SequenceOptions = {
	MinTimeBetween: number?,
	MaxTimeBetween: number?,
	MinTotalTime: number?,
	MaxTotalTime: number?,
	ResetOnMismatch: boolean?,
	FireOnMismatch: boolean?,
}

export type SequenceResult = {
	Time: number,
	Completed: boolean,
}

-- Internal types

type ListenerEntry = {
	Connected: boolean,
	Fn: (any) -> (),
}

type WaiterEntry = {
	Thread: thread,
}

type ReplayEntry = {
	HasValue: boolean,
	Value: any,
	Timestamp: number,
}

type SignalRecord = {
	Destroyed: boolean,
	IsNever: boolean,
	Listeners: { ListenerEntry },
	FireDepth: number,
	Waiters: { WaiterEntry },
	ReplayPolicy: "Count" | "Time" | nil,
	ReplayCountLimit: number,
	ReplayTimeWindow: number,
	ReplayBuffer: { ReplayEntry },
	CleanupFns: { () -> () },
	TimerHandles: { any },
}

local records: { [any]: SignalRecord } = setmetatable({}, { __mode = "k" }) :: any

local function trimReplayTime(record: SignalRecord): ()
	local now = Scheduler.Now()
	local window = record.ReplayTimeWindow
	local buf = record.ReplayBuffer
	local i = 1
	while i <= #buf do
		if now - buf[i].Timestamp > window then
			table.remove(buf, i)
		else
			i += 1
		end
	end
end

local function storeReplay(record: SignalRecord, value: any): ()
	local policy = record.ReplayPolicy
	if policy == nil then return end
	local entry: ReplayEntry = { HasValue = true, Value = value, Timestamp = Scheduler.Now() }
	if policy == "Count" then
		local buf = record.ReplayBuffer
		table.insert(buf, entry)
		while #buf > record.ReplayCountLimit do
			table.remove(buf, 1)
		end
	elseif policy == "Time" then
		table.insert(record.ReplayBuffer, entry)
		trimReplayTime(record)
	end
end

local function compactListeners(record: SignalRecord): ()
	if record.FireDepth > 0 then return end
	local keep: { ListenerEntry } = {}
	for _, e in record.Listeners do
		if e.Connected then
			table.insert(keep, e)
		end
	end
	record.Listeners = keep
end

local function makeConn(record: SignalRecord, entry: ListenerEntry): Connection.Connection
	return Connection.New(function()
		entry.Connected = false
		compactListeners(record)
	end)
end

local function scheduleReplay(record: SignalRecord, entry: ListenerEntry): ()
	local policy = record.ReplayPolicy
	if policy == nil then return end
	if policy == "Time" then
		trimReplayTime(record)
	end
	for _, re in record.ReplayBuffer do
		local v = re.Value
		Scheduler.Defer(function()
			if entry.Connected then
				ErrorHandler.Protect(function() entry.Fn(v) end, "Signal", "Listener")
			end
		end)
	end
end

-- Handle model

local signalMethods: { [string]: any } = {}

local handleMeta = {
	__index = function(_self: any, key: string): any
		return signalMethods[key]
	end,
	__newindex = function(_self: any, key: string, _value: any): ()
		error(`Signal: '{tostring(key)}' is read-only`)
	end,
	__metatable = "Signal",
}

local function newHandle(isNever: boolean): any
	local h: any = setmetatable({}, handleMeta)
	records[h] = {
		Destroyed = false,
		IsNever = isNever,
		Listeners = {},
		FireDepth = 0,
		Waiters = {},
		ReplayPolicy = nil,
		ReplayCountLimit = 0,
		ReplayTimeWindow = 0,
		ReplayBuffer = {},
		CleanupFns = {},
		TimerHandles = {},
	}
	return h
end

-- Subscribes fn to source; registers source-destroy→destroy-derived and derived-destroy→disconnect.
local function connectDerived(source: any, derived: any, fn: (any) -> ()): ListenerEntry
	local sr = records[source] :: SignalRecord
	local dr = records[derived] :: SignalRecord
	local entry: ListenerEntry = { Connected = true, Fn = fn }
	table.insert(sr.Listeners, entry)
	table.insert(sr.CleanupFns, function()
		if not dr.Destroyed then
			signalMethods.Destroy(derived)
		end
	end)
	table.insert(dr.CleanupFns, function()
		entry.Connected = false
		compactListeners(sr)
	end)
	return entry
end

-- Constructors

function Signal.New<T>(): Signal<T>
	return newHandle(false)
end

function Signal.Never<T>(): Signal<T>
	return newHandle(true)
end

function Signal.After(seconds: number): Signal<nil>
	if type(seconds) ~= "number" or not (seconds >= 0) then
		error("Signal.After: seconds must be non-negative")
	end
	local h = newHandle(false)
	local rec = records[h] :: SignalRecord
	local timerHandle: any = Scheduler.Delay(seconds, function()
		local r = records[h] :: SignalRecord?
		if r == nil or r.Destroyed then return end
		signalMethods.Fire(h, nil)
		signalMethods.Destroy(h)
	end)
	table.insert(rec.TimerHandles, timerHandle)
	return h
end

function Signal.Every(seconds: number): Signal<nil>
	if type(seconds) ~= "number" or not (seconds > 0) then
		error("Signal.Every: seconds must be positive")
	end
	local h = newHandle(false)
	local rec = records[h] :: SignalRecord

	local function scheduleTick(): ()
		local th: any = Scheduler.Delay(seconds, function()
			local r = records[h] :: SignalRecord?
			if r == nil or r.Destroyed then return end
			signalMethods.Fire(h, nil)
			if not r.Destroyed then
				table.clear(r.TimerHandles)
				scheduleTick()
			end
		end)
		table.clear(rec.TimerHandles)
		table.insert(rec.TimerHandles, th)
	end

	scheduleTick()
	return h
end

function Signal.FromRoblox(rbxSignal: RBXScriptSignal, mapper: ((...any) -> any)?): Signal<any>
	if typeof(rbxSignal) ~= "RBXScriptSignal" then
		error("Signal.FromRoblox: expected RBXScriptSignal")
	end
	if mapper ~= nil and type(mapper) ~= "function" then
		error("Signal.FromRoblox: mapper must be a function or nil")
	end
	local h = newHandle(false)
	local rec = records[h] :: SignalRecord
	local rbxConn = (rbxSignal :: any):Connect(function(...)
		local r = records[h] :: SignalRecord?
		if r == nil or r.Destroyed then return end
		local payload: any = table.pack(...)
		if mapper ~= nil then
			local ok, result = ErrorHandler.Protect(function() return mapper(table.unpack(payload, 1, payload.n)) end, "Signal", "FromRoblox")
			if not ok then return end
			payload = result
		end
		signalMethods.Fire(h, payload)
	end)
	table.insert(rec.CleanupFns, function()
		rbxConn:Disconnect()
	end)
	return h
end

Signal.ReplayPolicy = table.freeze({
	Count = "Count" :: "Count",
	Time = "Time" :: "Time",
})

function Signal.IsSignal(value: unknown): boolean
	if type(value) ~= "table" then return false end
	return records[value :: any] ~= nil
end

-- Instance methods

function signalMethods:Connect(listener: (any) -> ()): Connection.Connection
	local rec: SignalRecord? = records[self :: any]
	if rec == nil or rec.Destroyed then
		error("Signal.Connect: signal is destroyed")
	end
	if type(listener) ~= "function" then
		error("Signal.Connect: listener must be a function")
	end
	local entry: ListenerEntry = { Connected = true, Fn = listener }
	table.insert(rec.Listeners, entry)
	local conn = makeConn(rec, entry)
	scheduleReplay(rec, entry)
	return conn
end

function signalMethods:Once(listener: (any) -> ()): Connection.Connection
	local rec: SignalRecord? = records[self :: any]
	if rec == nil or rec.Destroyed then
		error("Signal.Once: signal is destroyed")
	end
	if type(listener) ~= "function" then
		error("Signal.Once: listener must be a function")
	end
	local r = rec :: SignalRecord
	local entry: ListenerEntry
	entry = {
		Connected = true,
		Fn = function(payload: any): ()
			if not entry.Connected then return end
			entry.Connected = false
			compactListeners(r)
			listener(payload)
		end,
	}
	table.insert(r.Listeners, entry)
	local conn = makeConn(r, entry)
	scheduleReplay(r, entry)
	return conn
end

function signalMethods:Fire(payload: any): ()
	local rec: SignalRecord? = records[self :: any]
	if rec == nil or rec.Destroyed then return end
	if rec.IsNever then
		error("Signal.Fire: cannot fire a never signal")
	end
	storeReplay(rec, payload)
	rec.FireDepth += 1
	local listeners = rec.Listeners
	local count = #listeners
	for i = 1, count do
		local e = listeners[i]
		if e.Connected then
			ErrorHandler.Protect(function() e.Fn(payload) end, "Signal", "Listener")
		end
	end
	rec.FireDepth -= 1
	if rec.FireDepth == 0 then
		compactListeners(rec)
	end
end

function signalMethods:Wait(): any
	local rec: SignalRecord? = records[self :: any]
	if rec == nil or rec.Destroyed then
		error("Signal.Wait: signal is destroyed")
	end
	if not coroutine.isyieldable() then
		error("Signal.Wait: must be called from a yieldable coroutine")
	end
	local thread = coroutine.running() :: thread
	local r = rec :: SignalRecord
	local waiter: WaiterEntry = { Thread = thread }
	table.insert(r.Waiters, waiter)
	local entry: ListenerEntry
	entry = {
		Connected = true,
		Fn = function(payload: any): ()
			if not entry.Connected then return end
			entry.Connected = false
			for i = 1, #r.Waiters do
				if r.Waiters[i] == waiter then
					table.remove(r.Waiters, i)
					break
				end
			end
			Scheduler.Defer(function()
				coroutine.resume(thread, true, payload)
			end)
		end,
	}
	table.insert(r.Listeners, entry)
	local ok, value = coroutine.yield()
	if not ok then
		error("Signal.Wait: signal destroyed")
	end
	return value
end

function signalMethods:DisconnectAll(): ()
	local rec: SignalRecord? = records[self :: any]
	if rec == nil then return end
	for _, e in rec.Listeners do
		e.Connected = false
	end
	if rec.FireDepth == 0 then
		table.clear(rec.Listeners)
	end
end

function signalMethods:Destroy(): ()
	local rec: SignalRecord? = records[self :: any]
	if rec == nil or rec.Destroyed then return end
	rec.Destroyed = true
	for _, e in rec.Listeners do
		e.Connected = false
	end
	table.clear(rec.Listeners)
	local waiters = table.clone(rec.Waiters)
	table.clear(rec.Waiters)
	for _, w in waiters do
		local t = w.Thread
		Scheduler.Defer(function()
			coroutine.resume(t, false, nil)
		end)
	end
	table.clear(rec.ReplayBuffer)
	rec.ReplayPolicy = nil
	for _, th in rec.TimerHandles do
		Scheduler.Cancel(th)
	end
	table.clear(rec.TimerHandles)
	local cleanups = table.clone(rec.CleanupFns)
	table.clear(rec.CleanupFns)
	for _, fn in cleanups do
		ErrorHandler.Protect(fn, "Signal", "Cleanup")
	end
end

function signalMethods:IsDestroyed(): boolean
	local rec: SignalRecord? = records[self :: any]
	if rec == nil then return true end
	return rec.Destroyed
end

-- Operators

function signalMethods:Map(mapper: (any) -> any): any
	if type(mapper) ~= "function" then
		error("Signal.Map: mapper must be a function")
	end
	local derived = Signal.New()
	local dr = records[derived] :: SignalRecord
	connectDerived(self, derived, function(payload: any): ()
		if dr.Destroyed then return end
		local ok, result = ErrorHandler.Protect(function() return mapper(payload) end, "Signal", "Map")
		if not ok then return end
		signalMethods.Fire(derived, result)
	end)
	return derived
end

function signalMethods:Filter(predicate: (any) -> boolean): any
	if type(predicate) ~= "function" then
		error("Signal.Filter: predicate must be a function")
	end
	local derived = Signal.New()
	local dr = records[derived] :: SignalRecord
	connectDerived(self, derived, function(payload: any): ()
		if dr.Destroyed then return end
		local ok, result = ErrorHandler.Protect(function() return predicate(payload) end, "Signal", "Filter")
		if not ok then return end
		if result == true then
			signalMethods.Fire(derived, payload)
		end
	end)
	return derived
end

function signalMethods:Scan(reducer: (any, any) -> any, seed: any): any
	if type(reducer) ~= "function" then
		error("Signal.Scan: reducer must be a function")
	end
	local derived = Signal.New()
	local dr = records[derived] :: SignalRecord
	local acc = seed
	connectDerived(self, derived, function(payload: any): ()
		if dr.Destroyed then return end
		local ok, result = ErrorHandler.Protect(function() return reducer(acc, payload) end, "Signal", "Scan")
		if not ok then return end
		acc = result
		signalMethods.Fire(derived, acc)
	end)
	return derived
end

function signalMethods:MergeMap(selector: (any) -> any): any
	if type(selector) ~= "function" then
		error("Signal.MergeMap: selector must be a function")
	end
	local derived = Signal.New()
	local dr = records[derived] :: SignalRecord
	local innerEntries: { ListenerEntry } = {}
	connectDerived(self, derived, function(payload: any): ()
		if dr.Destroyed then return end
		local ok, inner = ErrorHandler.Protect(function() return selector(payload) end, "Signal", "MergeMap")
		if not ok then return end
		if not Signal.IsSignal(inner) then
			error("Signal.MergeMap: selector must return a Signal")
		end
		local ir = records[inner :: any] :: SignalRecord
		local innerEntry: ListenerEntry = {
			Connected = true,
			Fn = function(p: any): ()
				if not dr.Destroyed then
					signalMethods.Fire(derived, p)
				end
			end,
		}
		table.insert(ir.Listeners, innerEntry)
		table.insert(innerEntries, innerEntry)
		table.insert(ir.CleanupFns, function()
			innerEntry.Connected = false
		end)
	end)
	table.insert((records[derived] :: SignalRecord).CleanupFns, function()
		for _, e in innerEntries do
			e.Connected = false
		end
		table.clear(innerEntries)
	end)
	return derived
end

function signalMethods:SwitchMap(selector: (any) -> any): any
	if type(selector) ~= "function" then
		error("Signal.SwitchMap: selector must be a function")
	end
	local derived = Signal.New()
	local dr = records[derived] :: SignalRecord
	local currentEntry: ListenerEntry? = nil
	connectDerived(self, derived, function(payload: any): ()
		if dr.Destroyed then return end
		local ok, inner = ErrorHandler.Protect(function() return selector(payload) end, "Signal", "SwitchMap")
		if not ok then return end
		if not Signal.IsSignal(inner) then
			error("Signal.SwitchMap: selector must return a Signal")
		end
		if currentEntry ~= nil then
			currentEntry.Connected = false
		end
		local ir = records[inner :: any] :: SignalRecord
		local entry: ListenerEntry = {
			Connected = true,
			Fn = function(p: any): ()
				if not dr.Destroyed then
					signalMethods.Fire(derived, p)
				end
			end,
		}
		currentEntry = entry
		table.insert(ir.Listeners, entry)
		table.insert(ir.CleanupFns, function()
			if currentEntry == entry then
				currentEntry = nil
			end
			entry.Connected = false
		end)
	end)
	table.insert(dr.CleanupFns, function()
		if currentEntry ~= nil then
			currentEntry.Connected = false
			currentEntry = nil
		end
	end)
	return derived
end

function signalMethods:Take(count: number): any
	if type(count) ~= "number" or count < 1 or count ~= math.floor(count) then
		error("Signal.Take: count must be a positive integer")
	end
	local derived = Signal.New()
	local dr = records[derived] :: SignalRecord
	local seen = 0
	connectDerived(self, derived, function(payload: any): ()
		if dr.Destroyed then return end
		seen += 1
		signalMethods.Fire(derived, payload)
		if seen >= count then
			signalMethods.Destroy(derived)
		end
	end)
	return derived
end

function signalMethods:Skip(count: number): any
	if type(count) ~= "number" or count < 0 or count ~= math.floor(count) then
		error("Signal.Skip: count must be a non-negative integer")
	end
	local derived = Signal.New()
	local dr = records[derived] :: SignalRecord
	local skipped = 0
	connectDerived(self, derived, function(payload: any): ()
		if dr.Destroyed then return end
		if skipped < count then
			skipped += 1
			return
		end
		signalMethods.Fire(derived, payload)
	end)
	return derived
end

function signalMethods:TakeWhile(predicate: (any) -> boolean): any
	if type(predicate) ~= "function" then
		error("Signal.TakeWhile: predicate must be a function")
	end
	local derived = Signal.New()
	local dr = records[derived] :: SignalRecord
	connectDerived(self, derived, function(payload: any): ()
		if dr.Destroyed then return end
		local ok, result = ErrorHandler.Protect(function() return predicate(payload) end, "Signal", "TakeWhile")
		if not ok then
			signalMethods.Destroy(derived)
			return
		end
		if result == true then
			signalMethods.Fire(derived, payload)
		else
			signalMethods.Destroy(derived)
		end
	end)
	return derived
end

function signalMethods:SkipWhile(predicate: (any) -> boolean): any
	if type(predicate) ~= "function" then
		error("Signal.SkipWhile: predicate must be a function")
	end
	local derived = Signal.New()
	local dr = records[derived] :: SignalRecord
	local skipping = true
	connectDerived(self, derived, function(payload: any): ()
		if dr.Destroyed then return end
		if not skipping then
			signalMethods.Fire(derived, payload)
			return
		end
		local ok, result = ErrorHandler.Protect(function() return predicate(payload) end, "Signal", "SkipWhile")
		if not ok then
			skipping = false
			signalMethods.Fire(derived, payload)
			return
		end
		if result ~= true then
			skipping = false
			signalMethods.Fire(derived, payload)
		end
	end)
	return derived
end

function signalMethods:TakeUntil(stopper: any): any
	if not Signal.IsSignal(stopper) or (records[stopper] :: SignalRecord).Destroyed then
		error("Signal.TakeUntil: stopper must be a live Signal")
	end
	local derived = Signal.New()
	local dr = records[derived] :: SignalRecord
	local sr = records[stopper] :: SignalRecord
	connectDerived(self, derived, function(payload: any): ()
		if not dr.Destroyed then
			signalMethods.Fire(derived, payload)
		end
	end)
	local stopEntry: ListenerEntry = {
		Connected = true,
		Fn = function(_: any): ()
			if not dr.Destroyed then
				signalMethods.Destroy(derived)
			end
		end,
	}
	table.insert(sr.Listeners, stopEntry)
	table.insert(sr.CleanupFns, function()
		if not dr.Destroyed then
			signalMethods.Destroy(derived)
		end
	end)
	table.insert(dr.CleanupFns, function()
		stopEntry.Connected = false
		compactListeners(sr)
	end)
	return derived
end

function signalMethods:SkipUntil(starter: any): any
	if not Signal.IsSignal(starter) or (records[starter] :: SignalRecord).Destroyed then
		error("Signal.SkipUntil: starter must be a live Signal")
	end
	local derived = Signal.New()
	local dr = records[derived] :: SignalRecord
	local stR = records[starter] :: SignalRecord
	local started = false
	local startEntry: ListenerEntry
	startEntry = {
		Connected = true,
		Fn = function(_: any): ()
			if not started then
				started = true
				startEntry.Connected = false
			end
		end,
	}
	table.insert(stR.Listeners, startEntry)
	connectDerived(self, derived, function(payload: any): ()
		if not dr.Destroyed and started then
			signalMethods.Fire(derived, payload)
		end
	end)
	table.insert(dr.CleanupFns, function()
		startEntry.Connected = false
	end)
	return derived
end

function signalMethods:Debounce(seconds: number): any
	if type(seconds) ~= "number" or not (seconds >= 0) then
		error("Signal.Debounce: seconds must be non-negative")
	end
	local derived = Signal.New()
	local dr = records[derived] :: SignalRecord
	local pendingHandle: any = nil
	local pendingValue: any = nil
	local pendingHas = false
	connectDerived(self, derived, function(payload: any): ()
		if dr.Destroyed then return end
		if pendingHandle ~= nil then
			Scheduler.Cancel(pendingHandle)
		end
		pendingHas = true
		pendingValue = payload
		pendingHandle = Scheduler.Delay(seconds, function()
			pendingHandle = nil
			if not dr.Destroyed and pendingHas then
				local v = pendingValue
				pendingHas = false
				pendingValue = nil
				signalMethods.Fire(derived, v)
			end
		end)
	end)
	table.insert(dr.CleanupFns, function()
		if pendingHandle ~= nil then
			Scheduler.Cancel(pendingHandle)
			pendingHandle = nil
		end
	end)
	return derived
end

function signalMethods:Throttle(seconds: number, opts: ThrottleOptions?): any
	if type(seconds) ~= "number" or not (seconds > 0) then
		error("Signal.Throttle: seconds must be positive")
	end
	local leading = true
	local trailing = true
	if opts ~= nil then
		if type(opts) ~= "table" then
			error("Signal.Throttle: opts must be a table or nil")
		end
		local raw: any = opts
		if raw.Leading ~= nil then
			if type(raw.Leading) ~= "boolean" then
				error("Signal.Throttle: Leading must be a boolean or nil")
			end
			leading = raw.Leading
		end
		if raw.Trailing ~= nil then
			if type(raw.Trailing) ~= "boolean" then
				error("Signal.Throttle: Trailing must be a boolean or nil")
			end
			trailing = raw.Trailing
		end
	end
	local derived = Signal.New()
	local dr = records[derived] :: SignalRecord
	local windowOpen = false
	local pendingHas = false
	local pendingValue: any = nil
	local timerHandle: any = nil
	local function openWindow(): ()
		windowOpen = true
		timerHandle = Scheduler.Delay(seconds, function()
			timerHandle = nil
			windowOpen = false
			if pendingHas then
				local v = pendingValue
				pendingHas = false
				pendingValue = nil
				if not dr.Destroyed then
					signalMethods.Fire(derived, v)
				end
			end
		end)
	end
	connectDerived(self, derived, function(payload: any): ()
		if dr.Destroyed then return end
		if not windowOpen then
			if leading then
				signalMethods.Fire(derived, payload)
			elseif trailing then
				pendingHas = true
				pendingValue = payload
			end
			openWindow()
		else
			if trailing then
				pendingHas = true
				pendingValue = payload
			end
		end
	end)
	table.insert(dr.CleanupFns, function()
		if timerHandle ~= nil then
			Scheduler.Cancel(timerHandle)
			timerHandle = nil
		end
	end)
	return derived
end

function signalMethods:Delay(seconds: number): any
	if type(seconds) ~= "number" or not (seconds >= 0) then
		error("Signal.Delay: seconds must be non-negative")
	end
	local derived = Signal.New()
	local dr = records[derived] :: SignalRecord
	local pending: { any } = {}
	connectDerived(self, derived, function(payload: any): ()
		if dr.Destroyed then return end
		local h: any
		h = Scheduler.Delay(seconds, function()
			for i = 1, #pending do
				if pending[i] == h then
					table.remove(pending, i)
					break
				end
			end
			if not dr.Destroyed then
				signalMethods.Fire(derived, payload)
			end
		end)
		table.insert(pending, h)
	end)
	table.insert(dr.CleanupFns, function()
		for _, h in pending do
			Scheduler.Cancel(h)
		end
		table.clear(pending)
	end)
	return derived
end

function signalMethods:BufferCount(count: number, step: number?): any
	if type(count) ~= "number" or count < 1 or count ~= math.floor(count) then
		error("Signal.BufferCount: count must be a positive integer")
	end
	local actualStep = count
	if step ~= nil then
		if type(step) ~= "number" or step < 1 or step ~= math.floor(step) then
			error("Signal.BufferCount: step must be a positive integer")
		end
		actualStep = step
	end
	local derived = Signal.New()
	local dr = records[derived] :: SignalRecord
	-- Presence-aware entries so nil payloads are preserved in the buffer.
	type BufEntry = { Value: any }
	local buf: { BufEntry } = {}
	connectDerived(self, derived, function(payload: any): ()
		if dr.Destroyed then return end
		table.insert(buf, { Value = payload })
		if #buf >= count then
			local arr: { any } = table.create(count)
			for i = 1, count do
				arr[i] = buf[i].Value
			end
			(arr :: any).n = count
			for _ = 1, actualStep do
				if #buf > 0 then
					table.remove(buf, 1)
				end
			end
			signalMethods.Fire(derived, arr)
		end
	end)
	return derived
end

function signalMethods:BufferTime(seconds: number): any
	if type(seconds) ~= "number" or not (seconds > 0) then
		error("Signal.BufferTime: seconds must be positive")
	end
	local derived = Signal.New()
	local dr = records[derived] :: SignalRecord
	-- Presence-aware entries so nil payloads are preserved.
	type BufEntry = { Value: any }
	local buf: { BufEntry } = {}
	local timerHandle: any = nil
	local function flush(): ()
		timerHandle = nil
		if #buf == 0 then return end
		local n = #buf
		local arr: { any } = table.create(n)
		for i = 1, n do
			arr[i] = buf[i].Value
		end
		(arr :: any).n = n
		table.clear(buf)
		if not dr.Destroyed then
			signalMethods.Fire(derived, arr)
		end
	end
	connectDerived(self, derived, function(payload: any): ()
		if dr.Destroyed then return end
		table.insert(buf, { Value = payload })
		if timerHandle == nil then
			timerHandle = Scheduler.Delay(seconds, flush)
		end
	end)
	table.insert(dr.CleanupFns, function()
		if timerHandle ~= nil then
			Scheduler.Cancel(timerHandle)
			timerHandle = nil
		end
	end)
	return derived
end

function signalMethods:SampleBy(sampler: any): any
	if not Signal.IsSignal(sampler) or (records[sampler] :: SignalRecord).Destroyed then
		error("Signal.SampleBy: sampler must be a live Signal")
	end
	local derived = Signal.New()
	local dr = records[derived] :: SignalRecord
	local sampR = records[sampler] :: SignalRecord
	local latestHas = false
	local latestValue: any = nil
	connectDerived(self, derived, function(payload: any): ()
		latestHas = true
		latestValue = payload
	end)
	local sampEntry: ListenerEntry = {
		Connected = true,
		Fn = function(_: any): ()
			if not dr.Destroyed and latestHas then
				local v = latestValue
				latestHas = false
				latestValue = nil
				signalMethods.Fire(derived, v)
			end
		end,
	}
	table.insert(sampR.Listeners, sampEntry)
	table.insert(sampR.CleanupFns, function()
		if not dr.Destroyed then
			signalMethods.Destroy(derived)
		end
	end)
	table.insert(dr.CleanupFns, function()
		sampEntry.Connected = false
		compactListeners(sampR)
	end)
	return derived
end

function signalMethods:ReplayCount(count: number): any
	if type(count) ~= "number" or count < 1 or count ~= math.floor(count) then
		error("Signal.ReplayCount: count must be a positive integer")
	end
	local rec: SignalRecord? = records[self :: any]
	if rec == nil or rec.Destroyed then error("Signal.ReplayCount: signal is destroyed") end
	local r = rec :: SignalRecord
	if r.ReplayPolicy ~= nil then
		error("Signal: only one replay policy may be applied")
	end
	r.ReplayPolicy = "Count"
	r.ReplayCountLimit = count
	return self
end

function signalMethods:ReplayTime(seconds: number): any
	if type(seconds) ~= "number" or not (seconds > 0) then
		error("Signal.ReplayTime: seconds must be positive")
	end
	local rec: SignalRecord? = records[self :: any]
	if rec == nil or rec.Destroyed then error("Signal.ReplayTime: signal is destroyed") end
	local r = rec :: SignalRecord
	if r.ReplayPolicy ~= nil then
		error("Signal: only one replay policy may be applied")
	end
	r.ReplayPolicy = "Time"
	r.ReplayTimeWindow = seconds
	return self
end

function signalMethods:ClearReplay(): any
	local rec: SignalRecord? = records[self :: any]
	if rec == nil or rec.Destroyed then return self end
	local r = rec :: SignalRecord
	if r.ReplayPolicy == nil then return self end
	r.ReplayPolicy = nil
	r.ReplayCountLimit = 0
	r.ReplayTimeWindow = 0
	table.clear(r.ReplayBuffer)
	return self
end

-- Static combinators

function Signal.Merge<T>(signals: { CoreSignal<T> }): Signal<T>
	if type(signals) ~= "table" or #signals == 0 then
		error("Signal.Merge: signals must be a non-empty dense array of Signals")
	end
	for i = 1, #signals do
		if not Signal.IsSignal(signals[i]) or (records[signals[i] :: any] :: SignalRecord).Destroyed then
			error("Signal.Merge: signals must be a non-empty dense array of Signals")
		end
	end
	local derived: Signal<T> = Signal.New()
	local dr = records[derived :: any] :: SignalRecord
	for _, src in signals do
		connectDerived(src :: any, derived :: any, function(payload: any): ()
			if not dr.Destroyed then
				signalMethods.Fire(derived :: any, payload)
			end
		end)
	end
	return derived
end

function Signal.Zip<T>(signals: { CoreSignal<T> }): Signal<{ T }>
	if type(signals) ~= "table" or #signals == 0 then
		error("Signal.Zip: signals must be a non-empty dense array of Signals")
	end
	for i = 1, #signals do
		if not Signal.IsSignal(signals[i]) or (records[signals[i] :: any] :: SignalRecord).Destroyed then
			error("Signal.Zip: signals must be a non-empty dense array of Signals")
		end
	end
	local n = #signals
	local derived: Signal<{ T }> = Signal.New()
	local dr = records[derived :: any] :: SignalRecord
	local filled: { boolean } = table.create(n, false)
	local vals: { T } = table.create(n)
	for idx, src in signals do
		local i = idx
		connectDerived(src :: any, derived :: any, function(payload: any): ()
			if dr.Destroyed then return end
			if filled[i] then return end
			filled[i] = true
			vals[i] = payload
			local allFilled = true
			for j = 1, n do
				if not filled[j] then
					allFilled = false
					break
				end
			end
			if allFilled then
				local arr: { T } = table.create(n)
				for j = 1, n do
					arr[j] = vals[j]
				end
				(arr :: any).n = n
				for j = 1, n do
					filled[j] = false
					vals[j] = nil :: any
				end
				signalMethods.Fire(derived :: any, arr)
			end
		end)
	end
	return derived
end

function Signal.Race<T>(signals: { CoreSignal<T> }): Signal<T>
	if type(signals) ~= "table" or #signals == 0 then
		error("Signal.Race: signals must be a non-empty dense array of Signals")
	end
	for i = 1, #signals do
		if not Signal.IsSignal(signals[i]) or (records[signals[i] :: any] :: SignalRecord).Destroyed then
			error("Signal.Race: signals must be a non-empty dense array of Signals")
		end
	end
	local derived: Signal<T> = Signal.New()
	local dr = records[derived :: any] :: SignalRecord
	local winner: CoreSignal<T>? = nil
	type EntryPair = { entry: ListenerEntry, source: CoreSignal<T> }
	local pairs: { EntryPair } = {}
	for _, src in signals do
		local s = src
		local entry: ListenerEntry
		entry = {
			Connected = true,
			Fn = function(payload: any): ()
				if dr.Destroyed then return end
				if winner == nil then
					winner = s
					for _, p in pairs do
						if p.source ~= s then
							p.entry.Connected = false
						end
					end
				end
				if winner == s then
					signalMethods.Fire(derived :: any, payload)
				end
			end,
		}
		local sr = records[s :: any] :: SignalRecord
		table.insert(sr.Listeners, entry)
		table.insert(pairs, { entry = entry, source = s })
		table.insert(sr.CleanupFns, function()
			if not dr.Destroyed and (winner == nil or winner == s) then
				signalMethods.Destroy(derived :: any)
			end
		end)
	end
	table.insert(dr.CleanupFns, function()
		for _, p in pairs do
			p.entry.Connected = false
		end
		table.clear(pairs)
	end)
	return derived
end

function Signal.Sequence<T>(signals: { CoreSignal<T> }, opts: SequenceOptions?): Signal<SequenceResult>
	if type(signals) ~= "table" or #signals == 0 then
		error("Signal.Sequence: signals must be a non-empty dense array of Signals")
	end
	for i = 1, #signals do
		if not Signal.IsSignal(signals[i]) or (records[signals[i] :: any] :: SignalRecord).Destroyed then
			error("Signal.Sequence: signals must be a non-empty dense array of Signals")
		end
	end
	local minBetween = 0
	local maxBetween = math.huge
	local minTotal = 0
	local maxTotal = math.huge
	local resetOnMismatch = true
	local fireOnMismatch = false
	if opts ~= nil then
		if type(opts) ~= "table" then
			error("Signal.Sequence: opts must be a table or nil")
		end
		local raw: SequenceOptions = opts
		if raw.MinTimeBetween ~= nil then
			if type(raw.MinTimeBetween) ~= "number" or raw.MinTimeBetween < 0 then
				error("Signal.Sequence: timing options must be non-negative")
			end
			minBetween = raw.MinTimeBetween
		end
		if raw.MaxTimeBetween ~= nil then
			if type(raw.MaxTimeBetween) ~= "number" or raw.MaxTimeBetween < 0 then
				error("Signal.Sequence: timing options must be non-negative")
			end
			maxBetween = raw.MaxTimeBetween
		end
		if raw.MinTotalTime ~= nil then
			if type(raw.MinTotalTime) ~= "number" or raw.MinTotalTime < 0 then
				error("Signal.Sequence: timing options must be non-negative")
			end
			minTotal = raw.MinTotalTime
		end
		if raw.MaxTotalTime ~= nil then
			if type(raw.MaxTotalTime) ~= "number" or raw.MaxTotalTime < 0 then
				error("Signal.Sequence: timing options must be non-negative")
			end
			maxTotal = raw.MaxTotalTime
		end
		if raw.ResetOnMismatch ~= nil then
			if type(raw.ResetOnMismatch) ~= "boolean" then
				error("Signal.Sequence: ResetOnMismatch must be a boolean or nil")
			end
			resetOnMismatch = raw.ResetOnMismatch
		end
		if raw.FireOnMismatch ~= nil then
			if type(raw.FireOnMismatch) ~= "boolean" then
				error("Signal.Sequence: FireOnMismatch must be a boolean or nil")
			end
			fireOnMismatch = raw.FireOnMismatch
		end
		if maxBetween < minBetween then
			error("Signal.Sequence: MaxTimeBetween must be >= MinTimeBetween")
		end
		if maxTotal < minTotal then
			error("Signal.Sequence: MaxTotalTime must be >= MinTotalTime")
		end
	end
	local derived: Signal<SequenceResult> = Signal.New()
	local dr = records[derived :: any] :: SignalRecord
	local step = 0
	local startTime = 0
	local lastStepTime = 0
	local seqLen = #signals
	local function resetState(): ()
		step = 0
		startTime = 0
		lastStepTime = 0
	end
	local seen: { [CoreSignal<T>]: boolean } = {}
	for _, src in signals do
		if not seen[src] then
			seen[src] = true
			connectDerived(src :: any, derived :: any, function(_payload: any): ()
				if dr.Destroyed then return end
				local now = Scheduler.Now()
				local expected = signals[step + 1]
				if src ~= expected then
					local elapsed = if step > 0 then now - startTime else 0
					if fireOnMismatch then
						signalMethods.Fire(derived :: any, { Time = elapsed, Completed = false })
					end
					if resetOnMismatch then
						resetState()
					end
					return
				end
				if step > 0 then
					local dt = now - lastStepTime
					if dt < minBetween or dt > maxBetween then
						local elapsed = now - startTime
						if fireOnMismatch then
							signalMethods.Fire(derived :: any, { Time = elapsed, Completed = false })
						end
						if resetOnMismatch then
							resetState()
						end
						return
					end
				end
				if step == 0 then
					startTime = now
				end
				lastStepTime = now
				step += 1
				local elapsed = now - startTime
				if elapsed > maxTotal then
					if fireOnMismatch then
						signalMethods.Fire(derived :: any, { Time = elapsed, Completed = false })
					end
					if resetOnMismatch then
						resetState()
					end
					return
				end
				if step >= seqLen then
					if elapsed >= minTotal then
						signalMethods.Fire(derived :: any, { Time = elapsed, Completed = true })
						resetState()
					else
						if fireOnMismatch then
							signalMethods.Fire(derived :: any, { Time = elapsed, Completed = false })
						end
						if resetOnMismatch then
							resetState()
						end
					end
				end
			end)
		end
	end
	return derived
end

return Signal

