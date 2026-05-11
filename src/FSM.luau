--!strict
local Connection = require(script.Parent.Connection)
local Context = require(script.Parent.Context)
local ErrorHandler = require(script.Parent.ErrorHandler)
local Rule = require(script.Parent.Rule)
local Scheduler = require(script.Parent.Scheduler)
local Signal = require(script.Parent.Signal)
local Store = require(script.Parent.Store)
local Task = require(script.Parent.Task)

-- ── Types ─────────────────────────────────────────────────────────────────────

export type TransitionEvent = {
	From: string,
	To: string,
	Reason: string?,
	Data: unknown?,
}

export type TransitionFrame = {
	From: string,
	To: string,
	Reason: string?,
	Data: unknown?,
	StartedAt: number,
	Immediate: boolean,
}

export type UpdateFrame = {
	Mode: string,
	StartedAt: number,
}

export type SwitchOptions = {
	Immediate: boolean?,
	Reason: string?,
	Data: unknown?,
}

export type SnapshotOptions = {
	IncludeHistory: boolean?,
}

export type Snapshot = {
	ActivePath: { string },
	History: { [string]: string },
}

export type GuardOptions = {
	Priority: number?,
	Reason: string?,
	Defer: boolean?,
	Data: unknown?,
}

export type Policy = {
	SingleSwitchPerFrame: boolean,
	CancelTasksOnExit: boolean,
	ExitOrdering: string,
	Deferral: string,
	ErrorPolicy: string?,
	Trace: boolean,
	Tag: string?,
}

export type PartialPolicy = {
	SingleSwitchPerFrame: boolean?,
	CancelTasksOnExit: boolean?,
	ExitOrdering: string?,
	Deferral: string?,
	ErrorPolicy: string?,
	Trace: boolean?,
	Tag: string?,
}

export type FSM<Ctx> = {
	Context: (self: FSM<Ctx>) -> Context.Context<Ctx>,
	Mode: (self: FSM<Ctx>, name: string, builder: ((mode: Mode<Ctx>) -> ())?) -> Mode<Ctx>,
	HasMode: (self: FSM<Ctx>, name: string) -> boolean,
	GetMode: (self: FSM<Ctx>, name: string) -> Mode<Ctx>?,
	Start: (self: FSM<Ctx>, name: string) -> (),
	Switch: (self: FSM<Ctx>, name: string, opts: SwitchOptions?) -> (),
	CanSwitch: (self: FSM<Ctx>, name: string) -> boolean,
	Current: (self: FSM<Ctx>) -> string,
	IsActive: (self: FSM<Ctx>, name: string) -> boolean,
	InMode: (self: FSM<Ctx>, name: string) -> boolean,
	Path: (self: FSM<Ctx>) -> { string },
	History: (self: FSM<Ctx>, parentName: string) -> string?,
	SwitchToHistory: (self: FSM<Ctx>, parentName: string, opts: SwitchOptions?) -> (),
	ClearHistory: (self: FSM<Ctx>, parentName: string?) -> (),
	Snapshot: (self: FSM<Ctx>, opts: SnapshotOptions?) -> Snapshot,
	Restore: (self: FSM<Ctx>, snapshot: Snapshot, opts: SwitchOptions?) -> (),
	OnTransition: (self: FSM<Ctx>, fn: (event: TransitionEvent) -> ()) -> Connection.Connection,
	WaitForTransition: (self: FSM<Ctx>) -> TransitionEvent,
	Policy: (self: FSM<Ctx>, opts: PartialPolicy) -> FSM<Ctx>,
	IsStarted: (self: FSM<Ctx>) -> boolean,
	IsDestroyed: (self: FSM<Ctx>) -> boolean,
	Destroy: (self: FSM<Ctx>) -> (),
	IsActiveStore: (self: FSM<Ctx>, name: string) -> Store.ReadableStore<boolean>,
	ActiveStore: Store.ReadableStore<string>,
	TransitionSignal: Signal.Signal<TransitionEvent>,
}

export type Mode<Ctx> = {
	Name: (self: Mode<Ctx>) -> string,
	Parent: (self: Mode<Ctx>) -> Mode<Ctx>?,
	OnEnter: (self: Mode<Ctx>, fn: (ctx: Context.Context<Ctx>, frame: TransitionFrame) -> any) -> Mode<Ctx>,
	OnExit: (self: Mode<Ctx>, fn: (ctx: Context.Context<Ctx>, frame: TransitionFrame) -> any) -> Mode<Ctx>,
	OnUpdate: (self: Mode<Ctx>, fn: (ctx: Context.Context<Ctx>, dt: number, frame: UpdateFrame) -> ()) -> Mode<Ctx>,
	Add: (self: Mode<Ctx>, resource: any) -> Mode<Ctx>,
	Provide: (self: Mode<Ctx>, providerOrValues: any) -> Mode<Ctx>,
	Guard: (self: Mode<Ctx>, to: string, guard: any, opts: GuardOptions?) -> Mode<Ctx>,
	TaskGroup: (self: Mode<Ctx>) -> Task.TaskGroup,
	Tag: (self: Mode<Ctx>, label: string) -> Mode<Ctx>,
	IsActive: (self: Mode<Ctx>) -> boolean,
	IsDestroyed: (self: Mode<Ctx>) -> boolean,
	Destroy: (self: Mode<Ctx>) -> (),
}

-- ── Internal records ──────────────────────────────────────────────────────────

type PolicyRecord = {
	SingleSwitchPerFrame: boolean,
	CancelTasksOnExit: boolean,
	ExitOrdering: string,
	Deferral: string,
	ErrorPolicy: string?,
	Trace: boolean,
	Tag: string?,
}

type GuardEntry = {
	To: string,
	GuardValue: any,
	Priority: number,
	InsertIdx: number,
	Reason: string?,
	Defer: boolean,
	Data: unknown?,
}

