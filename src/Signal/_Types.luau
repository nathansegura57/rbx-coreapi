--!strict

local Types = {}

export type ReplayPolicy = "Count" | "Time"

export type ReplayPolicySet = {
	Count: "Count",
	Time: "Time",
}

export type ListenerEntry = {
	Connected: boolean,
	Fn: (any) -> (),
}

export type WaiterEntry = {
	Thread: thread,
}

export type ReplayEntry = {
	Value: any,
	Timestamp: number,
}

export type SignalRecord = {
	Destroyed: boolean,
	IsNever: boolean,

	Listeners: { ListenerEntry },
	FireDepth: number,
	Waiters: { WaiterEntry },

	ReplayPolicy: ReplayPolicy?,
	ReplayCountLimit: number,
	ReplayTimeWindow: number,
	ReplayBuffer: { ReplayEntry },

	CleanupCallbacks: { () -> () },
	TimerHandles: { any },
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

export type SignalModule = {
	ReplayPolicy: ReplayPolicySet,

	New: <Value>() -> any,
	Never: <Value>() -> any,
	After: (seconds: number) -> any,
	Every: (seconds: number) -> any,
	FromRoblox: (robloxSignal: RBXScriptSignal, mapper: ((...any) -> any)?) -> any,
	IsSignal: (value: unknown) -> boolean,

	Merge: <Value>(signals: { any }) -> any,
	Zip: <Value>(signals: { any }) -> any,
	Race: <Value>(signals: { any }) -> any,
	Sequence: <Value>(signals: { any }, options: SequenceOptions?) -> any,
}

export type SignalMethods = { [string]: any }

return table.freeze(Types)

