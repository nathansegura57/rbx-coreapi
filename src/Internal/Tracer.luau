--!strict
--!optimize 2

-- Internal: factory for per-module trace emitters.
-- Rule, Task, and FSM each have their own typed TraceEvent shape but share the
-- same handler-slot + setter + emitter boilerplate. Each module calls
-- Tracer.create() once at module-init to get its own isolated TracerInstance.

export type TracerInstance<Event> = {
	setHandler: (handler: ((Event) -> ())?) -> (),
	emit:       (event: Event) -> (),
	hasHandler: () -> boolean,
}

local function create<Event>(): TracerInstance<Event>
	local activeHandler: ((Event) -> ())? = nil

	local instance: TracerInstance<Event> = {
		setHandler = function(handler: ((Event) -> ())?)
			activeHandler = handler
		end,
		emit = function(event: Event)
			if activeHandler then
				activeHandler(event)
			end
		end,
		hasHandler = function(): boolean
			return activeHandler ~= nil
		end,
	}

	return instance
end

return table.freeze({
	create = create,
})

