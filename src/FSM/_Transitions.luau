--!strict

local Connection = require(script.Parent.Parent.Connection)
local Context = require(script.Parent.Parent.Context)
local ErrorHandler = require(script.Parent.Parent.ErrorHandler)
local Rule = require(script.Parent.Parent.Rule)
local Scheduler = require(script.Parent.Parent.Scheduler)
local Signal = require(script.Parent.Parent.Signal)
local Store = require(script.Parent.Parent.Store)
local Task = require(script.Parent.Parent.Task)
local Types = require(script.Parent._Types)
local PolicyHelpers = require(script.Parent._Policy)

type TransitionEvent = Types.TransitionEvent
type TransitionFrame = Types.TransitionFrame
type UpdateFrame = Types.UpdateFrame
type SwitchOptions = Types.SwitchOptions
type SnapshotOptions = Types.SnapshotOptions
type Snapshot = Types.Snapshot
type GuardOptions = Types.GuardOptions
type FSMTraceEvent = Types.FSMTraceEvent
type Policy = Types.Policy
type PartialPolicy = Types.PartialPolicy
type FSM<Ctx> = Types.FSM<Ctx>
type Mode<Ctx> = Types.Mode<Ctx>
type FSMModuleType = Types.FSMModuleType


-- ── Internal records ──────────────────────────────────────────────────────────

type ExitOrdering = "LeafFirst" | "ParentFirst"
type Deferral = "Queue" | "Drop"

type PolicyRecord = {
	SingleSwitchPerFrame: boolean,
	CancelTasksOnExit: boolean,
	ExitOrdering: ExitOrdering,
	Deferral: Deferral,
	ErrorPolicy: ErrorHandler.Policy?,
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

local fsmRecords: { [any]: FSMRecord } = setmetatable({}, { __mode = "k" }) :: any
local modeRecords: { [any]: ModeRecord } = setmetatable({}, { __mode = "k" }) :: any

-- ── Tracer ────────────────────────────────────────────────────────────────────

local activeTracer: ((FSMTraceEvent) -> ())? = nil

local function emitTrace(event: string, fsmRecord: FSMRecord, extra: { [string]: any }?)
	if activeTracer == nil then return end
	local fn = activeTracer :: (FSMTraceEvent) -> ()
	local payload: { [string]: any } = { Event = event, Tag = fsmRecord.Policy.Tag }
	if extra then
		for k, v in extra do payload[k] = v end
	end
	ErrorHandler.Protect(function() fn(payload :: FSMTraceEvent) end, "FSM", "Trace")
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
		ErrorHandler.RaiseUsageError(`FSM: '{k}' is read-only`)
	end,
}

local modeMeta = {
	__metatable = "FSMMode",
	__index = modeMethods,
	__newindex = function(_, k: string)
		ErrorHandler.RaiseUsageError(`Mode: '{k}' is read-only`)
	end,
}

-- ── Policy helpers ────────────────────────────────────────────────────────────

local makeDefaultPolicy = PolicyHelpers.MakeDefaultPolicy
local validateFSMPolicy = PolicyHelpers.ValidatePolicy

-- ── Mode parent / path helpers ────────────────────────────────────────────────

local function getModeParentName(fsmRecord: FSMRecord, modeRecord: ModeRecord): string?
	if modeRecord.ParentHandle ~= nil then
		local parentRec = modeRecords[modeRecord.ParentHandle]
		return if parentRec ~= nil then parentRec.RegistryName else nil
	end
	local name = modeRecord.RegistryName
	local dotPos = string.find(name, "%.[^%.]*$")
	if dotPos ~= nil then
		local possibleParent = string.sub(name, 1, dotPos - 1)
		if fsmRecord.Modes[possibleParent] ~= nil then
			return possibleParent
		end
	end
	return nil
end

