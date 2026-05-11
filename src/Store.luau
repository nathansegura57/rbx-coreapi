--!strict

local Connection = require(script.Parent.Connection)
local ErrorHandler = require(script.Parent.ErrorHandler)
local Scheduler = require(script.Parent.Scheduler)
local Signal = require(script.Parent.Signal)

local Store = {}

export type ReadableStore<T> = {
	Get: (self: ReadableStore<T>) -> T,
	Peek: (self: ReadableStore<T>) -> T,
	Subscribe: (self: ReadableStore<T>, listener: (T, T?) -> (), opts: SubscribeOptions?) -> Connection.Connection,
	Changed: (self: ReadableStore<T>) -> Signal.Signal<{ New: T, Old: T }>,
	Map: <U>(self: ReadableStore<T>, picker: (T) -> U, equals: ((U, U) -> boolean)?) -> ReadableStore<U>,
	Equals: (self: ReadableStore<T>, equals: (T, T) -> boolean) -> ReadableStore<T>,
	Name: (self: ReadableStore<T>) -> string?,
	Deps: (self: ReadableStore<T>) -> { ReadableStore<any> },
	Wait: (self: ReadableStore<T>) -> (T, T),
	DisconnectAll: (self: ReadableStore<T>) -> (),
	IsDestroyed: (self: ReadableStore<T>) -> boolean,
	Destroy: (self: ReadableStore<T>) -> (),
}

export type WritableStore<T> = ReadableStore<T> & {
	Set: (self: WritableStore<T>, value: T) -> (),
	Update: (self: WritableStore<T>, updater: (T) -> T) -> (),
}

export type SubscribeOptions = {
	Immediate: boolean?,
	Deferred: boolean?,
}

export type ValueOptions<T> = {
	Name: string?,
	Equals: ((T, T) -> boolean)?,
	ReplaceName: boolean?,
}

export type DeriveOptions<T> = ValueOptions<T>

-- Internal

type SubscriberEntry = {
	Connected: boolean,
	Fn: (any, any?) -> (),
}

type WaiterEntry = {
	Thread: thread,
}

type StoreRecord = {
	Destroyed: boolean,
	Kind: "value" | "const" | "derived" | "readonly",
	Value: any,
	Dirty: boolean,
	DirtyOldValue: any,
	Subscribers: { SubscriberEntry },
	Waiters: { WaiterEntry },
	ChangedSignal: any?,
	Name: string?,
	Equals: ((any, any) -> boolean)?,
	Compute: (() -> any)?,
	Deps: { any },
	DerivedConsumers: { any },
}

local records: { [any]: StoreRecord } = setmetatable({}, { __mode = "k" } :: any)
local _namedStores: { [string]: any } = {}
local _batchDepth = 0
local _transactionDepth = 0
local _dirtyStores: { [any]: boolean } = {}
local _flushScheduled = false

local storeMethods: { [string]: any } = {}

local handleMeta = {
	__index = function(_self: any, key: string): any
		return storeMethods[key]
	end,
	__newindex = function(_self: any, key: string, _value: any): ()
		error(`Store: '{tostring(key)}' is read-only`)
	end,
	__metatable = "Store",
}

local function newHandle(kind: "value" | "const" | "derived" | "readonly"): any
	local h: any = setmetatable({}, handleMeta)
	records[h] = {
		Destroyed = false,
		Kind = kind,
		Value = nil,
		Dirty = false,
		DirtyOldValue = nil,
		Subscribers = {},
		Waiters = {},
		ChangedSignal = nil,
		Name = nil,
		Equals = nil,
		Compute = nil,
		Deps = {},
		DerivedConsumers = {},
	}
	return h
end

local function defaultEquals(a: any, b: any): boolean
	return a == b
end

-- Forward declarations
local recomputeDerived: (handle: any) -> ()
local markDirty: (handle: any, oldValue: any) -> ()
local doFlush: () -> ()
local flushStore: (handle: any) -> ()

