--!strict
--!optimize 2

-- FSM: hierarchical state machine runtime.
--   Organises modes (states), manages lifecycles (onEnter/onExit/onUpdate),
--   scopes Rules and Tasks to modes, and supports guarded/queued transitions.
--
-- Safety model (same as Signal/Store/Rule/Task)
--   Handles are frozen opaque tables. All mutable state lives in
--   module-private weak tables keyed by identity.
--   __metatable = "ModeHandle" / "FSM" blocks getmetatable().
--
-- Reactive cross-FSM properties (exposed via FSM_META __index, not in type)
--   fsm.activeStore       ReadableStore<string>  — current leaf mode name
--   fsm.transitionSignal  Signal<{...}>          — transitions as first-class signal
--   fsm:isActiveStore(name) ReadableStore<boolean> — lazy boolean store per mode
--
-- Scope protocol
--   ModeHandle implements _ruleAttached(rule) — called by Rule:attach(mode).
--   Rules are enabled with ctx on mode enter, disabled on mode exit, disposed
--   on FSM dispose.
--
-- Frame coalescing (singleSwitchPerFrame=true, default)
--   Multiple switch() calls in one frame collapse to the last request via a
--   single deferred performTransition.
--
-- Re-entrancy safety
--   switch() called during enter/exit is queued (or dropped) per deferral policy.
--   After performTransition completes, the queue is drained one entry per frame.

local TaskModule      = require(script.Parent.Task)
local StoreModule     = require(script.Parent.Store)
local SignalModule    = require(script.Parent.Signal)
local SchedulerModule = require(script.Parent.Internal.Scheduler)
local TracerModule    = require(script.Parent.Internal.Tracer)
local FSMTypes        = require(script.Parent.Types.FSMTypes)

local Scheduler = SchedulerModule.Scheduler

-- ── Internal type aliases ──────────────────────────────────────────────────────

export type GuardOpts = FSMTypes.GuardOpts
type Policy    = FSMTypes.FSMPipelinePolicy

-- ── Internal state types ───────────────────────────────────────────────────────

type GuardEntry = {
	to:         string,
	when:       any,        -- ReadableStore<boolean> | (ctx)->boolean
	isStore:    boolean,    -- has :get(); false = predicate
	opts:       GuardOpts,
	connection: any?,       -- active Signal Connection; nil when mode is inactive
}

type ModeRecord = {
	handle:          any,       -- back-ref to frozen ModeHandle
	label:           string,
	fsmHandle:       any,       -- owning FSM handle
	parentHandle:    any?,      -- explicit parent set via :add(childModeHandle)
	tagLabel:        string?,

	enterFns:        { (any, string?) -> any? },
	exitFns:         { (any, string?) -> any? },
	updateFns:       { (any, number) -> () },

	rules:           { any },           -- Rule handles: enable on enter, disable on exit
	factories:       { () -> any },     -- called on enter; return Task or ()->()
	guardEntries:    { GuardEntry },

	taskGroup:       any,               -- TaskGroup; reused across activations
	activeDisposers: { () -> () },      -- from onEnter/factory returns; called on exit
	updateConn:      any?,              -- RunService.Heartbeat Connection; nil when inactive

	destroyed: boolean,
}

type FSMRecord = {
	handle:  any,
	ctx:     any,
	policy:  Policy,

	modeRegistry:    { [string]: any },    -- name -> ModeHandle
	activePath:      { string },           -- root → leaf
	historyMap:      { [string]: string }, -- parentName -> last-active-child-name

	isTransitioning: boolean,
	switchQueue:     { { name: string, reason: string? } },

	frameRequest:    { name: string, reason: string? }?,
	framePending:    boolean,

	activeStore:      any,              -- WritableStore<string>
	isActiveCache:    { [string]: any }, -- name -> WritableStore<boolean>
	transitionSignal: any,              -- Signal<{ from: string, to: string, reason: string? }>

	regions:     { any },  -- sub-FSM handles

	startCalled: boolean,
	destroyed:   boolean,
}

