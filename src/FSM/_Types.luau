--!strict

local Connection = require(script.Parent.Parent.Connection)
local Context = require(script.Parent.Parent.Context)
local Rule = require(script.Parent.Parent.Rule)
local Signal = require(script.Parent.Parent.Signal)
local Store = require(script.Parent.Parent.Store)
local Task = require(script.Parent.Parent.Task)

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

export type FSMTraceEvent = {
	Event: string,
	Tag: string?,
	From: string?,
	To: string?,
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


export type FSMModuleType = {
	New: <Ctx>(ctx: Context.Context<Ctx> | { [any]: any }, opts: PartialPolicy?) -> FSM<Ctx>,
	IsFSM: (value: unknown) -> boolean,
	IsMode: (value: unknown) -> boolean,
	DefaultPolicy: () -> Policy,
	ValidatePolicy: (policy: PartialPolicy) -> (boolean, string?),
	SetTracer: (fn: ((FSMTraceEvent) -> ())?) -> (),
	ExitOrdering: {
		LeafFirst: "LeafFirst",
		ParentFirst: "ParentFirst",
	},
	Deferral: {
		Queue: "Queue",
		Drop: "Drop",
	},
}

return table.freeze({})