markDirty = function(handle: any, oldValue: any): ()
	local rec: StoreRecord? = records[handle]
	if rec == nil or rec.Destroyed then return end
	if rec.Dirty then return end
	rec.Dirty = true
	rec.DirtyOldValue = oldValue
	_dirtyStores[handle] = true
	if _batchDepth > 0 or _transactionDepth > 0 then return end
	if not _flushScheduled then
		_flushScheduled = true
		Scheduler.Defer(function()
			_flushScheduled = false
			doFlush()
		end)
	end
end

recomputeDerived = function(handle: any): ()
	local rec: StoreRecord? = records[handle]
	if rec == nil or rec.Destroyed then return end
	local r = rec :: StoreRecord
	local oldValue = r.Value
	local ok, newValue = pcall(r.Compute :: any)
	if not ok then
		ErrorHandler.Report({ Module = "Store", Phase = "Derive", Error = newValue })
		return
	end
	local eq = if r.Equals ~= nil then r.Equals else defaultEquals
	if eq(oldValue, newValue) then return end
	r.Value = newValue
	markDirty(handle, oldValue)
	for _, consumer in r.DerivedConsumers do
		recomputeDerived(consumer)
	end
end

flushStore = function(handle: any): ()
	local rec: StoreRecord? = records[handle]
	if rec == nil or not rec.Dirty then return end
	local r = rec :: StoreRecord
	local newValue = r.Value
	local oldValue = r.DirtyOldValue
	r.Dirty = false
	r.DirtyOldValue = nil
	local snap = table.clone(r.Subscribers)
	for _, sub in snap do
		if sub.Connected then
			local ok, err = pcall(sub.Fn, newValue, oldValue)
			if not ok then
				ErrorHandler.Report({ Module = "Store", Phase = "Subscribe", Error = err })
			end
		end
	end
	local keep: { SubscriberEntry } = {}
	for _, s in r.Subscribers do
		if s.Connected then
			table.insert(keep, s)
		end
	end
	r.Subscribers = keep
	if r.ChangedSignal ~= nil then
		local sig: any = r.ChangedSignal
		if not sig:IsDestroyed() then
			sig:Fire({ New = newValue, Old = oldValue })
		end
	end
	local waiters = table.clone(r.Waiters)
	table.clear(r.Waiters)
	for _, w in waiters do
		local t = w.Thread
		Scheduler.Defer(function()
			coroutine.resume(t, true, newValue, oldValue)
		end)
	end
end

doFlush = function(): ()
	while next(_dirtyStores) ~= nil do
		local snap: { any } = {}
		for h, _ in _dirtyStores do
			table.insert(snap, h)
		end
		table.clear(_dirtyStores)
		for _, h in snap do
			flushStore(h)
		end
	end
end

-- Validate and extract ValueOptions/DeriveOptions
local function parseValueOpts(caller: string, opts: any): (string?, ((any, any) -> boolean)?, boolean)
	if opts == nil then return nil, nil, false end
	if type(opts) ~= "table" then
		error(`{caller}: opts must be a table or nil`)
	end
	local name: string? = nil
	local eq: ((any, any) -> boolean)? = nil
	local replaceName = false
	if opts.Name ~= nil then
		if type(opts.Name) ~= "string" or #(opts.Name :: string) == 0 then
			error(`{caller}: Name must be a non-empty string or nil`)
		end
		name = opts.Name
	end
	if opts.Equals ~= nil then
		if type(opts.Equals) ~= "function" then
			error(`{caller}: Equals must be a function or nil`)
		end
		eq = opts.Equals
	end
	if opts.ReplaceName ~= nil then
		if type(opts.ReplaceName) ~= "boolean" then
			error(`{caller}: ReplaceName must be a boolean or nil`)
		end
		replaceName = opts.ReplaceName
	end
	return name, eq, replaceName
end

-- Constructors

