--!strict
--!optimize 2

-- Internal: canonical scheduler shared by Signal, Rule, Task, and FSM.
--
-- Roblox's `task` global is captured ONCE here, at module-load time, before any
-- consumer module executes. All timing-dependent modules import Scheduler rather
-- than referencing `task.*` directly, so test harnesses can swap all scheduling
-- in one place via override().
--
-- CRITICAL: never name a local variable "task" in this module or in any module
-- that imports it. Doing so shadows the Roblox global before this capture runs
-- in that module's scope.

export type SchedulerInterface = {
	defer:  (callback: () -> ()) -> thread,
	delay:  (seconds: number, callback: () -> ()) -> thread,
	cancel: (coroutineThread: thread) -> (),
	now:    () -> number,
}

-- Live table: importers reference Scheduler.defer etc. on each call so that
-- override() takes effect immediately library-wide without re-requiring.
local Scheduler: SchedulerInterface = {
	defer  = task.defer,
	delay  = task.delay,
	cancel = task.cancel,
	now    = os.clock,
}

-- Replaces any subset of the scheduler's methods.
-- Pass only the fields you want to change; unspecified fields are left alone.
local function override(replacement: {
	defer:  ((callback: () -> ()) -> thread)?,
	delay:  ((seconds: number, callback: () -> ()) -> thread)?,
	cancel: ((coroutineThread: thread) -> ())?,
	now:    (() -> number)?,
	})
	if replacement.defer  ~= nil then Scheduler.defer  = replacement.defer  :: any end
	if replacement.delay  ~= nil then Scheduler.delay  = replacement.delay  :: any end
	if replacement.cancel ~= nil then Scheduler.cancel = replacement.cancel :: any end
	if replacement.now    ~= nil then Scheduler.now    = replacement.now    :: any end
end

return table.freeze({
	Scheduler = Scheduler,
	override  = override,
})

