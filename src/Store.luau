--!strict
--!optimize 2

-- Store<T>: reactive state graph. Derived recomputation, transactions, snapshots.
--
-- Safety model
--   Instances are frozen opaque handles. All mutable state lives in
--   module-private weak tables keyed by identity.
--   __metatable = "Store" blocks getmetatable().
--
-- Notification model
--   set/update apply to storeRecord.value immediately (get() is always current).
--   Derived stores recompute eagerly on dep mutation (cascadeConsumers).
--   Subscriber callbacks fire in a deferred flush phase, coalesced per frame.
--   store.transaction() defers flush until the outermost block exits.
--   store.batch() flushes synchronously on exit (for tools / editor use).
--
-- Reactive graph
--   Explicit deps (no auto-tracking). Cycle detection at derive() time.
--   topoOrder (computed at construction) ensures derived recompute in
--   dependency order; index tiebreaks for determinism.
--
-- Lifetime
--   source destroyed → all consumers destroyed.
--   consumer destroyed → unlinks from its deps; sources are unaffected.

local ConnectionModule     = require(script.Parent.Internal.Connection)
local SubscriberListModule = require(script.Parent.Internal.SubscriberList)
local SchedulerModule      = require(script.Parent.Internal.Scheduler)
local Signal               = require(script.Parent.Signal)
local StoreTypes           = require(script.Parent.Types.StoreTypes)

local Scheduler = SchedulerModule.Scheduler

-- ── Internal types ─────────────────────────────────────────────────────────────

type StoreRecord = {
	kind:              "value" | "derived" | "const",
	value:             any,
	lastNotifiedValue: any,
	equals:            (any, any) -> boolean,
	name:              string?,
	index:             number,
	topoOrder:         number,
	subscriberList:    SubscriberListModule.SubscriberList,
	consumers:         { [StoreRecord]: true }?,
	depRecords:        { StoreRecord }?,
	depHandles:        { any }?,
	compute:           (() -> any)?,
	changedSignal:     any?,
	destroyed:         boolean,
	destroyHooks:      { () -> () }?,
}

-- Weak-keyed: abandoned handles are collected by the GC automatically.
local storeRecords: { [any]: StoreRecord } =
	setmetatable({}, { __mode = "k" } :: { __mode: "k" }) :: any

-- ── Public types ───────────────────────────────────────────────────────────────

export type Connection      = StoreTypes.Connection
export type ReadableStore<T> = StoreTypes.ReadableStore<T>
export type WritableStore<T> = StoreTypes.WritableStore<T>
export type DerivedStore<T>  = StoreTypes.DerivedStore<T>

-- ── Flush scheduler state ──────────────────────────────────────────────────────

local flushScheduler = {
	dirty            = {} :: { [StoreRecord]: true },
	dirtyOrder       = {} :: { StoreRecord },
	transactionDepth = 0,
	isFlushQueued    = false,
	nextIndex        = 0,
}

local namedStores:  { [string]: StoreRecord } = {}
-- Weak values: handle GC removes entries when the store handle is collected.
local namedHandles: { [string]: any } = setmetatable({}, { __mode = "v" }) :: any

-- ── Store metatable ────────────────────────────────────────────────────────────

local storeMethods = {}

local STORE_META = {
	__metatable = "Store",
	__newindex  = function(_, key: string)
		error(`Store: '{key}' is read-only`, 2)
	end,
	__index = storeMethods,
}

local function newHandle(): any
	local handle = setmetatable({}, STORE_META)
	return handle
end

local function newBaseRecord(
	kind:  "value" | "derived" | "const",
	value: any,
	name:  string?,
	eq:    ((any, any) -> boolean)?
): StoreRecord
	flushScheduler.nextIndex += 1
	return {
		kind              = kind,
		value             = value,
		lastNotifiedValue = value,
		equals            = eq or function(a, b) return a == b end,
		name              = name,
		index             = flushScheduler.nextIndex,
		topoOrder         = 0,
		subscriberList    = SubscriberListModule.create(),
		consumers         = nil,
		depRecords        = nil,
		depHandles        = nil,
		compute           = nil,
		changedSignal     = nil,
		destroyed         = false,
		destroyHooks      = nil,
	}