function Store.Value(initial: any, opts: any?): any
	local name, eq, replaceName = parseValueOpts("Store.Value", opts)
	if name ~= nil and _namedStores[name] ~= nil and not replaceName then
		error(`Store.Value: duplicate store name '{name}'`)
	end
	local h = newHandle("value")
	local rec = records[h] :: StoreRecord
	rec.Value = initial
	rec.Name = name
	rec.Equals = eq
	if name ~= nil then
		_namedStores[name] = h
	end
	return h
end

function Store.Const(value: any): any
	local h = newHandle("const")
	local rec = records[h] :: StoreRecord
	rec.Value = value
	return h
end

function Store.Derive(compute: any, deps: any, opts: any?): any
	if type(compute) ~= "function" then
		error("Store.Derive: compute must be a function")
	end
	if type(deps) ~= "table" or #deps == 0 then
		error("Store.Derive: deps must be a non-empty dense array")
	end
	for i = 1, #deps do
		local dep = deps[i]
		if not Store.IsStore(dep) or (records[dep] :: StoreRecord).Destroyed then
			error(`Store.Derive: dep at index {i} is not a live Store`)
		end
	end
	local name: string?, eq: ((any, any) -> boolean)?, replaceName: boolean
	if opts ~= nil then
		name, eq, replaceName = parseValueOpts("Store.Derive", opts)
	else
		name = nil
		eq = nil
		replaceName = false
	end
	local ok, initValue = pcall(compute)
	if not ok then
		error(`Store.Derive: initial compute failed: {tostring(initValue)}`)
	end
	if name ~= nil and _namedStores[name] ~= nil and not replaceName then
		error(`Store.Derive: duplicate store name '{name}'`)
	end
	local h = newHandle("derived")
	local rec = records[h] :: StoreRecord
	rec.Value = initValue
	rec.Compute = compute
	rec.Name = name
	rec.Equals = eq
	for i = 1, #deps do
		local dep = deps[i]
		rec.Deps[i] = dep
		local depRec = records[dep] :: StoreRecord
		table.insert(depRec.DerivedConsumers, h)
	end
	if name ~= nil then
		_namedStores[name] = h
	end
	return h
end

function Store.Select(source: any, picker: any, equals: any?): any
	if not Store.IsStore(source) or (records[source] :: StoreRecord).Destroyed then
		error("Store.Select: source must be a live Store")
	end
	if type(picker) ~= "function" then
		error("Store.Select: picker must be a function")
	end
	if equals ~= nil and type(equals) ~= "function" then
		error("Store.Select: equals must be a function or nil")
	end
	local src = source
	return Store.Derive(function()
		return picker((records[src] :: StoreRecord).Value)
	end, { source }, if equals ~= nil then { Equals = equals } else nil)
end