local function computePath(fsmRecord: FSMRecord, modeName: string): { string }
	local path: { string } = {}
	local current: string? = modeName
	local visited: { [string]: boolean } = {}
	while current ~= nil do
		if visited[current] then break end
		visited[current] = true
		table.insert(path, 1, current)
		local modeHandle = fsmRecord.Modes[current]
		if modeHandle == nil then break end
		local modeRecord = modeRecords[modeHandle]
		if modeRecord == nil then break end
		current = getModeParentName(fsmRecord, modeRecord)
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

local function getOrCreateIsActiveStore(fsmRecord: FSMRecord, name: string): any
	local entry = fsmRecord._isActiveStores[name]
	if entry ~= nil then
		return entry.readonly
	end
	local isActive = false
	for _, m in fsmRecord.ActivePath do
		if m == name then isActive = true break end
	end
	local writable = Store.Value(isActive)
	local readonly = Store.Readonly(writable)
	fsmRecord._isActiveStores[name] = { writable = writable, readonly = readonly }
	return readonly
end

local function updateIsActiveStores(fsmRecord: FSMRecord, fromPath: { string }, toPath: { string })
	local fromSet: { [string]: boolean } = {}
	for _, m in fromPath do fromSet[m] = true end
	local toSet: { [string]: boolean } = {}
	for _, m in toPath do toSet[m] = true end

	for name, entry in fsmRecord._isActiveStores do
		local wasActive = fromSet[name] == true
		local isActive = toSet[name] == true
		if wasActive ~= isActive then
			entry.writable:Set(isActive)
		end
	end
end

-- ── Error policy helper ───────────────────────────────────────────────────────

local function handleFSMError(fsmRecord: FSMRecord, phase: string, err: unknown): ()
	local errorPolicy = fsmRecord.Policy.ErrorPolicy
	local errorInfo: ErrorHandler.ErrorInfo = { Module = "FSM", Phase = phase, Error = err }
	if errorPolicy ~= nil then
		ErrorHandler.ReportWithPolicy(errorInfo, errorPolicy)
	else
		ErrorHandler.Report(errorInfo)
	end
end

-- ── Mode exit ─────────────────────────────────────────────────────────────────

local function exitMode(fsmRecord: FSMRecord, modeHandle: any, frame: TransitionFrame)
	local modeRecord = modeRecords[modeHandle]
	if modeRecord == nil or modeRecord.ActiveCtx == nil then return end

	local ctx = modeRecord.ActiveCtx

	-- 1. Disconnect update connections
	for _, conn in modeRecord.UpdateConns do
		conn:Disconnect()
	end
	table.clear(modeRecord.UpdateConns)

	-- 2. Disconnect guard watchers
	for _, conn in modeRecord.GuardConns do
		conn:Disconnect()
	end
	table.clear(modeRecord.GuardConns)

	-- 3. Run OnExit callbacks
	for _, fn in modeRecord.OnExitFns do
		local ok, result = pcall(fn, ctx, frame)
		if not ok then
			handleFSMError(fsmRecord, "Exit", result)
		else
			if type(result) == "function" then
				ErrorHandler.Protect(result :: () -> (), "FSM", "ExitDisposer")
			elseif Task.IsTask(result) then
				ErrorHandler.Report({ Module = "FSM", Phase = "ExitTaskIgnored", Error = "OnExit returned a Task; async exit is not supported" })
			end
		end
	end

	-- 4. Run active disposers
	for _, d in modeRecord.ActiveDisposers do
		ErrorHandler.Protect(d, "FSM", "ExitDisposer")
	end
	table.clear(modeRecord.ActiveDisposers)

	-- 5. Disable attached rules
	for _, ruleHandle in modeRecord.AttachedRules do
		if Rule.IsRule(ruleHandle) then
			(ruleHandle :: any):Disable()
		end
	end

	-- 6. Cancel task group if CancelTasksOnExit
	if fsmRecord.Policy.CancelTasksOnExit and modeRecord.TaskGroupHandle ~= nil then
		modeRecord.TaskGroupHandle:CancelAll(Task.Reason.ModeExit)
	end

	-- 7. Destroy mode context layer
	if Context.IsContext(ctx) then
		ctx:Destroy()
	end
	modeRecord.ActiveCtx = nil
	modeRecord.ActiveStartedAt = nil