end

-- ── Lifecycle helpers ──────────────────────────────────────────────────────────

local function addDestroyHook(storeRecord: StoreRecord, hook: () -> ())
	if not storeRecord.destroyHooks then storeRecord.destroyHooks = {} end
	table.insert(storeRecord.destroyHooks :: { () -> () }, hook)
end

local function markDirty(storeRecord: StoreRecord)
	if flushScheduler.dirty[storeRecord] then return end
	flushScheduler.dirty[storeRecord] = true
	table.insert(flushScheduler.dirtyOrder, storeRecord)
end

local cascadeConsumers: (storeRecord: StoreRecord) -> ()
local flushNow: () -> ()

local function scheduleFlush()
	if flushScheduler.isFlushQueued or flushScheduler.transactionDepth > 0 then return end
	flushScheduler.isFlushQueued = true
	Scheduler.defer(function() flushNow() end)
end

cascadeConsumers = function(storeRecord: StoreRecord)
	local consumers = storeRecord.consumers
	if not consumers then return end
	for consumerRecord in pairs(consumers) do
		if consumerRecord.destroyed then continue end
		local previousValue = consumerRecord.value
		local ok, newValue  = pcall(consumerRecord.compute :: () -> any)
		if ok and not consumerRecord.equals(newValue, previousValue) then
			consumerRecord.value = newValue
			markDirty(consumerRecord)
			cascadeConsumers(consumerRecord)
		end
	end
end

flushNow = function()
	flushScheduler.isFlushQueued = false
	if #flushScheduler.dirtyOrder == 0 then return end

	local toProcess          = flushScheduler.dirtyOrder
	flushScheduler.dirty     = {}
	flushScheduler.dirtyOrder = {}

	table.sort(toProcess, function(a: StoreRecord, b: StoreRecord): boolean
		if a.topoOrder ~= b.topoOrder then return a.topoOrder < b.topoOrder end
		return a.index < b.index
	end)

	for _, storeRecord in ipairs(toProcess) do
		if storeRecord.destroyed then continue end
		local newValue = storeRecord.value
		local oldValue = storeRecord.lastNotifiedValue
		if storeRecord.equals(newValue, oldValue) then continue end
		storeRecord.lastNotifiedValue = newValue
		SubscriberListModule.fire(storeRecord.subscriberList, newValue, oldValue)
		if storeRecord.changedSignal then
			(storeRecord.changedSignal :: any):fire({ new = newValue, old = oldValue })
		end
	end

	-- Drain any stores mutated during subscriber callbacks.
	if #flushScheduler.dirtyOrder > 0 then flushNow() end
end

-- ── Cycle detection ────────────────────────────────────────────────────────────

local function detectCycle(newRecord: StoreRecord, depRecords: { StoreRecord }): string?
	local function label(record: StoreRecord): string
		return record.name or ("@" .. record.index)
	end
	local function dfs(current: StoreRecord, path: { string }): string?
		if current == newRecord then
			table.insert(path, label(current))
			return table.concat(path, " → ")
		end
		if current.consumers then
			for consumer in pairs(current.consumers) do
				table.insert(path, label(current))
				local result = dfs(consumer, path)
				if result then return result end
				table.remove(path)
			end
		end
		return nil
	end
	for _, depRecord in ipairs(depRecords) do
		local result = dfs(depRecord, {})
		if result then return result end
	end
	return nil
end

-- ── Forward ref for methods that call module API before it is populated ────────
--
-- storeMethods is defined early so STORE_META can reference it. Methods like
-- :map and :equals need to call StoreAPI functions, so they reference
-- storeAPIRef which is populated at module tail from StoreAPI.

