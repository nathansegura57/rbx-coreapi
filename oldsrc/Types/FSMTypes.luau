--!strict

local ConnectionModule = require(script.Parent.Parent.Internal.Connection)
local TaskTypes         = require(script.Parent.TaskTypes)

export type Connection = ConnectionModule.Connection

export type GuardOpts = {
	priority: number?,
	defer:    boolean?,
	reason:   string?,
}

export type FSMPipelinePolicy = {
	singleSwitchPerFrame: boolean?,
	cancelTasksOnExit:    boolean?,
	ordering:             ("exitParentsFirst" | "exitSelfFirst")?,
	deferral:             ("drop" | "queue")?,
	trace:                boolean?,
	tag:                  string?,
}

-- ModeHandle: builder/handle for a single state in the machine.
-- :add() accepts Rule|Task|ModeHandle|()->Task|()->(()->()) — typed as any at
-- callsites because Luau cannot express the union cleanly; runtime narrowing
-- uses getmetatable() inside the implementation.
export type ModeHandle = {
	name:      (self: ModeHandle) -> string,
	parent:    (self: ModeHandle) -> ModeHandle?,
	onEnter:   (self: ModeHandle, fn: (ctx: any, from: string?) -> any?) -> ModeHandle,
	onExit:    (self: ModeHandle, fn: (ctx: any, to: string?) -> any?) -> ModeHandle,
	onUpdate:  (self: ModeHandle, fn: (ctx: any, dt: number) -> ()) -> ModeHandle,
	add:       (self: ModeHandle, x: any) -> ModeHandle,
	guard:     (self: ModeHandle, to: string, when: any, opts: GuardOpts?) -> ModeHandle,
	taskGroup: (self: ModeHandle) -> TaskTypes.TaskGroup,
	tag:       (self: ModeHandle, label: string) -> ModeHandle,
}

-- FSM: hierarchical state machine controller.
--
-- Two reactive properties are accessible directly on the FSM handle via __index
-- (not listed in this type because Luau cannot express per-instance data fields
-- on a method table):
--   fsm.activeStore       ReadableStore<string>  — current leaf mode name
--   fsm.transitionSignal  Signal<{...}>          — all transitions as a signal
--
-- isActiveStore(name) is a method returning a lazy ReadableStore<boolean> per name.
export type FSM = {
	context:         (self: FSM) -> any,
	mode:            (self: FSM, name: string, builder: ((ModeHandle) -> ())?) -> ModeHandle,
	region:          (self: FSM, name: string, builder: (region: FSM) -> ()) -> ModeHandle,
	start:           (self: FSM, name: string) -> (),
	switch:          (self: FSM, name: string, opts: { immediate: boolean?, reason: string? }?) -> (),
	current:         (self: FSM) -> string,
	isActive:        (self: FSM, name: string) -> boolean,
	inMode:          (self: FSM, name: string) -> boolean,
	path:            (self: FSM) -> { string },
	history:         (self: FSM, parentName: string) -> string?,
	snapshot:        (self: FSM) -> { activePath: { string } },
	restore:         (self: FSM, snap: { activePath: { string } }) -> (),
	onTransition:    (self: FSM, fn: (from: string, to: string, reason: string?) -> ()) -> Connection,
	policy:          (self: FSM, opts: FSMPipelinePolicy) -> FSM,
	dispose:         (self: FSM) -> (),
	isActiveStore:   (self: FSM, name: string) -> any,
}

return nil