-- ── Weak state tables ──────────────────────────────────────────────────────────

local modeRecords: { [any]: ModeRecord } =
	setmetatable({}, { __mode = "k" } :: { __mode: "k" }) :: any
local fsmRecords: { [any]: FSMRecord } =
	setmetatable({}, { __mode = "k" } :: { __mode: "k" }) :: any

-- ── Public type exports ────────────────────────────────────────────────────────

export type Connection        = FSMTypes.Connection
export type FSMPipelinePolicy = FSMTypes.FSMPipelinePolicy
export type ModeHandle        = FSMTypes.ModeHandle
export type FSM               = FSMTypes.FSM

-- ── Diagnostics ────────────────────────────────────────────────────────────────

export type TraceEvent = {
	event: string,
	fsm:   string?,
	mode:  string?,
	extra: any?,
}

local tracer = TracerModule.create()

local function emitTrace(fsmRecord: FSMRecord, event: string, modeName: string?, extra: any?)
	if not tracer.hasHandler() and not fsmRecord.policy.trace then return end
	tracer.emit({ event = event, fsm = fsmRecord.policy.tag, mode = modeName, extra = extra })
end

-- ── Default policy ─────────────────────────────────────────────────────────────

local DEFAULT_POLICY: Policy = table.freeze({
	singleSwitchPerFrame = true,
	cancelTasksOnExit    = true,
	ordering             = "exitSelfFirst",
	deferral             = "queue",
	trace                = false,
	tag                  = nil,
} :: Policy)

-- ── Method tables (declared early so helpers can reference) ───────────────────

local modeMethods = {}
local fsmMethods  = {}

local MODE_META = {
	__metatable = "ModeHandle",
	__newindex  = function(_, key: string) error("ModeHandle: '" .. key .. "' is read-only", 2) end,
	__index     = modeMethods,
}

local FSM_META = {
	__metatable = "FSM",
	__newindex  = function(_, key: string) error("FSM: '" .. key .. "' is read-only", 2) end,
	__index     = function(self, key: string): any
		if key == "activeStore"      then return fsmRecords[self] and fsmRecords[self].activeStore end
		if key == "transitionSignal" then return fsmRecords[self] and fsmRecords[self].transitionSignal end
		return fsmMethods[key]
	end,
}

-- ── Forward declaration (performTransition references fsmMethods:switch) ──────

local performTransition: (fsmRecord: FSMRecord, toName: string, reason: string?) -> ()

-- ── Path & hierarchy helpers ───────────────────────────────────────────────────

-- Infers parent name from dot-separated naming convention.
-- "Menu.Inventory" -> "Menu" (only if "Menu" exists in modeRegistry).
local function inferParentName(fsmRecord: FSMRecord, name: string): string?
	local prefix = name:match("^(.+)%.[^.]+$")
	if prefix and fsmRecord.modeRegistry[prefix] then return prefix end
	return nil
end

-- Builds root-to-leaf path for a leaf mode.
local function computePathToRoot(fsmRecord: FSMRecord, leafName: string): { string }
	local path: { string } = {}
	local current: string? = leafName
	while current do
		table.insert(path, 1, current)
		local modeHandle = fsmRecord.modeRegistry[current]
		local modeRecord = modeHandle and modeRecords[modeHandle]
		if modeRecord and modeRecord.parentHandle then
			local parentRecord = modeRecords[modeRecord.parentHandle]
			current = parentRecord and parentRecord.label or nil
		else
			current = inferParentName(fsmRecord, current)
		end
	end
	return path
end

local function isInActivePath(fsmRecord: FSMRecord, name: string): boolean
	for _, pathName in ipairs(fsmRecord.activePath) do
		if pathName == name then return true end
	end
	return false
end