local storeAPIRef: {
	value:       <T>(init: T, opts: { name: string?, equals: ((T, T) -> boolean)? }?) -> WritableStore<T>,
	const:       <T>(v: T) -> ReadableStore<T>,
	derive:      <T>(compute: () -> T, deps: { ReadableStore<any> }, opts: { name: string?, equals: ((T, T) -> boolean)? }?) -> DerivedStore<T>,
	select:      <T, R>(source: ReadableStore<T>, picker: (T) -> R, equality: ((R, R) -> boolean)?) -> DerivedStore<R>,
	all:         (stores: { ReadableStore<any> }) -> ReadableStore<any>,
	any:         (stores: { ReadableStore<boolean> }) -> ReadableStore<boolean>,
	match:       <S, T>(source: ReadableStore<S>, cases: { [any]: ReadableStore<T> }) -> ReadableStore<T>,
	tween:       <T>(source: ReadableStore<T>, opts: { time: number?, easing: string?, delay: number? }?) -> ReadableStore<T>,
	spring:      <T>(source: ReadableStore<T>, opts: { stiffness: number?, damping: number?, mass: number?, clamp: boolean? }?) -> ReadableStore<T>,
	table:   <K, V>() -> any,
	set:     <T>() -> any,
	map:     <K, V>() -> any,
	transaction: (block: () -> ()) -> (),
	batch:       (block: () -> ()) -> (),
	snapshot:    (...ReadableStore<any>) -> { [string]: any },
	restore:     (snapshot: { [string]: any }) -> (),
	history:     <T>(targetStore: WritableStore<T>, limit: number?) -> any,
} = {} :: any

-- ── Instance methods ───────────────────────────────────────────────────────────

function storeMethods:get(): any
	local storeRecord = storeRecords[self]
	assert(storeRecord and not storeRecord.destroyed, "Store.get: store is destroyed")
	return storeRecord.value
end

function storeMethods:set(newValue: any)
	local storeRecord = storeRecords[self]
	assert(storeRecord and not storeRecord.destroyed, "Store.set: store is destroyed")
	assert(storeRecord.kind == "value", "Store.set: only writable (value) stores support set()")
	if storeRecord.equals(newValue, storeRecord.value) then return end
	storeRecord.value = newValue
	markDirty(storeRecord)
	cascadeConsumers(storeRecord)
	scheduleFlush()
end

function storeMethods:update(updater: (any) -> any)
	local storeRecord = storeRecords[self]
	assert(storeRecord and not storeRecord.destroyed, "Store.update: store is destroyed")
	assert(storeRecord.kind == "value", "Store.update: only writable (value) stores support update()")
	local newValue = updater(storeRecord.value)
	if storeRecord.equals(newValue, storeRecord.value) then return end
	storeRecord.value = newValue
	markDirty(storeRecord)
	cascadeConsumers(storeRecord)
	scheduleFlush()
end

function storeMethods:subscribe(listener: (any, any?) -> ()): Connection
	local storeRecord = storeRecords[self]
	assert(storeRecord and not storeRecord.destroyed, "Store.subscribe: store is destroyed")
	local isStillConnected, performDisconnect =
		SubscriberListModule.append(storeRecord.subscriberList, listener)
	local connection   = ConnectionModule.create(isStillConnected, performDisconnect)
	local currentValue = storeRecord.value
	-- Deliver the current value on the next frame so the subscriber finishes
	-- setting up before it receives its first notification.
	Scheduler.defer(function()
		if connection.Connected then listener(currentValue, nil) end
	end)
	return connection
end

function storeMethods:changed(): any
	local storeRecord = storeRecords[self]
	assert(storeRecord and not storeRecord.destroyed, "Store.changed: store is destroyed")
	if not storeRecord.changedSignal then
		storeRecord.changedSignal = Signal.new()
	end
	return storeRecord.changedSignal
end

function storeMethods:equals(eq: (any, any) -> boolean): any
	local storeRecord = storeRecords[self]
	assert(storeRecord and not storeRecord.destroyed, "Store.equals: store is destroyed")
	return storeAPIRef.derive(function() return storeRecord.value end, { self }, { equals = eq })
end

function storeMethods:name(): string?
	local storeRecord = storeRecords[self]
	return storeRecord and storeRecord.name or nil
end

function storeMethods:deps(): { any }
	local storeRecord = storeRecords[self]
	if not storeRecord or not storeRecord.depHandles then return {} end
	return table.clone(storeRecord.depHandles :: { any })
end

function storeMethods:map(picker: (any) -> any, equality: ((any, any) -> boolean)?): any
	return storeAPIRef.select(self, picker, equality)
end