type ModeRecord = {
	Destroyed: boolean,
	FSMHandle: any,
	RegistryName: string,
	Label: string?,
	ParentHandle: any?,

	OnEnterFns: { (any, any) -> any },
	OnExitFns: { (any, any) -> any },
	OnUpdateFns: { (any, number, any) -> () },
	Providers: { any },
	Guards: { GuardEntry },
	GuardInsertCount: number,

	AttachedRules: { any },
	AttachedRuleSet: { [any]: boolean },
	AddedFactories: { (any, any) -> any },
	TaskGroupHandle: any?,

	-- Per-activation (nil when inactive)
	ActiveCtx: any?,
	ActiveDisposers: { () -> () },
	UpdateConns: { Connection.Connection },
	GuardConns: { Connection.Connection },
	ActiveStartedAt: number?,
}

type FSMRecord = {
	Destroyed: boolean,
	Disposing: boolean,
	Started: boolean,
	Transitioning: boolean,
	CtxHandle: any,
	Modes: { [string]: any },
	ActivePath: { string },
	HistoryMap: { [string]: string },
	Policy: PolicyRecord,
	_activeStoreWritable: any,
	ActiveStore: any,
	_isActiveStores: { [string]: { writable: any, readonly: any } },
	TransitionSignal: any,
	PendingSwitch: { name: string, opts: SwitchOptions? }?,
	DeferScheduled: boolean,
	SwitchQueue: { { name: string, opts: SwitchOptions? } },
}

-- ── Private storage ───────────────────────────────────────────────────────────

local fsmRecords: { [any]: FSMRecord } = setmetatable({}, { __mode = "k" } :: any)
local modeRecords: { [any]: ModeRecord } = setmetatable({}, { __mode = "k" } :: any)

-- ── Tracer ────────────────────────────────────────────────────────────────────

local _tracer: ((any) -> ())? = nil

local function emitTrace(event: string, fsmRec: FSMRecord, extra: { [string]: any }?)
	if not fsmRec.Policy.Trace and _tracer == nil then return end
	if _tracer == nil then return end
	local payload: { [string]: any } = {
		Event = event,
		Tag = fsmRec.Policy.Tag,
	}
	if extra then
		for k, v in extra do
			payload[k] = v
		end
	end
	local ok, err = pcall(_tracer :: any, payload)
	if not ok then
		ErrorHandler.Report({ Module = "FSM", Phase = "Trace", Error = err })
	end
end

-- ── Metatables ────────────────────────────────────────────────────────────────

local fsmMethods = {}
local modeMethods = {}

local fsmMeta = {
	__metatable = "FSM",
	__index = function(self: any, key: string): any
		if key == "ActiveStore" then
			local rec = fsmRecords[self]
			return if rec ~= nil then rec.ActiveStore else nil
		elseif key == "TransitionSignal" then
			local rec = fsmRecords[self]
			return if rec ~= nil then rec.TransitionSignal else nil
		end
		return fsmMethods[key]
	end,
	__newindex = function(_, k: string)
		error("FSM: '" .. k .. "' is read-only", 2)
	end,
}

local modeMeta = {
	__metatable = "FSMMode",
	__index = modeMethods,
	__newindex = function(_, k: string)
		error("Mode: '" .. k .. "' is read-only", 2)
	end,
}

-- ── Policy helpers ────────────────────────────────────────────────────────────

local KNOWN_FSM_POLICY_KEYS: { [string]: boolean } = {
	SingleSwitchPerFrame = true, CancelTasksOnExit = true,
	ExitOrdering = true, Deferral = true,
	ErrorPolicy = true, Trace = true, Tag = true,
}

local function makeDefaultPolicy(): PolicyRecord
	return {
		SingleSwitchPerFrame = true,
		CancelTasksOnExit = true,
		ExitOrdering = "LeafFirst",
		Deferral = "Queue",
		ErrorPolicy = nil,
		Trace = false,
		Tag = nil,
	}
end

local function validateFSMPolicy(policy: any): (boolean, string?)
	if type(policy) ~= "table" then
		return false, "policy must be a table"
	end
	for k in policy do
		if not KNOWN_FSM_POLICY_KEYS[k] then
			return false, "unknown policy key: " .. tostring(k)
		end
	end
	local spf = policy.SingleSwitchPerFrame
	if spf ~= nil and type(spf) ~= "boolean" then
		return false, "SingleSwitchPerFrame must be a boolean"
	end
	local cte = policy.CancelTasksOnExit
	if cte ~= nil and type(cte) ~= "boolean" then
		return false, "CancelTasksOnExit must be a boolean"
	end
	local eo = policy.ExitOrdering
	if eo ~= nil and eo ~= "LeafFirst" and eo ~= "ParentFirst" then
		return false, "ExitOrdering must be 'LeafFirst' or 'ParentFirst'"
	end
	local def = policy.Deferral
	if def ~= nil and def ~= "Queue" and def ~= "Drop" then
		return false, "Deferral must be 'Queue' or 'Drop'"
	end
	local ep = policy.ErrorPolicy
	if ep ~= nil then
		if ep ~= "Throw" and ep ~= "Warn" and ep ~= "Swallow" and ep ~= "Collect" then
			return false, "ErrorPolicy must be 'Throw', 'Warn', 'Swallow', or 'Collect'"
		end
	end
	local tr = policy.Trace
	if tr ~= nil and type(tr) ~= "boolean" then
		return false, "Trace must be a boolean"
	end
	local tag = policy.Tag
	if tag ~= nil and type(tag) ~= "string" then
		return false, "Tag must be a string"
	end
	return true, nil
end

-- ── Mode parent / path helpers ────────────────────────────────────────────────

local function getModeParentName(fsmRec: FSMRecord, modeRec: ModeRecord): string?
	if modeRec.ParentHandle ~= nil then
		local parentRec = modeRecords[modeRec.ParentHandle]
		return if parentRec ~= nil then parentRec.RegistryName else nil
	end
	local name = modeRec.RegistryName
	local lastDot: number? = nil
	for i = #name, 1, -1 do
		if string.sub(name, i, i) == "." then
			lastDot = i
			break
		end
	end
	if lastDot ~= nil then
		local possibleParent = string.sub(name, 1, lastDot - 1)
		if fsmRec.Modes[possibleParent] ~= nil then
			return possibleParent
		end
	end
	return nil
end