function Store.Combine(values: any): any
	if type(values) ~= "table" then
		error("Store.Combine: input must be a table")
	end
	local keyCount = 0
	for _ in values do keyCount += 1 end
	if keyCount == 0 then
		error("Store.Combine: input must not be empty")
	end
	local isArray = keyCount == #values and #values > 0
	if isArray then
		for i = 1, #values do
			if not Store.IsStore(values[i]) or (records[values[i]] :: StoreRecord).Destroyed then
				error(`Store.Combine: entry at index {i} is not a live Store`)
			end
		end
		local deps = table.clone(values)
		return Store.Derive(function()
			local result: { any } = table.create(#deps)
			for i = 1, #deps do
				result[i] = (records[deps[i]] :: StoreRecord).Value
			end
			return result
		end, deps)
	else
		local keys: { any } = {}
		local depList: { any } = {}
		for k, s in values do
			if not Store.IsStore(s) or (records[s] :: StoreRecord).Destroyed then
				error(`Store.Combine: value for key '{tostring(k)}' is not a live Store`)
			end
			table.insert(keys, k)
			table.insert(depList, s)
		end
		local storeMap = table.clone(values)
		return Store.Derive(function()
			local result: { [any]: any } = {}
			for _, k in keys do
				result[k] = (records[storeMap[k]] :: StoreRecord).Value
			end
			return result
		end, depList)
	end
end

function Store.AllTruthy(stores: any): any
	if type(stores) ~= "table" or #stores == 0 then
		error("Store.AllTruthy: stores must be a non-empty dense array of live Stores")
	end
	for i = 1, #stores do
		if not Store.IsStore(stores[i]) or (records[stores[i]] :: StoreRecord).Destroyed then
			error(`Store.AllTruthy: entry at index {i} is not a live Store`)
		end
	end
	local deps = table.clone(stores)
	return Store.Derive(function(): boolean
		for _, s in deps do
			if not (records[s] :: StoreRecord).Value then return false end
		end
		return true
	end, deps)
end

function Store.AnyTruthy(stores: any): any
	if type(stores) ~= "table" or #stores == 0 then
		error("Store.AnyTruthy: stores must be a non-empty dense array of live Stores")
	end
	for i = 1, #stores do
		if not Store.IsStore(stores[i]) or (records[stores[i]] :: StoreRecord).Destroyed then
			error(`Store.AnyTruthy: entry at index {i} is not a live Store`)
		end
	end
	local deps = table.clone(stores)
	return Store.Derive(function(): boolean
		for _, s in deps do
			if (records[s] :: StoreRecord).Value then return true end
		end
		return false
	end, deps)
end

function Store.Match(source: any, cases: any): any
	if not Store.IsStore(source) or (records[source] :: StoreRecord).Destroyed then
		error("Store.Match: source must be a live Store")
	end
	if type(cases) ~= "table" then
		error("Store.Match: cases must be a table")
	end
	local deps: { any } = { source }
	local caseMap: { [any]: any } = {}
	for k, s in cases do
		if not Store.IsStore(s) or (records[s] :: StoreRecord).Destroyed then
			error(`Store.Match: case '{tostring(k)}' is not a live Store`)
		end
		table.insert(deps, s)
		caseMap[k] = s
	end
	local srcRec = records[source] :: StoreRecord
	local initialKey = srcRec.Value
	local initialCase = caseMap[initialKey] or caseMap["_"]
	if initialCase == nil then
		error("Store.Match: initial case not found and no default '_' case")
	end
	local UNSET: any = {}
	local lastValue: any = UNSET
	return Store.Derive(function(): any
		local key = (records[source] :: StoreRecord).Value
		local caseStore = caseMap[key] or caseMap["_"]
		if caseStore == nil then
			ErrorHandler.Report({ Module = "Store", Phase = "Match", Error = `no case for key '{tostring(key)}'` })
			if lastValue ~= UNSET then
				return lastValue
			end
			error("Store.Match: no case found")
		end
		local v = (records[caseStore] :: StoreRecord).Value
		lastValue = v
		return v
	end, deps)
end

function Store.Readonly(store: any): any
	if not Store.IsStore(store) or (records[store] :: StoreRecord).Destroyed then
		error("Store.Readonly: store must be a live Store")
	end
	local srcRec = records[store] :: StoreRecord
	local h = newHandle("readonly")
	local rec = records[h] :: StoreRecord
	rec.Value = srcRec.Value
	rec.Compute = function(): any
		return (records[store] :: StoreRecord).Value
	end
	rec.Deps = { store }
	table.insert(srcRec.DerivedConsumers, h)
	return h
end

function Store.IsStore(value: unknown): boolean
	if type(value) ~= "table" then return false end
	return records[value :: any] ~= nil
end

-- Instance methods

function storeMethods:Get(): any
	local rec: StoreRecord? = records[self :: any]
	if rec == nil or rec.Destroyed then
		error("Store.Get: store is destroyed")
	end
	return rec.Value
end

function storeMethods:Peek(): any
	return storeMethods.Get(self)
end

function storeMethods:Set(value: any): ()
	local rec: StoreRecord? = records[self :: any]
	if rec == nil or rec.Destroyed then
		error("Store.Set: store is destroyed")
	end
	local r = rec :: StoreRecord
	if r.Kind == "readonly" then
		error("Store.Set: store is read-only")
	end
	if r.Kind ~= "value" then
		error("Store.Set: only writable stores support Set")
	end
	local oldValue = r.Value
	local eq = if r.Equals ~= nil then r.Equals else defaultEquals
	if eq(oldValue, value) then return end
	r.Value = value
	for _, consumer in r.DerivedConsumers do
		recomputeDerived(consumer)
	end
	markDirty(self :: any, oldValue)
end

function storeMethods:Update(updater: any): ()
	local rec: StoreRecord? = records[self :: any]
	if rec == nil or rec.Destroyed then
		error("Store.Set: store is destroyed")
	end
	if type(updater) ~= "function" then
		error("Store.Update: updater must be a function")
	end
	local current = (rec :: StoreRecord).Value
	local ok, newValue = pcall(updater, current)
	if not ok then
		error(newValue, 0)
	end
	storeMethods.Set(self, newValue)
end

function storeMethods:Subscribe(listener: any, opts: any?): Connection.Connection
	local rec: StoreRecord? = records[self :: any]
	if rec == nil or rec.Destroyed then
		error("Store.Subscribe: store is destroyed")
	end
	if type(listener) ~= "function" then
		error("Store.Subscribe: listener must be a function")
	end
	local immediate = true
	local deferred = false
	if opts ~= nil then
		if type(opts) ~= "table" then
			error("Store.Subscribe: opts must be a table or nil")
		end
		if opts.Immediate ~= nil then
			if type(opts.Immediate) ~= "boolean" then
				error("Store.Subscribe: Immediate must be a boolean or nil")
			end
			immediate = opts.Immediate
		end
		if opts.Deferred ~= nil then
			if type(opts.Deferred) ~= "boolean" then
				error("Store.Subscribe: Deferred must be a boolean or nil")
			end
			deferred = opts.Deferred
		end
	end
	local r = rec :: StoreRecord
	local entry: SubscriberEntry = { Connected = true, Fn = listener }
	table.insert(r.Subscribers, entry)
	local conn = Connection.New(function()
		entry.Connected = false
	end)
	if immediate and not deferred then
		local ok, err = pcall(listener, r.Value, nil)
		if not ok then
			ErrorHandler.Report({ Module = "Store", Phase = "Subscribe", Error = err })
		end
	elseif immediate and deferred then
		local v = r.Value
		Scheduler.Defer(function()
			if entry.Connected then
				local ok, err = pcall(listener, v, nil)
				if not ok then
					ErrorHandler.Report({ Module = "Store", Phase = "Subscribe", Error = err })
				end
			end
		end)
	end
	return conn
end

function storeMethods:Changed(): any
	local rec: StoreRecord? = records[self :: any]
	if rec == nil then error("Store.Changed: invalid store") end
	local r = rec :: StoreRecord
	if r.ChangedSignal == nil then
		r.ChangedSignal = Signal.New()
	end
	return r.ChangedSignal
end

function storeMethods:Map(picker: any, equals: any?): any
	return Store.Select(self, picker, equals)
end

function storeMethods:Equals(eq: any): any
	if not Store.IsStore(self) then error("Store.Equals: invalid store") end
	local src = self :: any
	return Store.Derive(function()
		return (records[src] :: StoreRecord).Value
	end, { src }, { Equals = eq })
end

function storeMethods:Name(): string?
	local rec: StoreRecord? = records[self :: any]
	if rec == nil or rec.Destroyed then return nil end
	return rec.Name
end

function storeMethods:Deps(): { any }
	local rec: StoreRecord? = records[self :: any]
	if rec == nil or rec.Destroyed then return {} end
	return table.clone(rec.Deps)
end

function storeMethods:Wait(): (any, any)
	local rec: StoreRecord? = records[self :: any]
	if rec == nil or rec.Destroyed then
		error("Store.Wait: store destroyed")
	end
	if not coroutine.isyieldable() then
		error("Store.Wait: must be called from a yieldable coroutine")
	end
	local thread = coroutine.running() :: thread
	local r = rec :: StoreRecord
	local waiter: WaiterEntry = { Thread = thread }
	table.insert(r.Waiters, waiter)
	local ok, newVal, oldVal = coroutine.yield()
	if not ok then
		error("Store.Wait: store destroyed")
	end
	return newVal, oldVal
end

function storeMethods:DisconnectAll(): ()
	local rec: StoreRecord? = records[self :: any]
	if rec == nil then return end
	for _, sub in rec.Subscribers do
		sub.Connected = false
	end
	table.clear(rec.Subscribers)
end

function storeMethods:IsDestroyed(): boolean
	local rec: StoreRecord? = records[self :: any]
	if rec == nil then return true end
	return rec.Destroyed
end

function storeMethods:Destroy(): ()
	local rec: StoreRecord? = records[self :: any]
	if rec == nil or rec.Destroyed then return end
	local r = rec :: StoreRecord
	r.Destroyed = true
	local consumers = table.clone(r.DerivedConsumers)
	table.clear(r.DerivedConsumers)
	for _, consumer in consumers do
		storeMethods.Destroy(consumer)
	end
	for _, sub in r.Subscribers do
		sub.Connected = false
	end
	table.clear(r.Subscribers)
	local waiters = table.clone(r.Waiters)
	table.clear(r.Waiters)
	for _, w in waiters do
		local t = w.Thread
		Scheduler.Defer(function()
			coroutine.resume(t, false, nil, nil)
		end)
	end
	if r.ChangedSignal ~= nil then
		(r.ChangedSignal :: any):Destroy()
		r.ChangedSignal = nil
	end
	if r.Name ~= nil and _namedStores[r.Name] == (self :: any) then
		_namedStores[r.Name] = nil
	end
	for _, dep in r.Deps do
		local depRec: StoreRecord? = records[dep]
		if depRec ~= nil then
			for i = 1, #depRec.DerivedConsumers do
				if depRec.DerivedConsumers[i] == (self :: any) then
					table.remove(depRec.DerivedConsumers, i)
					break
				end
			end
		end
	end
	table.clear(r.Deps)
end

-- Batch / Transaction

function Store.Batch(block: any): ()
	if type(block) ~= "function" then
		error("Store.Batch: block must be a function")
	end
	_batchDepth += 1
	local ok, err = pcall(block)
	_batchDepth -= 1
	if not ok then
		error(err, 0)
	end
	if _batchDepth == 0 and _transactionDepth == 0 then
		doFlush()
	end
end

function Store.Transaction(block: any): ()
	if type(block) ~= "function" then
		error("Store.Transaction: block must be a function")
	end
	_transactionDepth += 1
	local ok, err = pcall(block)
	_transactionDepth -= 1
	if not ok then
		error(err, 0)
	end
	if _batchDepth == 0 and _transactionDepth == 0 then
		if not _flushScheduled then
			_flushScheduled = true
			Scheduler.Defer(function()
				_flushScheduled = false
				doFlush()
			end)
		end
	end
end

-- Snapshot / Restore

export type Snapshot = { [any]: any }

function Store.Snapshot(...: any): Snapshot
	local snap: Snapshot = {}
	local args = { ... }
	for _, s in args do
		if not Store.IsStore(s) or (records[s] :: StoreRecord).Destroyed then
			error("Store.Snapshot: all arguments must be live Stores")
		end
		local rec = records[s] :: StoreRecord
		if rec.Name ~= nil then
			snap[rec.Name :: string] = rec.Value
		else
			snap[s] = rec.Value
		end
	end
	return snap
end

function Store.Restore(snapshot: Snapshot, opts: any?): ()
	local strict = false
	if opts ~= nil then
		if type(opts) ~= "table" then
			error("Store.Restore: opts must be a table or nil")
		end
		if opts.Strict ~= nil then
			if type(opts.Strict) ~= "boolean" then
				error("Store.Restore: Strict must be a boolean or nil")
			end
			strict = opts.Strict
		end
	end
	Store.Transaction(function()
		for k, v in snapshot do
			if type(k) == "string" then
				local storeHandle = _namedStores[k]
				if storeHandle == nil then
					if strict then error(`Store.Restore: unknown store '{k}'`) end
				else
					local rec: StoreRecord? = records[storeHandle]
					if rec == nil or rec.Destroyed then
						if strict then error(`Store.Restore: store '{k}' is destroyed`) end
					elseif rec.Kind ~= "value" then
						if strict then error(`Store.Restore: store '{k}' is not writable`) end
					else
						storeMethods.Set(storeHandle, v)
					end
				end
			else
				if strict then
					error("Store.Restore: snapshot contains unnamed store entry which is not restorable")
				end
			end
		end
	end)
end

-- History

export type History<T> = {
	Undo: () -> boolean,
	Redo: () -> boolean,
	Clear: () -> (),
	Destroy: () -> (),
	CanUndo: ReadableStore<boolean>,
	CanRedo: ReadableStore<boolean>,
}

function Store.History(store: any, limit: number?): any
	if not Store.IsStore(store) then
		error("Store.History: store must be a writable live Store")
	end
	local rec = records[store] :: StoreRecord
	if rec.Destroyed or rec.Kind ~= "value" then
		error("Store.History: store must be a writable live Store")
	end
	local lim = if limit ~= nil then limit else 100
	if type(lim) ~= "number" or lim < 1 or lim ~= math.floor(lim) then
		error("Store.History: limit must be a positive integer or nil")
	end

	type HistEntry = { Value: any }
	local undoStack: { HistEntry } = {}
	local redoStack: { HistEntry } = {}

	local canUndo: any = Store.Value(false)
	local canRedo: any = Store.Value(false)

	local suppressing = false

	local function updateFlags(): ()
		storeMethods.Set(canUndo, #undoStack > 0)
		storeMethods.Set(canRedo, #redoStack > 0)
	end

	local conn = storeMethods.Subscribe(store, function(_new: any, old: any): ()
		if suppressing then return end
		table.insert(undoStack, { Value = old })
		while #undoStack > lim do
			table.remove(undoStack, 1)
		end
		table.clear(redoStack)
		updateFlags()
	end, { Immediate = false })

	local destroyed = false

	return {
		Undo = function(): boolean
			if destroyed then return false end
			if #undoStack == 0 then return false end
			local entry = table.remove(undoStack, #undoStack)
			local currentRec = records[store] :: StoreRecord
			table.insert(redoStack, { Value = currentRec.Value })
			suppressing = true
			storeMethods.Set(store, entry.Value)
			suppressing = false
			updateFlags()
			return true
		end,
		Redo = function(): boolean
			if destroyed then return false end
			if #redoStack == 0 then return false end
			local entry = table.remove(redoStack, #redoStack)
			local currentRec = records[store] :: StoreRecord
			table.insert(undoStack, { Value = currentRec.Value })
			suppressing = true
			storeMethods.Set(store, entry.Value)
			suppressing = false
			updateFlags()
			return true
		end,
		Clear = function(): ()
			table.clear(undoStack)
			table.clear(redoStack)
			updateFlags()
		end,
		Destroy = function(): ()
			if destroyed then return end
			destroyed = true
			conn:Disconnect()
			storeMethods.Destroy(canUndo)
			storeMethods.Destroy(canRedo)
		end,
		CanUndo = canUndo,
		CanRedo = canRedo,
	}
end

return Store