function storeMethods:destroy()
	local storeRecord = storeRecords[self]
	if not storeRecord or storeRecord.destroyed then return end
	storeRecord.destroyed = true
	-- Cascade destroy to all consumers. Snapshot first to avoid mutating the
	-- set while iterating (consumer hooks will try to unlink themselves).
	if storeRecord.consumers then
		local consumerSnapshot: { StoreRecord } = {}
		for consumerRecord in pairs(storeRecord.consumers) do
			table.insert(consumerSnapshot, consumerRecord)
		end
		storeRecord.consumers = nil
		for _, consumerRecord in ipairs(consumerSnapshot) do
			if not consumerRecord.destroyed then
				consumerRecord.destroyed = true
				local hooks = consumerRecord.destroyHooks
				consumerRecord.destroyHooks = nil
				if hooks then for _, hook in ipairs(hooks) do hook() end end
			end
		end
	end
	SubscriberListModule.destroyAll(storeRecord.subscriberList)
	if storeRecord.name then
		namedStores[storeRecord.name]  = nil
		namedHandles[storeRecord.name] = nil
	end
	if storeRecord.changedSignal then
		(storeRecord.changedSignal :: any):destroy()
		storeRecord.changedSignal = nil
	end
	local hooks = storeRecord.destroyHooks
	storeRecord.destroyHooks = nil
	if hooks then for _, hook in ipairs(hooks) do hook() end end
	storeRecords[self] = nil
end

-- ── Module API ─────────────────────────────────────────────────────────────────

local StoreAPI = {} :: any

type InitOptions<T> = {
	name: string?,
	equals: ((T, T) -> boolean)?
}

function StoreAPI.value<T>(
	init: T,
	opts: InitOptions<T>?
): WritableStore<T>
	local options = opts or {} :: InitOptions<T>
	local record  = newBaseRecord("value", init, options.name, options.equals :: any)
	local handle  = newHandle()
	storeRecords[handle] = record
	if record.name then namedStores[record.name] = record; namedHandles[record.name] = handle end
	return handle :: any
end

function StoreAPI.const<T>(v: T): ReadableStore<T>
	local record = newBaseRecord("const", v, nil, nil)
	local handle = newHandle()
	storeRecords[handle] = record
	return handle :: any
end