local function computePath(fsmRec: FSMRecord, modeName: string): { string }
	local path: { string } = {}
	local current: string? = modeName
	local visited: { [string]: boolean } = {}
	while current ~= nil do
		if visited[current] then break end
		visited[current] = true
		table.insert(path, 1, current)
		local modeHandle = fsmRec.Modes[current]
		if modeHandle == nil then break end
		local modeRec = modeRecords[modeHandle]
		if modeRec == nil then break end
		current = getModeParentName(fsmRec, modeRec)
	end
	return path
end

local function findLCA(fromPath: { string }, toPath: { string }): number
	local lcaIdx = 0
	local minLen = math.min(#fromPath, #toPath)
	for i = 1, minLen do
		if fromPath[i] == toPath[i] then
			lcaIdx = i
		else
			break
		end
	end
	return lcaIdx
end

local function hasCycle(modeHandle: any, candidateParentHandle: any): boolean
	local current = candidateParentHandle
	local visited: { [any]: boolean } = {}
	while current ~= nil do
		if current == modeHandle then return true end
		if visited[current] then break end
		visited[current] = true
		local rec = modeRecords[current]
		if rec == nil then break end
		current = rec.ParentHandle
	end
	return false
end

-- ── IsActiveStore helpers ─────────────────────────────────────────────────────

local function getOrCreateIsActiveStore(fsmRec: FSMRecord, name: string): any
	local entry = fsmRec._isActiveStores[name]
	if entry ~= nil then
		return entry.readonly
	end
	local isActive = false
	for _, m in fsmRec.ActivePath do
		if m == name then isActive = true break end
	end
	local writable = Store.Value(isActive)
	local readonly = Store.Readonly(writable)
	fsmRec._isActiveStores[name] = { writable = writable, readonly = readonly }
	return readonly
end

local function updateIsActiveStores(fsmRec: FSMRecord, fromPath: { string }, toPath: { string })
	local fromSet: { [string]: boolean } = {}
	for _, m in fromPath do fromSet[m] = true end
	local toSet: { [string]: boolean } = {}
	for _, m in toPath do toSet[m] = true end

	for name, entry in fsmRec._isActiveStores do
		local wasActive = fromSet[name] == true
		local isActive = toSet[name] == true
		if wasActive ~= isActive then
			entry.writable:Set(isActive)
		end
	end
end

-- ── Error policy helper ───────────────────────────────────────────────────────

local function handleFSMError(fsmRec: FSMRecord, phase: string, err: any)
	local ep = fsmRec.Policy.ErrorPolicy
	if ep == nil or ep == "Warn" or ep == "Collect" then
		ErrorHandler.Report({ Module = "FSM", Phase = phase, Error = err })
	elseif ep == "Throw" then
		error(err, 0)
	end
	-- Swallow: ignore
end

-- ── Mode exit ─────────────────────────────────────────────────────────────────

local function exitMode(fsmRec: FSMRecord, modeHandle: any, frame: TransitionFrame)
	local modeRec = modeRecords[modeHandle]
	if modeRec == nil or modeRec.ActiveCtx == nil then return end

	local ctx = modeRec.ActiveCtx

	-- 1. Disconnect update connections
	for _, conn in modeRec.UpdateConns do
		conn:Disconnect()
	end
	table.clear(modeRec.UpdateConns)

	-- 2. Disconnect guard watchers
	for _, conn in modeRec.GuardConns do
		conn:Disconnect()
	end
	table.clear(modeRec.GuardConns)

	-- 3. Run OnExit callbacks
	for _, fn in modeRec.OnExitFns do
		local ok, result = pcall(fn, ctx, frame)
		if not ok then
			handleFSMError(fsmRec, "Exit", result)
		else
			if type(result) == "function" then
				local ok2, err2 = pcall(result :: () -> ())
				if not ok2 then
					ErrorHandler.Report({ Module = "FSM", Phase = "ExitDisposer", Error = err2 })
				end
			elseif Task.IsTask(result) then
				ErrorHandler.Report({ Module = "FSM", Phase = "ExitTaskIgnored", Error = "OnExit returned a Task; async exit is not supported" })
			end
		end
	end

	-- 4. Run active disposers
	for _, d in modeRec.ActiveDisposers do
		local ok, err = pcall(d)
		if not ok then
			ErrorHandler.Report({ Module = "FSM", Phase = "ExitDisposer", Error = err })
		end
	end
	table.clear(modeRec.ActiveDisposers)

	-- 5. Disable attached rules
	for _, ruleHandle in modeRec.AttachedRules do
		if Rule.IsRule(ruleHandle) then
			(ruleHandle :: any):Disable()
		end
	end

	-- 6. Cancel task group if CancelTasksOnExit
	if fsmRec.Policy.CancelTasksOnExit and modeRec.TaskGroupHandle ~= nil then
		modeRec.TaskGroupHandle:CancelAll(Task.Reason.ModeExit)
	end

	-- 7. Destroy mode context layer
	if Context.IsContext(ctx) then
		ctx:Destroy()
	end
	modeRec.ActiveCtx = nil
	modeRec.ActiveStartedAt = nil
end

-- ── Mode enter ────────────────────────────────────────────────────────────────

local function enterMode(fsmHandle: any, fsmRec: FSMRecord, modeHandle: any, frame: TransitionFrame)
	local modeRec = modeRecords[modeHandle]
	if modeRec == nil or modeRec.Destroyed then return end

	local startedAt = Scheduler.Now()
	modeRec.ActiveStartedAt = startedAt

	-- 1. Create mode context layer from providers
	local providerValues: { [any]: any } = {}
	local providerCleanups: { () -> () } = {}

	for _, provider in modeRec.Providers do
		if type(provider) == "function" then
			local ok, values, cleanup = pcall(provider, fsmRec.CtxHandle, frame)
			if ok then
				if type(values) == "table" then
					for k, v in values do
						providerValues[k] = v
					end
				end
				if type(cleanup) == "function" then
					table.insert(providerCleanups, cleanup :: () -> ())
				end
			else
				handleFSMError(fsmRec, "Provide", values)
			end
		elseif type(provider) == "table" then
			for k, v in provider do
				providerValues[k] = v
			end
		end
	end

	local modeCtx = fsmRec.CtxHandle:Layer(providerValues, if #providerCleanups > 0 then function()
		for _, c in providerCleanups do
			pcall(c)
		end
	end else nil)
	modeRec.ActiveCtx = modeCtx

	-- 2. Run OnEnter callbacks + 3. collect disposers + 4. add Task returns
	for _, fn in modeRec.OnEnterFns do
		local ok, result = pcall(fn, modeCtx, frame)
		if not ok then
			handleFSMError(fsmRec, "Enter", result)
		else
			if type(result) == "function" then
				table.insert(modeRec.ActiveDisposers, result :: () -> ())
			elseif Task.IsTask(result) then
				if modeRec.TaskGroupHandle == nil then
					modeRec.TaskGroupHandle = Task.Group()
				end
				modeRec.TaskGroupHandle:Add(result)
			end
		end
	end

	-- Factory resources
	for _, factory in modeRec.AddedFactories do
		local ok, result = pcall(factory, modeCtx, frame)
		if not ok then
			ErrorHandler.Report({ Module = "FSM", Phase = "Factory", Error = result })
		else
			if type(result) == "function" then
				table.insert(modeRec.ActiveDisposers, result :: () -> ())
			elseif Task.IsTask(result) then
				if modeRec.TaskGroupHandle == nil then
					modeRec.TaskGroupHandle = Task.Group()
				end
				modeRec.TaskGroupHandle:Add(result)
			end
		end
	end

	-- 5. Enable attached rules
	for _, ruleHandle in modeRec.AttachedRules do
		if Rule.IsRule(ruleHandle) then
			(ruleHandle :: any):Enable(modeCtx)
		end
	end

	-- 6. Connect update callbacks
	for _, updateFn in modeRec.OnUpdateFns do
		local fn = updateFn
		local updateFrame: UpdateFrame = { Mode = modeRec.RegistryName, StartedAt = startedAt }
		local ok, conn = pcall(Scheduler.OnStep, function(dt: number)
			if modeRec.ActiveCtx == nil then return end
			local ok2, err2 = pcall(fn, modeCtx, dt, updateFrame)
			if not ok2 then
				ErrorHandler.Report({ Module = "FSM", Phase = "Update", Error = err2 })
			end
		end)
		if ok then
			table.insert(modeRec.UpdateConns, conn :: Connection.Connection)
		else
			ErrorHandler.Report({ Module = "FSM", Phase = "Update", Error = "FSM.OnUpdate: no update driver available" })
		end
	end

	-- 7 & 8. Activate guards + evaluate immediate function guards
	local fnGuards: { GuardEntry } = {}
	for _, g in modeRec.Guards do
		if Store.IsStore(g.GuardValue) then
			local guardEntry = g
			local conn = (g.GuardValue :: any):Subscribe(function(value: any)
				if value == true and modeRec.ActiveCtx ~= nil then
					local switchOpts: SwitchOptions = {
						Reason = guardEntry.Reason,
						Data = guardEntry.Data,
						Immediate = not guardEntry.Defer,
					}
					fsmMethods.Switch(fsmHandle, guardEntry.To, switchOpts)
				end
			end, { Immediate = false })
			table.insert(modeRec.GuardConns, conn)
		else
			table.insert(fnGuards, g)
		end
	end

	-- Sort function guards by priority desc, then insertIdx asc
	table.sort(fnGuards, function(a: GuardEntry, b: GuardEntry): boolean
		if a.Priority ~= b.Priority then
			return a.Priority > b.Priority
		end
		return a.InsertIdx < b.InsertIdx
	end)

	for _, g in fnGuards do
		local ok, result = pcall(g.GuardValue, modeCtx, frame)
		if ok and result == true then
			local guardEntry = g
			if guardEntry.Defer then
				Scheduler.Defer(function()
					if modeRec.ActiveCtx ~= nil then
						fsmMethods.Switch(fsmHandle, guardEntry.To, {
							Reason = guardEntry.Reason,
							Data = guardEntry.Data,
						})
					end
				end)
			else
				fsmMethods.Switch(fsmHandle, guardEntry.To, {
					Reason = guardEntry.Reason,
					Data = guardEntry.Data,
					Immediate = true,
				})
			end
			break
		end
	end
end

-- ── Transition execution ──────────────────────────────────────────────────────

local function drainSwitchQueue(fsmHandle: any, fsmRec: FSMRecord)
	while #fsmRec.SwitchQueue > 0 and not fsmRec.Destroyed and not fsmRec.Disposing do
		local req = table.remove(fsmRec.SwitchQueue, 1)
		local currentLeaf = fsmRec.ActivePath[#fsmRec.ActivePath] or ""
		if req.name ~= currentLeaf and fsmRec.Modes[req.name] ~= nil then
			fsmMethods.Switch(fsmHandle, req.name, req.opts)
			if fsmRec.Transitioning then break end
		end
	end
end

local function executeTransition(fsmHandle: any, fsmRec: FSMRecord, targetName: string, opts: SwitchOptions?)
	if fsmRec.Transitioning then
		if fsmRec.Policy.Deferral == "Queue" then
			table.insert(fsmRec.SwitchQueue, { name = targetName, opts = opts })
		end
		return
	end

	fsmRec.Transitioning = true

	local fromPath = fsmRec.ActivePath
	local toPath = computePath(fsmRec, targetName)
	local lcaIdx = findLCA(fromPath, toPath)

	local frame: TransitionFrame = {
		From = fromPath[#fromPath] or "",
		To = targetName,
		Reason = opts and opts.Reason or nil,
		Data = opts and opts.Data or nil,
		StartedAt = Scheduler.Now(),
		Immediate = if opts ~= nil then opts.Immediate == true else false,
	}

	-- Build exit list
	local exitModes: { string } = {}
	for i = #fromPath, lcaIdx + 1, -1 do
		table.insert(exitModes, fromPath[i])
	end
	if fsmRec.Policy.ExitOrdering == "ParentFirst" then
		local rev: { string } = {}
		for i = #exitModes, 1, -1 do
			table.insert(rev, exitModes[i])
		end
		exitModes = rev
	end

	-- Exit modes
	for _, modeName in exitModes do
		local modeHandle = fsmRec.Modes[modeName]
		if modeHandle ~= nil then
			exitMode(fsmRec, modeHandle, frame)
		end
	end

	-- Update history (for each exited mode, record in its parent)
	for _, modeName in exitModes do
		local modeHandle = fsmRec.Modes[modeName]
		if modeHandle ~= nil then
			local modeRec = modeRecords[modeHandle]
			if modeRec ~= nil then
				local parentName = getModeParentName(fsmRec, modeRec)
				if parentName ~= nil then
					fsmRec.HistoryMap[parentName] = modeName
				end
			end
		end
	end

	-- Update active path and stores
	local prevPath = fsmRec.ActivePath
	fsmRec.ActivePath = toPath
	fsmRec._activeStoreWritable:Set(targetName)
	updateIsActiveStores(fsmRec, prevPath, toPath)

	-- Enter modes below LCA
	for i = lcaIdx + 1, #toPath do
		local modeName = toPath[i]
		local modeHandle = fsmRec.Modes[modeName]
		if modeHandle ~= nil then
			enterMode(fsmHandle, fsmRec, modeHandle, frame)
		end
	end

	-- Fire TransitionSignal
	local event: TransitionEvent = {
		From = frame.From,
		To = frame.To,
		Reason = frame.Reason,
		Data = frame.Data,
	}
	fsmRec.TransitionSignal:Fire(event)
	emitTrace("FSM.Transition", fsmRec, { From = frame.From, To = frame.To })

	fsmRec.Transitioning = false
	drainSwitchQueue(fsmHandle, fsmRec)
end

-- ── Public API ────────────────────────────────────────────────────────────────

local FSM = {} :: any

function FSM.New(ctx: any, opts: PartialPolicy?): any
	if ctx == nil or (type(ctx) ~= "table" and not Context.IsContext(ctx)) then
		error("FSM.New: ctx must be a table or Context", 2)
	end
	if opts ~= nil then
		local ok, msg = validateFSMPolicy(opts)
		if not ok then
			error("FSM.New: " .. (msg :: string), 2)
		end
	end

	local ctxHandle: any
	if Context.IsContext(ctx) then
		ctxHandle = ctx
	else
		ctxHandle = Context.Root(ctx)
	end

	local defaults = makeDefaultPolicy()
	if opts ~= nil then
		for k, v in opts :: any do
			(defaults :: any)[k] = v
		end
	end

	local activeWritable = Store.Value("")
	local activeReadonly = Store.Readonly(activeWritable)
	local transitionSignal = Signal.New()

	local rec: FSMRecord = {
		Destroyed = false,
		Disposing = false,
		Started = false,
		Transitioning = false,
		CtxHandle = ctxHandle,
		Modes = {},
		ActivePath = {},
		HistoryMap = {},
		Policy = defaults,
		_activeStoreWritable = activeWritable,
		ActiveStore = activeReadonly,
		_isActiveStores = {},
		TransitionSignal = transitionSignal,
		PendingSwitch = nil,
		DeferScheduled = false,
		SwitchQueue = {},
	}

	local handle = setmetatable({}, fsmMeta)
	fsmRecords[handle] = rec
	return handle
end

function FSM.IsFSM(value: unknown): boolean
	return type(value) == "table"
		and getmetatable(value :: any) == "FSM"
		and fsmRecords[value :: any] ~= nil
end

function FSM.IsMode(value: unknown): boolean
	return type(value) == "table"
		and getmetatable(value :: any) == "FSMMode"
		and modeRecords[value :: any] ~= nil
end

function FSM.DefaultPolicy(): Policy
	return makeDefaultPolicy() :: Policy
end

function FSM.ValidatePolicy(policy: PartialPolicy): (boolean, string?)
	return validateFSMPolicy(policy)
end

function FSM.SetTracer(fn: any): ()
	if fn ~= nil and type(fn) ~= "function" then
		error("FSM.SetTracer: fn must be a function or nil", 2)
	end
	_tracer = fn
end

-- ── FSM instance methods ──────────────────────────────────────────────────────

function fsmMethods:Context(): any
	local rec = fsmRecords[self]
	if rec == nil or rec.Destroyed then
		error("FSM.Context: FSM is destroyed", 2)
	end
	return rec.CtxHandle
end

function fsmMethods:Mode(name: string, builder: ((mode: any) -> ())?): any
	local rec = fsmRecords[self]
	if rec == nil or rec.Destroyed then
		error("FSM.Mode: FSM is destroyed", 2)
	end
	if type(name) ~= "string" or #name == 0 then
		error("FSM.Mode: name must be a non-empty string", 2)
	end
	if builder ~= nil and type(builder) ~= "function" then
		error("FSM.Mode: builder must be a function or nil", 2)
	end

	local modeHandle = rec.Modes[name]
	if modeHandle == nil then
		local modeRec: ModeRecord = {
			Destroyed = false,
			FSMHandle = self,
			RegistryName = name,
			Label = nil,
			ParentHandle = nil,
			OnEnterFns = {},
			OnExitFns = {},
			OnUpdateFns = {},
			Providers = {},
			Guards = {},
			GuardInsertCount = 0,
			AttachedRules = {},
			AttachedRuleSet = {},
			AddedFactories = {},
			TaskGroupHandle = nil,
			ActiveCtx = nil,
			ActiveDisposers = {},
			UpdateConns = {},
			GuardConns = {},
			ActiveStartedAt = nil,
		}
		modeHandle = setmetatable({}, modeMeta)
		modeRecords[modeHandle] = modeRec
		rec.Modes[name] = modeHandle
	end

	if builder ~= nil then
		builder(modeHandle)
	end
	return modeHandle
end

function fsmMethods:HasMode(name: string): boolean
	local rec = fsmRecords[self]
	if rec == nil then return false end
	if type(name) ~= "string" or #name == 0 then
		error("FSM.HasMode: name must be a non-empty string", 2)
	end
	return rec.Modes[name] ~= nil
end

function fsmMethods:GetMode(name: string): any
	local rec = fsmRecords[self]
	if rec == nil then return nil end
	if type(name) ~= "string" or #name == 0 then
		error("FSM.GetMode: name must be a non-empty string", 2)
	end
	return rec.Modes[name]
end

function fsmMethods:Start(name: string): ()
	local rec = fsmRecords[self]
	if rec == nil or rec.Destroyed then
		error("FSM.Start: FSM is destroyed", 2)
	end
	if rec.Started then
		error("FSM.Start: already started", 2)
	end
	if rec.Modes[name] == nil then
		error("FSM.Start: mode '" .. name .. "' not registered", 2)
	end

	rec.Started = true

	local toPath = computePath(rec, name)
	local prevPath: { string } = {}

	local frame: TransitionFrame = {
		From = "",
		To = name,
		Reason = "Start",
		Data = nil,
		StartedAt = Scheduler.Now(),
		Immediate = true,
	}

	rec.ActivePath = toPath
	rec._activeStoreWritable:Set(name)
	updateIsActiveStores(rec, prevPath, toPath)

	for i = 1, #toPath do
		local modeName = toPath[i]
		local modeHandle = rec.Modes[modeName]
		if modeHandle ~= nil then
			enterMode(self, rec, modeHandle, frame)
		end
	end

	local event: TransitionEvent = {
		From = "",
		To = name,
		Reason = "Start",
		Data = nil,
	}
	rec.TransitionSignal:Fire(event)
	emitTrace("FSM.Start", rec, { To = name })
end

function fsmMethods:Switch(name: string, opts: SwitchOptions?): ()
	local rec = fsmRecords[self]
	if rec == nil or rec.Destroyed then
		error("FSM.Switch: FSM is destroyed", 2)
	end
	if not rec.Started then
		error("FSM.Switch: FSM has not started", 2)
	end
	if rec.Modes[name] == nil then
		error("FSM.Switch: mode '" .. name .. "' not registered", 2)
	end
	if opts ~= nil and type(opts) ~= "table" then
		error("FSM.Switch: opts must be a table or nil", 2)
	end

	local currentLeaf = rec.ActivePath[#rec.ActivePath] or ""
	if currentLeaf == name then return end

	if rec.Disposing then return end

	local immediate = opts ~= nil and opts.Immediate == true

	if rec.Transitioning then
		if rec.Policy.Deferral == "Queue" then
			table.insert(rec.SwitchQueue, { name = name, opts = opts })
		end
		return
	end

	if immediate then
		executeTransition(self, rec, name, opts)
		return
	end

	if rec.Policy.SingleSwitchPerFrame then
		rec.PendingSwitch = { name = name, opts = opts }
		if not rec.DeferScheduled then
			rec.DeferScheduled = true
			local fsmHandle = self
			Scheduler.Defer(function()
				rec.DeferScheduled = false
				local pending = rec.PendingSwitch
				rec.PendingSwitch = nil
				if pending ~= nil and not rec.Destroyed and not rec.Disposing and not rec.Transitioning then
					local leaf = rec.ActivePath[#rec.ActivePath] or ""
					if leaf ~= pending.name and rec.Modes[pending.name] ~= nil then
						executeTransition(fsmHandle, rec, pending.name, pending.opts)
					end
				end
			end)
		end
	else
		local fsmHandle = self
		Scheduler.Defer(function()
			if rec.Destroyed or rec.Disposing or rec.Transitioning then return end
			local leaf = rec.ActivePath[#rec.ActivePath] or ""
			if leaf ~= name and rec.Modes[name] ~= nil then
				executeTransition(fsmHandle, rec, name, opts)
			end
		end)
	end
end

function fsmMethods:CanSwitch(name: string): boolean
	local rec = fsmRecords[self]
	if rec == nil or rec.Destroyed then return false end
	if not rec.Started then return false end
	if rec.Modes[name] == nil then return false end
	local currentLeaf = rec.ActivePath[#rec.ActivePath] or ""
	return currentLeaf ~= name
end

function fsmMethods:Current(): string
	local rec = fsmRecords[self]
	if rec == nil then return "" end
	return rec.ActivePath[#rec.ActivePath] or ""
end

function fsmMethods:IsActive(name: string): boolean
	local rec = fsmRecords[self]
	if rec == nil then return false end
	for _, m in rec.ActivePath do
		if m == name then return true end
	end
	return false
end

function fsmMethods:InMode(name: string): boolean
	local rec = fsmRecords[self]
	if rec == nil then return false end
	return (rec.ActivePath[#rec.ActivePath] or "") == name
end

function fsmMethods:Path(): { string }
	local rec = fsmRecords[self]
	if rec == nil then return {} end
	return table.clone(rec.ActivePath)
end

function fsmMethods:History(parentName: string): string?
	local rec = fsmRecords[self]
	if rec == nil then return nil end
	return rec.HistoryMap[parentName]
end

function fsmMethods:SwitchToHistory(parentName: string, opts: SwitchOptions?): ()
	local rec = fsmRecords[self]
	if rec == nil or rec.Destroyed then
		error("FSM.SwitchToHistory: FSM is destroyed", 2)
	end
	if not rec.Started then
		error("FSM.SwitchToHistory: FSM has not started", 2)
	end
	local target = rec.HistoryMap[parentName]
	if target == nil then return end
	fsmMethods.Switch(self, target, opts)
end

function fsmMethods:ClearHistory(parentName: string?): ()
	local rec = fsmRecords[self]
	if rec == nil then return end
	if parentName ~= nil then
		rec.HistoryMap[parentName] = nil
	else
		table.clear(rec.HistoryMap)
	end
end

function fsmMethods:Snapshot(_opts: SnapshotOptions?): Snapshot
	local rec = fsmRecords[self]
	if rec == nil then
		return { ActivePath = {}, History = {} }
	end
	return {
		ActivePath = table.clone(rec.ActivePath),
		History = table.clone(rec.HistoryMap),
	}
end

function fsmMethods:Restore(snapshot: Snapshot, opts: SwitchOptions?): ()
	local rec = fsmRecords[self]
	if rec == nil or rec.Destroyed then
		error("FSM.Restore: FSM is destroyed", 2)
	end
	if not rec.Started then
		error("FSM.Restore: FSM has not started", 2)
	end
	local leaf = snapshot.ActivePath[#snapshot.ActivePath]
	if leaf == nil then return end
	if rec.Modes[leaf] == nil then return end

	rec.HistoryMap = table.clone(snapshot.History)

	local mergedOpts: SwitchOptions = {
		Reason = "Restore",
		Data = snapshot,
		Immediate = opts ~= nil and opts.Immediate or nil,
	}
	fsmMethods.Switch(self, leaf, mergedOpts)
end

function fsmMethods:OnTransition(fn: (event: TransitionEvent) -> ()): Connection.Connection
	local rec = fsmRecords[self]
	if rec == nil then
		error("FSM.OnTransition: invalid FSM handle", 2)
	end
	return rec.TransitionSignal:Connect(fn)
end

function fsmMethods:WaitForTransition(): TransitionEvent
	local rec = fsmRecords[self]
	if rec == nil or rec.Destroyed then
		error("FSM.WaitForTransition: FSM destroyed", 2)
	end
	local ok, result = pcall(function()
		return rec.TransitionSignal:Wait()
	end)
	if not ok then
		error("FSM.WaitForTransition: FSM destroyed", 2)
	end
	return result :: TransitionEvent
end

function fsmMethods:Policy(opts: PartialPolicy): any
	local rec = fsmRecords[self]
	if rec == nil or rec.Destroyed then
		error("FSM.Policy: FSM is destroyed", 2)
	end
	if rec.Started then
		error("FSM.Policy: cannot change policy after start", 2)
	end
	local ok, msg = validateFSMPolicy(opts)
	if not ok then
		error("FSM.Policy: " .. (msg :: string), 2)
	end
	for k, v in opts :: any do
		(rec.Policy :: any)[k] = v
	end
	return self
end

function fsmMethods:IsStarted(): boolean
	local rec = fsmRecords[self]
	if rec == nil then return false end
	return rec.Started
end

function fsmMethods:IsDestroyed(): boolean
	local rec = fsmRecords[self]
	if rec == nil then return true end
	return rec.Destroyed
end

function fsmMethods:IsActiveStore(name: string): Store.ReadableStore<boolean>
	local rec = fsmRecords[self]
	if rec == nil then
		error("FSM.IsActiveStore: invalid FSM handle", 2)
	end
	if type(name) ~= "string" or #name == 0 then
		error("FSM.IsActiveStore: name must be a non-empty string", 2)
	end
	return getOrCreateIsActiveStore(rec, name) :: Store.ReadableStore<boolean>
end

function fsmMethods:Destroy(): ()
	local rec = fsmRecords[self]
	if rec == nil or rec.Destroyed then return end
	if rec.Disposing then return end

	rec.Disposing = true
	emitTrace("FSM.Destroy", rec)

	-- Exit active modes in leaf-first order while path is still observable
	local exitPath = table.clone(rec.ActivePath)
	local exitFrame: TransitionFrame = {
		From = exitPath[#exitPath] or "",
		To = "",
		Reason = "Destroy",
		Data = nil,
		StartedAt = Scheduler.Now(),
		Immediate = true,
	}
	for i = #exitPath, 1, -1 do
		local modeName = exitPath[i]
		local modeHandle = rec.Modes[modeName]
		if modeHandle ~= nil then
			exitMode(rec, modeHandle, exitFrame)
		end
	end

	-- Clear active path
	rec.ActivePath = {}
	rec._activeStoreWritable:Set("")
	updateIsActiveStores(rec, exitPath, {})

	-- Destroy modes
	for _, modeHandle in rec.Modes do
		local modeRec = modeRecords[modeHandle]
		if modeRec ~= nil then
			modeRec.Destroyed = true
			if modeRec.TaskGroupHandle ~= nil then
				modeRec.TaskGroupHandle:Destroy(Task.Reason.Shutdown)
			end
		end
	end

	-- Destroy TransitionSignal
	rec.TransitionSignal:Destroy()

	-- Destroy internal stores
	for _, entry in rec._isActiveStores do
		entry.writable:Destroy()
	end
	rec._activeStoreWritable:Destroy()

	rec.Disposing = false
	rec.Destroyed = true
end

-- ── Mode instance methods ─────────────────────────────────────────────────────

function modeMethods:Name(): string
	local rec = modeRecords[self]
	if rec == nil then
		error("Mode.Name: invalid mode handle", 2)
	end
	return rec.RegistryName
end

function modeMethods:Parent(): any
	local rec = modeRecords[self]
	if rec == nil then return nil end
	return rec.ParentHandle
end

function modeMethods:OnEnter(fn: any): any
	local rec = modeRecords[self]
	if rec == nil or rec.Destroyed then
		error("Mode.OnEnter: mode is destroyed", 2)
	end
	if type(fn) ~= "function" then
		error("Mode.OnEnter: fn must be a function", 2)
	end
	table.insert(rec.OnEnterFns, fn)
	return self
end

function modeMethods:OnExit(fn: any): any
	local rec = modeRecords[self]
	if rec == nil or rec.Destroyed then
		error("Mode.OnExit: mode is destroyed", 2)
	end
	if type(fn) ~= "function" then
		error("Mode.OnExit: fn must be a function", 2)
	end
	table.insert(rec.OnExitFns, fn)
	return self
end

function modeMethods:OnUpdate(fn: any): any
	local rec = modeRecords[self]
	if rec == nil or rec.Destroyed then
		error("Mode.OnUpdate: mode is destroyed", 2)
	end
	if type(fn) ~= "function" then
		error("Mode.OnUpdate: fn must be a function", 2)
	end
	table.insert(rec.OnUpdateFns, fn)
	return self
end

function modeMethods:Add(resource: any): any
	local rec = modeRecords[self]
	if rec == nil or rec.Destroyed then
		error("Mode.Add: mode is destroyed", 2)
	end

	if Rule.IsRule(resource) then
		if rec.AttachedRuleSet[resource] then
			error("Mode.Add: duplicate rule", 2)
		end
		rec.AttachedRuleSet[resource] = true
		table.insert(rec.AttachedRules, resource)
		-- If mode is currently active, enable immediately
		if rec.ActiveCtx ~= nil then
			resource:Enable(rec.ActiveCtx)
		end
	elseif Task.IsTask(resource) then
		if rec.TaskGroupHandle == nil then
			rec.TaskGroupHandle = Task.Group()
		end
		rec.TaskGroupHandle:Add(resource)
	elseif FSM.IsMode(resource) then
		local childRec = modeRecords[resource]
		if childRec == nil then
			error("Mode.Add: invalid mode handle", 2)
		end
		local fsmRec = fsmRecords[rec.FSMHandle]
		local childFSMRec = fsmRecords[childRec.FSMHandle]
		if fsmRec ~= childFSMRec then
			error("Mode.Add: child mode must belong to the same FSM", 2)
		end
		if childRec.ParentHandle ~= nil then
			error("Mode.Add: mode already has a parent (re-parenting is not allowed)", 2)
		end
		if hasCycle(self, resource) then
			error("Mode.Add: cycle detected in parent hierarchy", 2)
		end
		childRec.ParentHandle = self
	elseif type(resource) == "function" then
		table.insert(rec.AddedFactories, resource)
		-- If mode is currently active, run immediately
		if rec.ActiveCtx ~= nil then
			local fakeFrame: TransitionFrame = {
				From = rec.RegistryName,
				To = rec.RegistryName,
				Reason = "Add",
				Data = nil,
				StartedAt = rec.ActiveStartedAt or Scheduler.Now(),
				Immediate = true,
			}
			local ok, result = pcall(resource, rec.ActiveCtx, fakeFrame)
			if not ok then
				ErrorHandler.Report({ Module = "FSM", Phase = "Factory", Error = result })
			else
				if type(result) == "function" then
					table.insert(rec.ActiveDisposers, result :: () -> ())
				elseif Task.IsTask(result) then
					if rec.TaskGroupHandle == nil then
						rec.TaskGroupHandle = Task.Group()
					end
					rec.TaskGroupHandle:Add(result)
				end
			end
		end
	else
		error("Mode.Add: expected Rule, Task, Mode, or function", 2)
	end

	return self
end

function modeMethods:Provide(providerOrValues: any): any
	local rec = modeRecords[self]
	if rec == nil or rec.Destroyed then
		error("Mode.Provide: mode is destroyed", 2)
	end
	if type(providerOrValues) ~= "function" and type(providerOrValues) ~= "table" then
		error("Mode.Provide: providerOrValues must be a function or table", 2)
	end
	table.insert(rec.Providers, providerOrValues)
	return self
end

function modeMethods:Guard(to: string, guard: any, opts: GuardOptions?): any
	local rec = modeRecords[self]
	if rec == nil or rec.Destroyed then
		error("Mode.Guard: mode is destroyed", 2)
	end
	if type(to) ~= "string" or #to == 0 then
		error("Mode.Guard: to must be a non-empty string", 2)
	end
	if not Store.IsStore(guard) and type(guard) ~= "function" then
		error("Mode.Guard: guard must be a Store or function", 2)
	end
	local priority = 0
	local reason: string? = nil
	local deferred = false
	local data: unknown? = nil
	if opts ~= nil then
		if opts.Priority ~= nil then priority = opts.Priority :: number end
		if opts.Reason ~= nil then reason = opts.Reason end
		if opts.Defer ~= nil then deferred = opts.Defer :: boolean end
		if opts.Data ~= nil then data = opts.Data end
	end
	rec.GuardInsertCount += 1
	table.insert(rec.Guards, {
		To = to,
		GuardValue = guard,
		Priority = priority,
		InsertIdx = rec.GuardInsertCount,
		Reason = reason,
		Defer = deferred,
		Data = data,
	})
	return self
end

function modeMethods:TaskGroup(): any
	local rec = modeRecords[self]
	if rec == nil then
		error("Mode.TaskGroup: invalid mode handle", 2)
	end
	if rec.TaskGroupHandle == nil then
		rec.TaskGroupHandle = Task.Group()
	end
	return rec.TaskGroupHandle
end

function modeMethods:Tag(label: string): any
	local rec = modeRecords[self]
	if rec == nil or rec.Destroyed then
		error("Mode.Tag: mode is destroyed", 2)
	end
	if type(label) ~= "string" then
		error("Mode.Tag: label must be a string", 2)
	end
	rec.Label = label
	return self
end

function modeMethods:IsActive(): boolean
	local rec = modeRecords[self]
	if rec == nil then return false end
	local fsmRec = fsmRecords[rec.FSMHandle]
	if fsmRec == nil then return false end
	for _, m in fsmRec.ActivePath do
		if m == rec.RegistryName then return true end
	end
	return false
end

function modeMethods:IsDestroyed(): boolean
	local rec = modeRecords[self]
	if rec == nil then return true end
	return rec.Destroyed
end

function modeMethods:Destroy(): ()
	local rec = modeRecords[self]
	if rec == nil or rec.Destroyed then return end

	if rec.ActiveCtx ~= nil then
		error("Mode.Destroy: cannot destroy active mode", 2)
	end

	local fsmRec = fsmRecords[rec.FSMHandle]
	if fsmRec ~= nil then
		fsmRec.Modes[rec.RegistryName] = nil
	end

	-- Disable/destroy rules
	for _, ruleHandle in rec.AttachedRules do
		if Rule.IsRule(ruleHandle) then
			(ruleHandle :: any):Destroy()
		end
	end
	table.clear(rec.AttachedRules)
	table.clear(rec.AttachedRuleSet)

	if rec.TaskGroupHandle ~= nil then
		rec.TaskGroupHandle:Destroy(Task.Reason.ModeExit)
		rec.TaskGroupHandle = nil
	end

	table.clear(rec.OnEnterFns)
	table.clear(rec.OnExitFns)
	table.clear(rec.OnUpdateFns)
	table.clear(rec.Guards)
	table.clear(rec.Providers)
	table.clear(rec.AddedFactories)

	rec.Destroyed = true
end

return FSM