end

-- ── Mode enter ────────────────────────────────────────────────────────────────

local function enterMode(fsmHandle: any, fsmRecord: FSMRecord, modeHandle: any, frame: TransitionFrame)
	local modeRecord = modeRecords[modeHandle]
	if modeRecord == nil or modeRecord.Destroyed then return end

	local startedAt = Scheduler.Now()
	modeRecord.ActiveStartedAt = startedAt

	-- 1. Create mode context layer from providers
	local providerValues: { [any]: any } = {}
	local providerCleanups: { () -> () } = {}

	for _, provider in modeRecord.Providers do
		if type(provider) == "function" then
			local ok, values, cleanup = pcall(provider, fsmRecord.CtxHandle, frame)
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
				handleFSMError(fsmRecord, "Provide", values)
			end
		elseif type(provider) == "table" then
			for k, v in provider do
				providerValues[k] = v
			end
		end
	end

	local modeCtx = fsmRecord.CtxHandle:Layer(providerValues, if #providerCleanups > 0 then function()
		for _, c in providerCleanups do
			ErrorHandler.Protect(c, "FSM", "ProvideCleanup")
		end
	end else nil)
	modeRecord.ActiveCtx = modeCtx

	-- 2. Run OnEnter callbacks + 3. collect disposers + 4. add Task returns
	for _, fn in modeRecord.OnEnterFns do
		local ok, result = pcall(fn, modeCtx, frame)
		if not ok then
			handleFSMError(fsmRecord, "Enter", result)
		else
			if type(result) == "function" then
				table.insert(modeRecord.ActiveDisposers, result :: () -> ())
			elseif Task.IsTask(result) then
				if modeRecord.TaskGroupHandle == nil then
					modeRecord.TaskGroupHandle = Task.Group()
				end
				(modeRecord.TaskGroupHandle :: any):Add(result)
			end
		end
	end

	-- Factory resources
	for _, factory in modeRecord.AddedFactories do
		local ok, result = ErrorHandler.Protect(function() return factory(modeCtx, frame) end, "FSM", "Factory")
		if ok then
			if type(result) == "function" then
				table.insert(modeRecord.ActiveDisposers, result :: () -> ())
			elseif Task.IsTask(result) then
				if modeRecord.TaskGroupHandle == nil then
					modeRecord.TaskGroupHandle = Task.Group()
				end
				(modeRecord.TaskGroupHandle :: any):Add(result)
			end
		end
	end

	-- 5. Enable attached rules
	for _, ruleHandle in modeRecord.AttachedRules do
		if Rule.IsRule(ruleHandle) then
			(ruleHandle :: any):Enable(modeCtx)
		end
	end

	-- 6. Connect update callbacks
	for _, updateFn in modeRecord.OnUpdateFns do
		local fn = updateFn
		local updateFrame: UpdateFrame = { Mode = modeRecord.RegistryName, StartedAt = startedAt }
		local ok, conn = ErrorHandler.Protect(function()
			return Scheduler.OnStep(function(dt: number)
				if modeRecord.ActiveCtx == nil then return end
				ErrorHandler.Protect(function() fn(modeCtx, dt, updateFrame) end, "FSM", "Update")
			end)
		end, "FSM", "Update")
		if ok then
			table.insert(modeRecord.UpdateConns, conn :: Connection.Connection)
		end
	end

	-- 7 & 8. Activate guards + evaluate immediate function guards
	local fnGuards: { GuardEntry } = {}
	for _, g in modeRecord.Guards do
		if Store.IsStore(g.GuardValue) then
			local guardEntry = g
			local conn = (g.GuardValue :: any):Subscribe(function(value: any)
				if value == true and modeRecord.ActiveCtx ~= nil then
					local switchOpts: SwitchOptions = {
						Reason = guardEntry.Reason,
						Data = guardEntry.Data,
						Immediate = not guardEntry.Defer,
					}
					fsmMethods.Switch(fsmHandle, guardEntry.To, switchOpts)
				end
			end, { Immediate = false })
			table.insert(modeRecord.GuardConns, conn)
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
		local ok, result = ErrorHandler.Protect(function() return g.GuardValue(modeCtx, frame) end, "FSM", "Guard")
		if ok and result == true then
			local guardEntry = g
			if guardEntry.Defer then
				Scheduler.Defer(function()
					if modeRecord.ActiveCtx ~= nil then
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

local function drainSwitchQueue(fsmHandle: any, fsmRecord: FSMRecord)
	while #fsmRecord.SwitchQueue > 0 and not fsmRecord.Destroyed and not fsmRecord.Disposing do
		local req = table.remove(fsmRecord.SwitchQueue, 1) :: { name: string, opts: SwitchOptions? }
		local currentLeaf = fsmRecord.ActivePath[#fsmRecord.ActivePath] or ""
		if req.name ~= currentLeaf and fsmRecord.Modes[req.name] ~= nil then
			fsmMethods.Switch(fsmHandle, req.name, req.opts)
			if fsmRecord.Transitioning then break end
		end
	end
end

local function executeTransition(fsmHandle: any, fsmRecord: FSMRecord, targetName: string, opts: SwitchOptions?)
	if fsmRecord.Transitioning then
		if fsmRecord.Policy.Deferral == "Queue" then
			table.insert(fsmRecord.SwitchQueue, { name = targetName, opts = opts })
		end
		return
	end

	fsmRecord.Transitioning = true

	local fromPath = fsmRecord.ActivePath
	local toPath = computePath(fsmRecord, targetName)
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
	if fsmRecord.Policy.ExitOrdering == "ParentFirst" then
		local rev: { string } = {}
		for i = #exitModes, 1, -1 do
			table.insert(rev, exitModes[i])
		end
		exitModes = rev
	end

	-- Exit modes
	for _, modeName in exitModes do
		local modeHandle = fsmRecord.Modes[modeName]
		if modeHandle ~= nil then
			exitMode(fsmRecord, modeHandle, frame)
		end
	end

	-- Update history (for each exited mode, record in its parent)
	for _, modeName in exitModes do
		local modeHandle = fsmRecord.Modes[modeName]
		if modeHandle ~= nil then
			local modeRecord = modeRecords[modeHandle]
			if modeRecord ~= nil then
				local parentName = getModeParentName(fsmRecord, modeRecord)
				if parentName ~= nil then
					fsmRecord.HistoryMap[parentName] = modeName
				end
			end
		end
	end

	-- Update active path and stores
	local prevPath = fsmRecord.ActivePath
	fsmRecord.ActivePath = toPath
	fsmRecord._activeStoreWritable:Set(targetName)
	updateIsActiveStores(fsmRecord, prevPath, toPath)

	-- Enter modes below LCA
	for i = lcaIdx + 1, #toPath do
		local modeName = toPath[i]
		local modeHandle = fsmRecord.Modes[modeName]
		if modeHandle ~= nil then
			enterMode(fsmHandle, fsmRecord, modeHandle, frame)
		end
	end

	-- Fire TransitionSignal
	local event: TransitionEvent = {
		From = frame.From,
		To = frame.To,
		Reason = frame.Reason,
		Data = frame.Data,
	}
	fsmRecord.TransitionSignal:Fire(event)
	emitTrace("FSM.Transition", fsmRecord, { From = frame.From, To = frame.To })

	fsmRecord.Transitioning = false
	drainSwitchQueue(fsmHandle, fsmRecord)
end

-- ── Public API ────────────────────────────────────────────────────────────────

local FSM = {} :: any

function FSM.New<Ctx>(ctx: Context.Context<Ctx> | { [any]: any }, opts: PartialPolicy?): FSM<Ctx>
	if ctx == nil or (type(ctx) ~= "table" and not Context.IsContext(ctx)) then
		ErrorHandler.RaiseUsageError("FSM.New: ctx must be a table or Context")
	end
	if opts ~= nil then
		local ok, msg = validateFSMPolicy(opts)
		if not ok then
			ErrorHandler.RaiseUsageError("FSM.New: " .. (msg :: string))
		end
	end

	local ctxHandle: Context.Context<Ctx>
	if Context.IsContext(ctx) then
		ctxHandle = ctx :: Context.Context<Ctx>
	else
		ctxHandle = Context.Root(ctx :: { [any]: any }) :: Context.Context<Ctx>
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
	return handle :: any
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

function FSM.SetTracer(fn: ((FSMTraceEvent) -> ())?): ()
	if fn ~= nil and type(fn) ~= "function" then
		ErrorHandler.RaiseUsageError("FSM.SetTracer: fn must be a function or nil")
	end
	activeTracer = fn
end

-- ── FSM instance methods ──────────────────────────────────────────────────────

function fsmMethods:Context(): any
	local rec = fsmRecords[self]
	if rec == nil or rec.Destroyed then
		ErrorHandler.RaiseUsageError("FSM.Context: FSM is destroyed")
	end
	return rec.CtxHandle
end

function fsmMethods:Mode(name: string, builder: ((mode: any) -> ())?): any
	local rec = fsmRecords[self]
	if rec == nil or rec.Destroyed then
		ErrorHandler.RaiseUsageError("FSM.Mode: FSM is destroyed")
	end
	if type(name) ~= "string" or #name == 0 then
		ErrorHandler.RaiseUsageError("FSM.Mode: name must be a non-empty string")
	end
	if builder ~= nil and type(builder) ~= "function" then
		ErrorHandler.RaiseUsageError("FSM.Mode: builder must be a function or nil")
	end

	local modeHandle = rec.Modes[name]
	if modeHandle == nil then
		local modeRecord: ModeRecord = {
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
		modeRecords[modeHandle] = modeRecord
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
		ErrorHandler.RaiseUsageError("FSM.HasMode: name must be a non-empty string")
	end
	return rec.Modes[name] ~= nil
end

function fsmMethods:GetMode(name: string): any
	local rec = fsmRecords[self]
	if rec == nil then return nil end
	if type(name) ~= "string" or #name == 0 then
		ErrorHandler.RaiseUsageError("FSM.GetMode: name must be a non-empty string")
	end
	return rec.Modes[name]
end

function fsmMethods:Start(name: string): ()
	local rec = fsmRecords[self]
	if rec == nil or rec.Destroyed then
		ErrorHandler.RaiseUsageError("FSM.Start: FSM is destroyed")
	end
	if rec.Started then
		ErrorHandler.RaiseUsageError("FSM.Start: already started")
	end
	if rec.Modes[name] == nil then
		ErrorHandler.RaiseUsageError("FSM.Start: mode '" .. name .. "' not registered")
	end

	-- Validate all guard targets reference registered modes.
	for modeName, modeHandle in rec.Modes do
		local modeRecord = modeRecords[modeHandle]
		if modeRecord ~= nil then
			for _, guardEntry in modeRecord.Guards do
				if rec.Modes[guardEntry.To] == nil then
					ErrorHandler.RaiseUsageError(
						`FSM.Start: guard in mode '{modeName}' targets unregistered mode '{guardEntry.To}'`
					)
				end
			end
		end
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
		ErrorHandler.RaiseUsageError("FSM.Switch: FSM is destroyed")
	end
	if not rec.Started then
		ErrorHandler.RaiseUsageError("FSM.Switch: FSM has not started")
	end
	if rec.Modes[name] == nil then
		ErrorHandler.RaiseUsageError("FSM.Switch: mode '" .. name .. "' not registered")
	end
	if opts ~= nil and type(opts) ~= "table" then
		ErrorHandler.RaiseUsageError("FSM.Switch: opts must be a table or nil")
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
		ErrorHandler.RaiseUsageError("FSM.SwitchToHistory: FSM is destroyed")
	end
	if not rec.Started then
		ErrorHandler.RaiseUsageError("FSM.SwitchToHistory: FSM has not started")
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
		ErrorHandler.RaiseUsageError("FSM.Restore: FSM is destroyed")
	end
	if not rec.Started then
		ErrorHandler.RaiseUsageError("FSM.Restore: FSM has not started")
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
		ErrorHandler.RaiseUsageError("FSM.OnTransition: invalid FSM handle")
	end
	return rec.TransitionSignal:Connect(fn)
end

function fsmMethods:WaitForTransition(): TransitionEvent
	local rec = fsmRecords[self]
	if rec == nil or rec.Destroyed then
		ErrorHandler.RaiseUsageError("FSM.WaitForTransition: FSM destroyed")
	end
	local ok, result = pcall(function()
		return rec.TransitionSignal:Wait()
	end)
	if not ok then
		ErrorHandler.RaiseUsageError("FSM.WaitForTransition: FSM destroyed")
	end
	return result :: TransitionEvent
end

function fsmMethods:Policy(opts: PartialPolicy): any
	local rec = fsmRecords[self]
	if rec == nil or rec.Destroyed then
		ErrorHandler.RaiseUsageError("FSM.Policy: FSM is destroyed")
	end
	if rec.Started then
		ErrorHandler.RaiseUsageError("FSM.Policy: cannot change policy after start")
	end
	local ok, msg = validateFSMPolicy(opts)
	if not ok then
		ErrorHandler.RaiseUsageError("FSM.Policy: " .. (msg :: string))
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
		ErrorHandler.RaiseUsageError("FSM.IsActiveStore: invalid FSM handle")
	end
	if type(name) ~= "string" or #name == 0 then
		ErrorHandler.RaiseUsageError("FSM.IsActiveStore: name must be a non-empty string")
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
		local modeRecord = modeRecords[modeHandle]
		if modeRecord ~= nil then
			modeRecord.Destroyed = true
			if modeRecord.TaskGroupHandle ~= nil then
				modeRecord.TaskGroupHandle:Destroy(Task.Reason.Shutdown)
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
		ErrorHandler.RaiseUsageError("Mode.Name: invalid mode handle")
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
		ErrorHandler.RaiseUsageError("Mode.OnEnter: mode is destroyed")
	end
	if type(fn) ~= "function" then
		ErrorHandler.RaiseUsageError("Mode.OnEnter: fn must be a function")
	end
	table.insert(rec.OnEnterFns, fn)
	return self
end

function modeMethods:OnExit(fn: any): any
	local rec = modeRecords[self]
	if rec == nil or rec.Destroyed then
		ErrorHandler.RaiseUsageError("Mode.OnExit: mode is destroyed")
	end
	if type(fn) ~= "function" then
		ErrorHandler.RaiseUsageError("Mode.OnExit: fn must be a function")
	end
	table.insert(rec.OnExitFns, fn)
	return self
end

function modeMethods:OnUpdate(fn: any): any
	local rec = modeRecords[self]
	if rec == nil or rec.Destroyed then
		ErrorHandler.RaiseUsageError("Mode.OnUpdate: mode is destroyed")
	end
	if type(fn) ~= "function" then
		ErrorHandler.RaiseUsageError("Mode.OnUpdate: fn must be a function")
	end
	table.insert(rec.OnUpdateFns, fn)
	return self
end

function modeMethods:Add(resource: any): any
	local rec = modeRecords[self]
	if rec == nil or rec.Destroyed then
		ErrorHandler.RaiseUsageError("Mode.Add: mode is destroyed")
	end

	if Rule.IsRule(resource) then
		if rec.AttachedRuleSet[resource] then
			ErrorHandler.RaiseUsageError("Mode.Add: duplicate rule")
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
		(rec.TaskGroupHandle :: any):Add(resource)
	elseif FSM.IsMode(resource) then
		local childRec = modeRecords[resource]
		if childRec == nil then
			ErrorHandler.RaiseUsageError("Mode.Add: invalid mode handle")
		end
		local fsmRecord = fsmRecords[rec.FSMHandle]
		local childFSMRec = fsmRecords[childRec.FSMHandle]
		if fsmRecord ~= childFSMRec then
			ErrorHandler.RaiseUsageError("Mode.Add: child mode must belong to the same FSM")
		end
		if childRec.ParentHandle ~= nil then
			ErrorHandler.RaiseUsageError("Mode.Add: mode already has a parent (re-parenting is not allowed)")
		end
		if hasCycle(self, resource) then
			ErrorHandler.RaiseUsageError("Mode.Add: cycle detected in parent hierarchy")
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
			local ok, result = ErrorHandler.Protect(function() return resource(rec.ActiveCtx, fakeFrame) end, "FSM", "Factory")
			if ok then
				if type(result) == "function" then
					table.insert(rec.ActiveDisposers, result :: () -> ())
				elseif Task.IsTask(result) then
					if rec.TaskGroupHandle == nil then
						rec.TaskGroupHandle = Task.Group()
					end
					(rec.TaskGroupHandle :: any):Add(result)
				end
			end
		end
	else
		ErrorHandler.RaiseUsageError("Mode.Add: expected Rule, Task, Mode, or function")
	end

	return self
end

function modeMethods:Provide(providerOrValues: any): any
	local rec = modeRecords[self]
	if rec == nil or rec.Destroyed then
		ErrorHandler.RaiseUsageError("Mode.Provide: mode is destroyed")
	end
	if type(providerOrValues) ~= "function" and type(providerOrValues) ~= "table" then
		ErrorHandler.RaiseUsageError("Mode.Provide: providerOrValues must be a function or table")
	end
	table.insert(rec.Providers, providerOrValues)
	return self
end

function modeMethods:Guard(to: string, guard: any, opts: GuardOptions?): any
	local rec = modeRecords[self]
	if rec == nil or rec.Destroyed then
		ErrorHandler.RaiseUsageError("Mode.Guard: mode is destroyed")
	end
	if type(to) ~= "string" or #to == 0 then
		ErrorHandler.RaiseUsageError("Mode.Guard: to must be a non-empty string")
	end
	if not Store.IsStore(guard) and type(guard) ~= "function" then
		ErrorHandler.RaiseUsageError("Mode.Guard: guard must be a Store or function")
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
		ErrorHandler.RaiseUsageError("Mode.TaskGroup: invalid mode handle")
	end
	if rec.TaskGroupHandle == nil then
		rec.TaskGroupHandle = Task.Group()
	end
	return rec.TaskGroupHandle
end

function modeMethods:Tag(label: string): any
	local rec = modeRecords[self]
	if rec == nil or rec.Destroyed then
		ErrorHandler.RaiseUsageError("Mode.Tag: mode is destroyed")
	end
	if type(label) ~= "string" then
		ErrorHandler.RaiseUsageError("Mode.Tag: label must be a string")
	end
	rec.Label = label
	return self
end

function modeMethods:IsActive(): boolean
	local rec = modeRecords[self]
	if rec == nil then return false end
	local fsmRecord = fsmRecords[rec.FSMHandle]
	if fsmRecord == nil then return false end
	for _, m in fsmRecord.ActivePath do
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
		ErrorHandler.RaiseUsageError("Mode.Destroy: cannot destroy active mode")
	end

	local fsmRecord = fsmRecords[rec.FSMHandle]
	if fsmRecord ~= nil then
		fsmRecord.Modes[rec.RegistryName] = nil
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

-- ── Enum tables ───────────────────────────────────────────────────────────────

local leafFirstExitOrdering: "LeafFirst" = "LeafFirst"
local parentFirstExitOrdering: "ParentFirst" = "ParentFirst"

local queueDeferral: "Queue" = "Queue"
local dropDeferral: "Drop" = "Drop"

FSM.ExitOrdering = table.freeze({
	LeafFirst = leafFirstExitOrdering,
	ParentFirst = parentFirstExitOrdering,
}) :: { LeafFirst: "LeafFirst", ParentFirst: "ParentFirst" }

FSM.Deferral = table.freeze({
	Queue = queueDeferral,
	Drop = dropDeferral,
}) :: { Queue: "Queue", Drop: "Drop" }

return FSM :: Types.FSMModuleType