function StoreAPI.derive<T>(
	compute: () -> T,
	deps:    { ReadableStore<any> },
	opts:    InitOptions<T>?
): DerivedStore<T>
	assert(type(compute) == "function", "Store.derive: compute must be a function")
	assert(type(deps) == "table" and #deps > 0, "Store.derive: deps must be a non-empty array")
	local options = opts or {} :: InitOptions<T>

	local depRecords: { StoreRecord } = {}
	local maxTopoOrder = 0
	for _, dep in ipairs(deps) do
		local depRecord = storeRecords[dep :: any]
		assert(depRecord and not depRecord.destroyed, "Store.derive: a dep store is destroyed")
		table.insert(depRecords, depRecord)
		if depRecord.topoOrder > maxTopoOrder then maxTopoOrder = depRecord.topoOrder end
	end

	local cycleDescription = detectCycle(
		{ topoOrder = maxTopoOrder + 1 } :: StoreRecord,
		depRecords
	)
	assert(
		not cycleDescription,
		"Store.derive: cyclic dependency detected: " .. tostring(cycleDescription)
	)

	local ok, initialValue = pcall(compute)
	assert(ok, "Store.derive: initial compute failed: " .. tostring(initialValue))

	local record = newBaseRecord("derived", initialValue, options.name, options.equals :: any)
	record.topoOrder  = maxTopoOrder + 1
	record.depRecords = depRecords
	record.depHandles = table.clone(deps) :: any
	record.compute    = compute :: any

	local derivedHandle = newHandle()
	storeRecords[derivedHandle] = record

	-- Wire forward edges: dep → this derived store.
	for _, depRecord in ipairs(depRecords) do
		if not depRecord.consumers then depRecord.consumers = {} end
		(depRecord.consumers :: {[StoreRecord]: true})[record] = true
		-- When a dep is destroyed, destroy this derived store too.
		addDestroyHook(depRecord, function()
			if not record.destroyed then
				record.destroyed = true
				local hooks = record.destroyHooks
				record.destroyHooks = nil
				if hooks then for _, hook in ipairs(hooks) do hook() end end
			end
		end)
	end

	-- On self-destroy: unlink from all dep forward edges.
	-- Guard nil: if the dep was destroyed first it already set consumers = nil.
	addDestroyHook(record, function()
		for _, depRecord in ipairs(depRecords) do
			if depRecord.consumers then depRecord.consumers[record] = nil end
		end
		if record.name then
			namedStores[record.name]  = nil
			namedHandles[record.name] = nil
		end
	end)

	if record.name then namedStores[record.name] = record; namedHandles[record.name] = derivedHandle end
	return derivedHandle :: any
end

function StoreAPI.select<T, R>(
	source:   ReadableStore<T>,
	picker:   (T) -> R,
	equality: ((R, R) -> boolean)?
): DerivedStore<R>
	return StoreAPI.derive(
		function(): R return picker((source :: any):get()) end,
		{ source },
		{ equals = equality :: any }
	)
end

function StoreAPI.all(stores: { ReadableStore<any> }): ReadableStore<any>
	assert(type(stores) == "table" and #stores > 0, "Store.all: stores must be a non-empty array")
	local allBoolean = true
	for _, store in ipairs(stores) do
		if type((store :: any):get()) ~= "boolean" then allBoolean = false; break end
	end
	if allBoolean then
		return StoreAPI.derive(function()
			for _, store in ipairs(stores) do
				if not (store :: any):get() then return false end
			end
			return true
		end, stores) :: any
	else
		return StoreAPI.derive(function()
			local values = table.create(#stores)
			for i, store in ipairs(stores) do values[i] = (store :: any):get() end
			return values
		end, stores) :: any
	end
end

function StoreAPI.any(stores: { ReadableStore<boolean> }): ReadableStore<boolean>
	assert(type(stores) == "table" and #stores > 0, "Store.any: stores must be a non-empty array")
	return StoreAPI.derive(function()
		for _, store in ipairs(stores) do
			if (store :: any):get() then return true end
		end
		return false
	end, stores :: any) :: any
end

function StoreAPI.match<S, T>(
	source: ReadableStore<S>,
	cases:  { [any]: ReadableStore<T> }
): ReadableStore<T>
	local depList: { ReadableStore<any> } = { source }
	for _, caseStore in pairs(cases) do
		table.insert(depList, caseStore)
	end
	return StoreAPI.derive(function(): T
		local key = (source :: any):get()
		local activeCase: ReadableStore<T>? = (cases :: any)[key] or (cases :: any)["_"]
		assert(activeCase, "Store.match: no case and no default (_) for key: " .. tostring(key))
		return (activeCase :: any):get()
	end, depList) :: any
end

-- ── Animation ──────────────────────────────────────────────────────────────────

local RunService: RunService? = nil
do
	local ok, rs = pcall(function() return game:GetService("RunService") end)
	if ok then RunService = rs end
end

local function lerpValue(a: any, b: any, t: number): any
	if type(a) == "number" then
		return (a :: number) + ((b :: number) - (a :: number)) * t
	end
	local valueType = typeof(a)
	if valueType == "Vector2"     then return (a :: Vector2):Lerp(b :: Vector2, t)
	elseif valueType == "Vector3" then return (a :: Vector3):Lerp(b :: Vector3, t)
	elseif valueType == "Color3"  then return (a :: Color3):Lerp(b :: Color3, t)
	elseif valueType == "CFrame"  then return (a :: CFrame):Lerp(b :: CFrame, t)
	end
	return b
end

local EASING_STYLES: { [string]: Enum.EasingStyle } = {
	quad    = Enum.EasingStyle.Quad,
	cubic   = Enum.EasingStyle.Cubic,
	quart   = Enum.EasingStyle.Quart,
	quint   = Enum.EasingStyle.Quint,
	sine    = Enum.EasingStyle.Sine,
	expo    = Enum.EasingStyle.Exponential,
	circ    = Enum.EasingStyle.Circular,
	bounce  = Enum.EasingStyle.Bounce,
	elastic = Enum.EasingStyle.Elastic,
	back    = Enum.EasingStyle.Back,
}
local EASING_DIRS: { [string]: Enum.EasingDirection } = {
	["In"]    = Enum.EasingDirection.In,
	["Out"]   = Enum.EasingDirection.Out,
	["InOut"] = Enum.EasingDirection.InOut,
}

local function parseEasing(easingString: string?): (Enum.EasingStyle, Enum.EasingDirection)
	if not easingString or easingString == "linear" then
		return Enum.EasingStyle.Linear, Enum.EasingDirection.Out
	end
	local easingStyle:     Enum.EasingStyle     = Enum.EasingStyle.Linear
	local easingDirection: Enum.EasingDirection = Enum.EasingDirection.Out
	for name, styleEnum in pairs(EASING_STYLES) do
		if string.find(easingString, name, 1, true) then easingStyle = styleEnum; break end
	end
	for name, dirEnum in pairs(EASING_DIRS) do
		if string.find(easingString, name, 1, true) then easingDirection = dirEnum; break end
	end
	return easingStyle, easingDirection
end

type StoreTweenOptions = {
	time: number?,
	easing: string?,
	delay: number?
}

function StoreAPI.tween<T>(
	source: ReadableStore<T>,
	opts:   StoreTweenOptions?
): ReadableStore<T>
	local options                      = opts or {} :: StoreTweenOptions
	local duration                     = options.time  or 0.3
	local delayTime                    = options.delay or 0
	local easingStyle, easingDirection = parseEasing(options.easing)

	local inner: WritableStore<T> = StoreAPI.value((source :: any):get())

	if not RunService then return inner :: any end

	local TweenService  = game:GetService("TweenService")
	local startValue: any  = (source :: any):get()
	local targetValue: any = startValue
	local elapsed          = 0.0
	local isTweening       = false
	local heartbeatConnection: RBXScriptConnection? = nil

	local function startTween(fromValue: any, toValue: any)
		startValue = fromValue; targetValue = toValue; elapsed = 0.0; isTweening = true
		if not heartbeatConnection then
			heartbeatConnection = (RunService :: RunService).Heartbeat:Connect(function(dt: number)
				if not isTweening then return end
				elapsed = math.min(elapsed + dt, duration + delayTime)
				local progress = math.clamp((elapsed - delayTime) / duration, 0, 1)
				local eased    = TweenService:GetValue(progress, easingStyle, easingDirection)
				;(inner :: any):set(lerpValue(startValue, targetValue, eased))
				if elapsed >= duration + delayTime then
					isTweening = false
					if heartbeatConnection then heartbeatConnection:Disconnect(); heartbeatConnection = nil end
				end
			end)
		end
	end

	local ignoreFirst    = true
	local sourceConnection = (source :: any):subscribe(function(newValue: any, _oldValue: any?)
		if ignoreFirst then ignoreFirst = false; return end
		startTween((inner :: any):get(), newValue)
	end)

	local innerRecord = storeRecords[inner :: any]
	addDestroyHook(innerRecord, function()
		sourceConnection:Disconnect()
		if heartbeatConnection then heartbeatConnection:Disconnect(); heartbeatConnection = nil end
	end)
	return inner :: any
end

type StoreSpringOptions = {
	stiffness: number?,
	damping:   number?,
	mass:      number?,
	clamp:     boolean?,
}

function StoreAPI.spring<T>(
	source: ReadableStore<T>,
	opts:   StoreSpringOptions?
): ReadableStore<T>
	local options     = opts or {} :: StoreSpringOptions
	local stiffness   = options.stiffness or 200
	local damping     = options.damping   or 20
	local mass        = options.mass      or 1
	local shouldClamp = options.clamp     or false

	local initialValue: any = (source :: any):get()
	local inner: WritableStore<T> = StoreAPI.value(initialValue)

	if not RunService then return inner :: any end

	local position: any = initialValue
	local target:   any = initialValue

	local function zeroVelocity(value: any): any
		if type(value) == "number" then return 0 end
		local valueType = typeof(value)
		if valueType == "Vector2" then return Vector2.zero end
		if valueType == "Vector3" then return Vector3.zero end
		return 0
	end

	local velocity: any = zeroVelocity(initialValue)

	local function springStep(pos: any, vel: any, tgt: any, dt: number): (any, any)
		if type(pos) == "number" then
			local acceleration = (tgt - pos) * stiffness / mass - vel * damping / mass
			local newVelocity  = vel + acceleration * dt
			local newPosition  = pos + newVelocity  * dt
			if shouldClamp then
				if tgt >= pos and newPosition > tgt then newPosition = tgt; newVelocity = 0 end
				if tgt <= pos and newPosition < tgt then newPosition = tgt; newVelocity = 0 end
			end
			return newPosition, newVelocity
		end
		local valueType = typeof(pos)
		if valueType == "Vector2" then
			local posVec       = pos :: Vector2
			local velVec       = vel :: Vector2
			local tgtVec       = tgt :: Vector2
			local acceleration = (tgtVec - posVec) * (stiffness / mass) - velVec * (damping / mass)
			local newVelocity  = velVec + acceleration * dt
			return posVec + newVelocity * dt, newVelocity
		elseif valueType == "Vector3" then
			local posVec       = pos :: Vector3
			local velVec       = vel :: Vector3
			local tgtVec       = tgt :: Vector3
			local acceleration = (tgtVec - posVec) * (stiffness / mass) - velVec * (damping / mass)
			local newVelocity  = velVec + acceleration * dt
			return posVec + newVelocity * dt, newVelocity
		end
		return tgt, vel
	end

	local heartbeatConnection: RBXScriptConnection? =
		(RunService :: RunService).Heartbeat:Connect(function(dt: number)
			local newPosition, newVelocity = springStep(position, velocity, target, dt)
			position = newPosition; velocity = newVelocity
			;(inner :: any):set(position)
		end)

	local ignoreFirst    = true
	local sourceConnection = (source :: any):subscribe(function(newValue: any, _oldValue: any?)
		if ignoreFirst then ignoreFirst = false; return end
		target = newValue
	end)

	local innerRecord = storeRecords[inner :: any]
	addDestroyHook(innerRecord, function()
		sourceConnection:Disconnect()
		if heartbeatConnection then heartbeatConnection:Disconnect(); heartbeatConnection = nil end
	end)
	return inner :: any
end

-- ── Collection stores ──────────────────────────────────────────────────────────

type TableStore<K, V> = {
	get:       () -> { [K]: V },
	setKey:    (k: K, v: V) -> (),
	updateKey: (k: K, f: (V?) -> V) -> (),
	delKey:    (k: K) -> (),
	keys:      ReadableStore<{ K }>,
	size:      ReadableStore<number>,
	entries:   ReadableStore<{ [K]: V }>,
}

function StoreAPI.tableStore<K, V>(): TableStore<K, V>
	local data: WritableStore<{ [any]: any }> = StoreAPI.value(table.freeze({}))

	local function current(): { [any]: any }
		return (data :: any):get()
	end

	local keysStore: DerivedStore<{ any }> = StoreAPI.derive(function()
		local keys: { any } = {}
		for key in pairs(current()) do table.insert(keys, key) end
		return keys
	end, { data })

	local sizeStore: DerivedStore<number> = StoreAPI.derive(function()
		local count = 0
		for _ in pairs(current()) do count += 1 end
		return count
	end, { data })

	return {
		get    = current,
		setKey = function(key: any, value: any)
			local copy = table.clone(current())
			copy[key] = value
			;(data :: any):set(table.freeze(copy))
		end,
		updateKey = function(key: any, updater: any)
			local copy = table.clone(current())
			copy[key] = updater(copy[key])
			;(data :: any):set(table.freeze(copy))
		end,
		delKey = function(key: any)
			local copy = table.clone(current())
			copy[key] = nil
			;(data :: any):set(table.freeze(copy))
		end,
		keys    = keysStore :: any,
		size    = sizeStore :: any,
		entries = data :: any,
	}
end

type SetStore<T> = {
	add:    (v: T) -> (),
	remove: (v: T) -> (),
	has:    (v: T) -> boolean,
	values: ReadableStore<{ T }>,
	size:   ReadableStore<number>,
}

function StoreAPI.setStore<T>(): SetStore<T>
	local inner: TableStore<T, boolean> = StoreAPI.tableStore()
	return {
		add    = function(value: any) inner.setKey(value, true) end,
		remove = function(value: any) inner.delKey(value) end,
		has    = function(value: any): boolean return inner.get()[value] == true end,
		values = inner.keys :: any,
		size   = inner.size,
	}
end

function StoreAPI.mapStore<K, V>()
	return StoreAPI.tableStore()
end

-- ── Transactions ───────────────────────────────────────────────────────────────

function StoreAPI.transaction(block: () -> ())
	flushScheduler.transactionDepth += 1
	local ok, err = pcall(block)
	flushScheduler.transactionDepth -= 1
	if not ok then error(err, 2) end
	if flushScheduler.transactionDepth == 0 and #flushScheduler.dirtyOrder > 0 then
		scheduleFlush()
	end
end

function StoreAPI.batch(block: () -> ())
	flushScheduler.transactionDepth += 1
	local ok, err = pcall(block)
	flushScheduler.transactionDepth -= 1
	if not ok then error(err, 2) end
	if flushScheduler.transactionDepth == 0 and #flushScheduler.dirtyOrder > 0 then
		flushNow()
	end
end

-- ── Snapshots & restore ────────────────────────────────────────────────────────

function StoreAPI.snapshot(...: ReadableStore<any>): { [string]: any }
	local snap: { [string]: any } = {}
	for _, store in ipairs({ ... }) do
		local record = storeRecords[store :: any]
		if not record then continue end
		local key = record.name or ("@" .. record.index)
		snap[key] = record.value
	end
	return snap
end

function StoreAPI.restore(snapshot: { [string]: any })
	StoreAPI.transaction(function()
		for name, value in pairs(snapshot) do
			local record = namedStores[name]
			local handle = namedHandles[name]
			if record and handle and not record.destroyed and record.kind == "value" then
				(handle :: any):set(value)
			end
		end
	end)
end

-- ── History ────────────────────────────────────────────────────────────────────

type HistoryHandle<T> = {
	undo:    () -> boolean,
	redo:    () -> boolean,
	clear:   () -> (),
	canUndo: ReadableStore<boolean>,
	canRedo: ReadableStore<boolean>,
}

function StoreAPI.history<T>(targetStore: WritableStore<T>, limit: number?): HistoryHandle<T>
	local maxLength              = limit or 100
	local undoStack: { T }       = {}
	local redoStack: { T }       = {}
	local canUndoStore: WritableStore<boolean> = StoreAPI.value(false)
	local canRedoStore: WritableStore<boolean> = StoreAPI.value(false)

	local function updateFlags()
		(canUndoStore :: any):set(#undoStack > 0);
		(canRedoStore :: any):set(#redoStack > 0)
	end

	local skipNext = false

	;(targetStore :: any):subscribe(function(_newValue: T, oldValue: T?)
		-- subscribe always delivers initial value with oldValue = nil; skip that.
		if oldValue == nil then return end
		if skipNext then skipNext = false; return end
		table.insert(undoStack, oldValue)
		if #undoStack > maxLength then table.remove(undoStack, 1) end
		table.clear(redoStack)
		updateFlags()
	end)

	return {
		undo = function(): boolean
			if #undoStack == 0 then return false end
			local previousValue = table.remove(undoStack)
			table.insert(redoStack, (targetStore :: any):get())
			skipNext = true
			;(targetStore :: any):set(previousValue)
			updateFlags()
			return true
		end,
		redo = function(): boolean
			if #redoStack == 0 then return false end
			local nextValue = table.remove(redoStack)
			table.insert(undoStack, (targetStore :: any):get())
			skipNext = true
			;(targetStore :: any):set(nextValue)
			updateFlags()
			return true
		end,
		clear = function()
			table.clear(undoStack)
			table.clear(redoStack)
			updateFlags()
		end,
		canUndo = canUndoStore :: any,
		canRedo = canRedoStore :: any,
	}
end

-- ── Populate forward ref & export ──────────────────────────────────────────────

for key, value in pairs(StoreAPI) do
	storeAPIRef[key] = value
end
storeAPIRef.table = StoreAPI.tableStore
storeAPIRef.set   = StoreAPI.setStore
storeAPIRef.map   = StoreAPI.mapStore

table.freeze(storeMethods)
return table.freeze(storeAPIRef)