-- Returns index of the deepest common ancestor between two paths (0 = no common prefix).
local function findLowestCommonAncestor(fromPath: { string }, toPath: { string }): number
	local commonDepth = 0
	local minLength   = math.min(#fromPath, #toPath)
	for i = 1, minLength do
		if fromPath[i] == toPath[i] then commonDepth = i else break end
	end
	return commonDepth
end

-- Modes to exit in the correct order.
local function collectExitNodes(
	fromPath:  { string },
	ancestorDepth: number,
	ordering:  string?
): { string }
	local exitOrder: { string } = {}
	for i = #fromPath, ancestorDepth + 1, -1 do
		table.insert(exitOrder, fromPath[i])
	end
	if ordering == "exitParentsFirst" then
		local reversed: { string } = {}
		for i = #exitOrder, 1, -1 do table.insert(reversed, exitOrder[i]) end
		return reversed
	end
	return exitOrder  -- default exitSelfFirst: leaf first
end

-- Modes to enter in the correct order (always parent → leaf).
local function collectEnterNodes(toPath: { string }, ancestorDepth: number): { string }
	local enterOrder: { string } = {}
	for i = ancestorDepth + 1, #toPath do
		table.insert(enterOrder, toPath[i])
	end
	return enterOrder
end

-- ── Guard helpers ──────────────────────────────────────────────────────────────

local function scheduleGuardSwitch(fsmRecord: FSMRecord, entry: GuardEntry)
	local reason = entry.opts and entry.opts.reason or nil
	if entry.opts and entry.opts.defer then
		Scheduler.defer(function()
			if not fsmRecord.destroyed then
				(fsmMethods :: any).switch(fsmRecord.handle, entry.to, { reason = reason })
			end
		end)
	else
		(fsmMethods :: any).switch(fsmRecord.handle, entry.to, { reason = reason })
	end
end

local function activateGuards(fsmRecord: FSMRecord, modeRecord: ModeRecord)
	-- Collect guards already true on enter; take only the highest-priority one.
	local immediateEntries: { GuardEntry } = {}

	for _, entry in ipairs(modeRecord.guardEntries) do
		if entry.isStore then
			local guardStore = entry.when :: any
			-- Subscribe to future changes.
			if type(guardStore.changed) == "function" then
				entry.connection = (guardStore:changed() :: any):connect(function(event: any)
					if event.new == true and not fsmRecord.destroyed then
						scheduleGuardSwitch(fsmRecord, entry)
					end
				end)
			end
			-- Check current value.
			if (guardStore :: any):get() == true then
				table.insert(immediateEntries, entry)
			end
		else
			local ok, result = pcall(entry.when :: any, fsmRecord.ctx)
			if ok and result == true then
				table.insert(immediateEntries, entry)
			end
		end
	end

	if #immediateEntries > 0 then
		table.sort(immediateEntries, function(a: GuardEntry, b: GuardEntry)
			return (a.opts.priority or 0) > (b.opts.priority or 0)
		end)
		scheduleGuardSwitch(fsmRecord, immediateEntries[1])
	end
end

local function deactivateGuards(modeRecord: ModeRecord)
	for _, entry in ipairs(modeRecord.guardEntries) do
		if entry.connection then
			(entry.connection :: any):Disconnect()
			entry.connection = nil
		end
	end
end

-- ── onUpdate helper ────────────────────────────────────────────────────────────

local function connectHeartbeatUpdate(fsmRecord: FSMRecord, modeRecord: ModeRecord)
	if #modeRecord.updateFns == 0 then return end
	local ok, runService = pcall(function() return game:GetService("RunService") end)
	if not ok or not runService then return end
	modeRecord.updateConn = (runService :: any).Heartbeat:Connect(function(dt: number)
		for _, fn in ipairs(modeRecord.updateFns) do
			pcall(fn, fsmRecord.ctx, dt)
		end
	end)
end

-- ── Lifecycle functions ────────────────────────────────────────────────────────

local function enterMode(fsmRecord: FSMRecord, modeName: string, fromName: string)
	local modeHandle = fsmRecord.modeRegistry[modeName]
	if not modeHandle then return end
	local modeRecord = modeRecords[modeHandle]
	if not modeRecord or modeRecord.destroyed then return end

	-- Enable rules.
	for _, rule in ipairs(modeRecord.rules) do
		(rule :: any):enable(fsmRecord.ctx)
	end

	activateGuards(fsmRecord, modeRecord)
	connectHeartbeatUpdate(fsmRecord, modeRecord)

	-- Run enter functions; collect Tasks and disposers.
	for _, fn in ipairs(modeRecord.enterFns) do
		local ok, result = pcall(fn, fsmRecord.ctx, if fromName == "" then nil else fromName)
		if ok then
			if type(result) == "function" then
				table.insert(modeRecord.activeDisposers, result :: any)
			elseif type(result) == "table" and type((result :: any).finally) == "function" then
				modeRecord.taskGroup:add(result)
			end
		end
	end

	-- Run factories.
	for _, fn in ipairs(modeRecord.factories) do
		local ok, result = pcall(fn)
		if ok then
			if type(result) == "function" then
				table.insert(modeRecord.activeDisposers, result :: any)
			elseif type(result) == "table" and type((result :: any).finally) == "function" then
				modeRecord.taskGroup:add(result)
			end
		end
	end

	emitTrace(fsmRecord, "FSM.Enter", modeName)
end

local function exitMode(fsmRecord: FSMRecord, modeName: string, toName: string)
	local modeHandle = fsmRecord.modeRegistry[modeName]
	if not modeHandle then return end
	local modeRecord = modeRecords[modeHandle]
	if not modeRecord or modeRecord.destroyed then return end

	emitTrace(fsmRecord, "FSM.Exit", modeName)

	-- Disconnect per-frame update.
	if modeRecord.updateConn then
		(modeRecord.updateConn :: any):Disconnect()
		modeRecord.updateConn = nil
	end

	deactivateGuards(modeRecord)

	-- Run exit functions; function returns are called immediately (within exit).
	for _, fn in ipairs(modeRecord.exitFns) do
		local ok, result = pcall(fn, fsmRecord.ctx, if toName == "" then nil else toName)
		if ok then
			if type(result) == "function" then
				pcall(result)
			elseif type(result) == "table" and type((result :: any).finally) == "function" then
				modeRecord.taskGroup:add(result)
			end
		end
	end

	-- Run disposers collected from onEnter/factory returns.
	for _, disposer in ipairs(modeRecord.activeDisposers) do pcall(disposer) end
	modeRecord.activeDisposers = {}

	-- Disable rules.
	for _, rule in ipairs(modeRecord.rules) do
		(rule :: any):disable()
	end

	-- Cancel tasks.
	if fsmRecord.policy.cancelTasksOnExit ~= false then
		local taskCount = modeRecord.taskGroup:size()
		modeRecord.taskGroup:cancelAll(TaskModule.Reason.ModeExit)
		if taskCount > 0 then emitTrace(fsmRecord, "FSM.TasksCancelled", modeName, taskCount) end
	end
end

-- ── performTransition ──────────────────────────────────────────────────────────

performTransition = function(fsmRecord: FSMRecord, toName: string, reason: string?)
	if fsmRecord.destroyed then return end
	if not fsmRecord.modeRegistry[toName] then
		warn("FSM: mode '" .. toName .. "' not registered")
		return
	end

	local fromLeaf = fsmRecord.activePath[#fsmRecord.activePath] or ""
	if fromLeaf == toName then return end

	local fromPath              = fsmRecord.activePath
	local toPath                = computePathToRoot(fsmRecord, toName)
	local lowestCommonAncestorDepth = findLowestCommonAncestor(fromPath, toPath)

	fsmRecord.isTransitioning = true
	emitTrace(fsmRecord, "FSM.SwitchRequested", toName, { from = fromLeaf, reason = reason })

	-- Exit.
	local exitNodes = collectExitNodes(fromPath, lowestCommonAncestorDepth, fsmRecord.policy.ordering)
	for _, name in ipairs(exitNodes) do
		exitMode(fsmRecord, name, toName)
	end

	-- Record history: last active child of each exited parent.
	if #fromPath > 1 then
		fsmRecord.historyMap[fromPath[#fromPath - 1]] = fromPath[#fromPath]
	end

	-- Update state.
	fsmRecord.activePath = toPath
	fsmRecord.activeStore:set(toName)
	for name, boolStore in pairs(fsmRecord.isActiveCache) do
		local isActive = false
		for _, pathName in ipairs(toPath) do
			if pathName == name then isActive = true; break end
		end
		boolStore:set(isActive)
	end

	-- Enter.
	local enterNodes = collectEnterNodes(toPath, lowestCommonAncestorDepth)
	for _, name in ipairs(enterNodes) do
		enterMode(fsmRecord, name, fromLeaf)
	end

	fsmRecord.isTransitioning = false

	-- Fire transition signal.
	fsmRecord.transitionSignal:fire({ from = fromLeaf, to = toName, reason = reason })

	-- Drain queue (one per frame for determinism).
	if #fsmRecord.switchQueue > 0 then
		local nextRequest = table.remove(fsmRecord.switchQueue, 1) :: { name: string, reason: string? }
		Scheduler.defer(function()
			if not fsmRecord.destroyed then
				performTransition(fsmRecord, nextRequest.name, nextRequest.reason)
			end
		end)
	end
end

-- ── ModeHandle constructor ─────────────────────────────────────────────────────

local function newModeHandle(label: string, fsmHandle: any): any
	local handle = setmetatable({}, MODE_META)
	modeRecords[handle] = {
		handle          = handle,
		label           = label,
		fsmHandle       = fsmHandle,
		parentHandle    = nil,
		tagLabel        = nil,
		enterFns        = {},
		exitFns         = {},
		updateFns       = {},
		rules           = {},
		factories       = {},
		guardEntries    = {},
		taskGroup       = TaskModule.group({ name = label }),
		activeDisposers = {},
		updateConn      = nil,
		destroyed       = false,
	}
	return handle
end

-- ── ModeHandle methods ─────────────────────────────────────────────────────────

function modeMethods:name(): string
	local modeRecord = modeRecords[self]
	return modeRecord and (modeRecord.tagLabel or modeRecord.label) or ""
end

function modeMethods:parent(): ModeHandle?
	local modeRecord = modeRecords[self]
	return modeRecord and modeRecord.parentHandle :: any or nil
end

function modeMethods:onEnter(fn: (any, string?) -> any?): ModeHandle
	local modeRecord = modeRecords[self]
	assert(modeRecord and not modeRecord.destroyed, "ModeHandle.onEnter: handle is destroyed")
	table.insert(modeRecord.enterFns, fn)
	return self :: any
end

function modeMethods:onExit(fn: (any, string?) -> any?): ModeHandle
	local modeRecord = modeRecords[self]
	assert(modeRecord and not modeRecord.destroyed, "ModeHandle.onExit: handle is destroyed")
	table.insert(modeRecord.exitFns, fn)
	return self :: any
end

function modeMethods:onUpdate(fn: (any, number) -> ()): ModeHandle
	local modeRecord = modeRecords[self]
	assert(modeRecord and not modeRecord.destroyed, "ModeHandle.onUpdate: handle is destroyed")
	table.insert(modeRecord.updateFns, fn)
	return self :: any
end

function modeMethods:add(x: any): ModeHandle
	local modeRecord = modeRecords[self]
	assert(modeRecord and not modeRecord.destroyed, "ModeHandle.add: handle is destroyed")

	local handleType = getmetatable(x)

	if handleType == "Rule" then
		table.insert(modeRecord.rules, x)
		-- If mode is currently active, enable immediately.
		local fsmRecord = fsmRecords[modeRecord.fsmHandle]
		if fsmRecord and isInActivePath(fsmRecord, modeRecord.label) then
			x:enable(fsmRecord.ctx)
		end

	elseif handleType == "Task" then
		modeRecord.taskGroup:add(x)

	elseif handleType == "ModeHandle" then
		-- Register parent-child relationship.
		local childRecord = modeRecords[x]
		if childRecord then childRecord.parentHandle = self end

	elseif type(x) == "function" then
		table.insert(modeRecord.factories, x)
		-- If mode is currently active, run the factory immediately.
		local fsmRecord = fsmRecords[modeRecord.fsmHandle]
		if fsmRecord and isInActivePath(fsmRecord, modeRecord.label) then
			local ok, result = pcall(x)
			if ok then
				if type(result) == "function" then
					table.insert(modeRecord.activeDisposers, result)
				elseif type(result) == "table" and type((result :: any).finally) == "function" then
					modeRecord.taskGroup:add(result)
				end
			end
		end
	end

	return self :: any
end

function modeMethods:guard(to: string, when: any, opts: GuardOpts?): ModeHandle
	local modeRecord = modeRecords[self]
	assert(modeRecord and not modeRecord.destroyed, "ModeHandle.guard: handle is destroyed")
	table.insert(modeRecord.guardEntries, {
		to         = to,
		when       = when,
		isStore    = type(when) == "table" and type((when :: any).get) == "function",
		opts       = opts or {},
		connection = nil,
	})
	return self :: any
end

function modeMethods:taskGroup(): any
	local modeRecord = modeRecords[self]
	assert(modeRecord and not modeRecord.destroyed, "ModeHandle.taskGroup: handle is destroyed")
	return modeRecord.taskGroup
end

function modeMethods:tag(label: string): ModeHandle
	local modeRecord = modeRecords[self]
	assert(modeRecord and not modeRecord.destroyed, "ModeHandle.tag: handle is destroyed")
	modeRecord.tagLabel = label
	return self :: any
end

-- Called by Rule:attach(mode) — scope protocol.
function modeMethods:_ruleAttached(rule: any)
	local modeRecord = modeRecords[self]
	if not modeRecord or modeRecord.destroyed then return end
	table.insert(modeRecord.rules, rule)
	-- Enable immediately if mode is currently active.
	local fsmRecord = fsmRecords[modeRecord.fsmHandle]
	if fsmRecord and isInActivePath(fsmRecord, modeRecord.label) then
		rule:enable(fsmRecord.ctx)
	end
end

-- ── FSM constructor ────────────────────────────────────────────────────────────

local function newFSM(ctx: any, opts: Policy?): any
	local merged: { [string]: any } = {}
	for key, value in pairs(DEFAULT_POLICY :: any) do merged[key] = value end
	if opts then
		for key, value in pairs(opts :: any) do merged[key] = value end
	end
	local policy = table.freeze(merged) :: Policy

	local handle = setmetatable({}, FSM_META)
	fsmRecords[handle] = {
		handle           = handle,
		ctx              = ctx,
		policy           = policy,
		modeRegistry     = {},
		activePath       = {},
		historyMap       = {},
		isTransitioning  = false,
		switchQueue      = {},
		frameRequest     = nil,
		framePending     = false,
		activeStore      = StoreModule.value(""),
		isActiveCache    = {},
		transitionSignal = SignalModule.new(),
		regions          = {},
		startCalled      = false,
		destroyed        = false,
	}
	return handle
end

-- ── FSM methods ────────────────────────────────────────────────────────────────

function fsmMethods:context(): any
	local fsmRecord = fsmRecords[self]
	assert(fsmRecord and not fsmRecord.destroyed, "FSM.context: FSM is disposed")
	return fsmRecord.ctx
end

function fsmMethods:mode(name: string, builder: ((ModeHandle) -> ())?): ModeHandle
	local fsmRecord = fsmRecords[self]
	assert(fsmRecord and not fsmRecord.destroyed, "FSM.mode: FSM is disposed")
	local existing = fsmRecord.modeRegistry[name]
	if existing then
		if builder then builder(existing) end
		return existing :: any
	end
	local modeHandle = newModeHandle(name, self)
	fsmRecord.modeRegistry[name] = modeHandle
	if builder then builder(modeHandle) end
	return modeHandle :: any
end

function fsmMethods:region(name: string, builder: (FSM) -> ()): ModeHandle
	local fsmRecord = fsmRecords[self]
	assert(fsmRecord and not fsmRecord.destroyed, "FSM.region: FSM is disposed")
	local regionFsm = newFSM(fsmRecord.ctx, fsmRecord.policy)
	builder(regionFsm)
	table.insert(fsmRecord.regions, regionFsm)
	-- Return a synthetic ModeHandle for tagging/inspection.
	local syntheticHandle = newModeHandle(name, self)
	fsmRecord.modeRegistry[name] = syntheticHandle
	return syntheticHandle :: any
end

function fsmMethods:start(name: string)
	local fsmRecord = fsmRecords[self]
	assert(fsmRecord and not fsmRecord.destroyed, "FSM.start: FSM is disposed")
	assert(not fsmRecord.startCalled, "FSM.start: already started")
	assert(fsmRecord.modeRegistry[name], "FSM.start: mode '" .. name .. "' not registered")
	fsmRecord.startCalled = true

	local toPath = computePathToRoot(fsmRecord, name)
	fsmRecord.activePath = toPath

	fsmRecord.activeStore:set(name)
	for modeName, boolStore in pairs(fsmRecord.isActiveCache) do
		local isActive = false
		for _, pathName in ipairs(toPath) do
			if pathName == modeName then isActive = true; break end
		end
		boolStore:set(isActive)
	end

	for _, modeName in ipairs(toPath) do
		enterMode(fsmRecord, modeName, "")
	end

	emitTrace(fsmRecord, "FSM.Start", name)
	fsmRecord.transitionSignal:fire({ from = "", to = name, reason = "start" })
end

function fsmMethods:switch(name: string, opts: { immediate: boolean?, reason: string? }?)
	local fsmRecord = fsmRecords[self]
	if not fsmRecord or fsmRecord.destroyed then return end

	local reason    = opts and opts.reason or nil
	local immediate = opts and opts.immediate or false

	if immediate then
		performTransition(fsmRecord, name, reason)
		return
	end

	if fsmRecord.isTransitioning then
		if fsmRecord.policy.deferral == "drop" then return end
		table.insert(fsmRecord.switchQueue, { name = name, reason = reason })
		return
	end

	if fsmRecord.policy.singleSwitchPerFrame ~= false then
		fsmRecord.frameRequest = { name = name, reason = reason }
		if not fsmRecord.framePending then
			fsmRecord.framePending = true
			Scheduler.defer(function()
				fsmRecord.framePending = false
				local request          = fsmRecord.frameRequest
				fsmRecord.frameRequest = nil
				if request and not fsmRecord.destroyed then
					performTransition(fsmRecord, request.name, request.reason)
				end
			end)
		end
	else
		Scheduler.defer(function()
			if not fsmRecord.destroyed then
				performTransition(fsmRecord, name, reason)
			end
		end)
	end
end

function fsmMethods:current(): string
	local fsmRecord = fsmRecords[self]
	assert(fsmRecord, "FSM.current: invalid FSM handle")
	return fsmRecord.activePath[#fsmRecord.activePath] or ""
end

function fsmMethods:isActive(name: string): boolean
	local fsmRecord = fsmRecords[self]
	assert(fsmRecord, "FSM.isActive: invalid FSM handle")
	return isInActivePath(fsmRecord, name)
end

function fsmMethods:inMode(name: string): boolean
	return (fsmMethods :: any).isActive(self, name)
end

function fsmMethods:path(): { string }
	local fsmRecord = fsmRecords[self]
	assert(fsmRecord, "FSM.path: invalid FSM handle")
	return table.clone(fsmRecord.activePath)
end

function fsmMethods:history(parentName: string): string?
	local fsmRecord = fsmRecords[self]
	assert(fsmRecord, "FSM.history: invalid FSM handle")
	return fsmRecord.historyMap[parentName]
end

function fsmMethods:snapshot(): { activePath: { string } }
	local fsmRecord = fsmRecords[self]
	assert(fsmRecord, "FSM.snapshot: invalid FSM handle")
	return { activePath = table.clone(fsmRecord.activePath) }
end

function fsmMethods:restore(snap: { activePath: { string } })
	local fsmRecord = fsmRecords[self]
	assert(fsmRecord and not fsmRecord.destroyed, "FSM.restore: FSM is disposed")
	if snap.activePath and #snap.activePath > 0 then
		local leaf = snap.activePath[#snap.activePath]
		;(fsmMethods :: any).switch(self, leaf, { reason = "restore" })
	end
end

function fsmMethods:onTransition(fn: (from: string, to: string, reason: string?) -> ()): Connection
	local fsmRecord = fsmRecords[self]
	assert(fsmRecord and not fsmRecord.destroyed, "FSM.onTransition: FSM is disposed")
	return (fsmRecord.transitionSignal :: any):connect(function(event: any)
		fn(event.from, event.to, event.reason)
	end) :: any
end

function fsmMethods:policy(opts: FSMPipelinePolicy): FSM
	local fsmRecord = fsmRecords[self]
	assert(fsmRecord and not fsmRecord.destroyed, "FSM.policy: FSM is disposed")
	local merged: { [string]: any } = {}
	for key, value in pairs(fsmRecord.policy :: any) do merged[key] = value end
	for key, value in pairs(opts :: any) do merged[key] = value end
	fsmRecord.policy = table.freeze(merged) :: Policy
	return self :: any
end

function fsmMethods:dispose()
	local fsmRecord = fsmRecords[self]
	if not fsmRecord or fsmRecord.destroyed then return end
	fsmRecord.destroyed = true

	-- Exit active path leaf-first.
	local activePath      = fsmRecord.activePath
	fsmRecord.activePath  = {}
	for i = #activePath, 1, -1 do
		exitMode(fsmRecord, activePath[i], "")
	end

	-- Dispose all rules in all modes.
	for _, modeHandle in pairs(fsmRecord.modeRegistry) do
		local modeRecord = modeRecords[modeHandle]
		if modeRecord and not modeRecord.destroyed then
			for _, rule in ipairs(modeRecord.rules) do
				(rule :: any):dispose()
			end
			modeRecord.destroyed = true
		end
	end

	-- Dispose sub-FSMs.
	for _, region in ipairs(fsmRecord.regions) do
		(region :: any):dispose()
	end

	fsmRecord.transitionSignal:destroy()
	emitTrace(fsmRecord, "FSM.Dispose", nil)
end

-- Lazy boolean store per mode name.
function fsmMethods:isActiveStore(name: string): any
	local fsmRecord = fsmRecords[self]
	assert(fsmRecord, "FSM.isActiveStore: invalid FSM handle")
	if not fsmRecord.isActiveCache[name] then
		fsmRecord.isActiveCache[name] = StoreModule.value(isInActivePath(fsmRecord, name))
	end
	return fsmRecord.isActiveCache[name]
end

-- ── Module API ─────────────────────────────────────────────────────────────────

local FSMAPI: {
	new:          (ctx: any, opts: FSMPipelinePolicy?) -> FSM,
	setTracer:    (fn: ((TraceEvent) -> ())?) -> (),
	setScheduler: (s: { defer: any?, delay: any?, cancel: any?, now: (() -> number)? }) -> (),
} = {} :: any

function FSMAPI.new(ctx: any, opts: FSMPipelinePolicy?): FSM
	return newFSM(ctx, opts) :: any
end

function FSMAPI.setTracer(fn: ((TraceEvent) -> ())?)
	tracer.setHandler(fn)
end

function FSMAPI.setScheduler(s: { defer: any?, delay: any?, cancel: any?, now: (() -> number)? })
	SchedulerModule.override(s)
end

table.freeze(modeMethods)
table.freeze(fsmMethods)
return table.freeze(FSMAPI)

