--!strict

local Types = require(script.Parent._Types)

local Policy = {}

local KNOWN_FSM_POLICY_KEYS: { [string]: boolean } = {
	SingleSwitchPerFrame = true,
	CancelTasksOnExit = true,
	ExitOrdering = true,
	Deferral = true,
	ErrorPolicy = true,
	Trace = true,
	Tag = true,
}

Policy.ExitOrdering = table.freeze({
	LeafFirst = "LeafFirst" :: "LeafFirst",
	ParentFirst = "ParentFirst" :: "ParentFirst",
})

Policy.Deferral = table.freeze({
	Queue = "Queue" :: "Queue",
	Drop = "Drop" :: "Drop",
})

function Policy.MakeDefaultPolicy(): Types.Policy
	return {
		SingleSwitchPerFrame = true,
		CancelTasksOnExit = true,
		ExitOrdering = Policy.ExitOrdering.LeafFirst,
		Deferral = Policy.Deferral.Queue,
		ErrorPolicy = nil,
		Trace = false,
		Tag = nil,
	}
end

function Policy.ValidatePolicy(policy: Types.PartialPolicy): (boolean, string?)
	if type(policy) ~= "table" then
		return false, "policy must be a table"
	end

	for key in policy do
		if not KNOWN_FSM_POLICY_KEYS[key :: any] then
			return false, "unknown policy key: " .. tostring(key)
		end
	end

	local singleSwitchPerFrame = policy.SingleSwitchPerFrame

	if singleSwitchPerFrame ~= nil and type(singleSwitchPerFrame) ~= "boolean" then
		return false, "SingleSwitchPerFrame must be a boolean"
	end

	local cancelTasksOnExit = policy.CancelTasksOnExit

	if cancelTasksOnExit ~= nil and type(cancelTasksOnExit) ~= "boolean" then
		return false, "CancelTasksOnExit must be a boolean"
	end

	local exitOrdering = policy.ExitOrdering

	if exitOrdering ~= nil
		and exitOrdering ~= Policy.ExitOrdering.LeafFirst
		and exitOrdering ~= Policy.ExitOrdering.ParentFirst
	then
		return false, "ExitOrdering must be 'LeafFirst' or 'ParentFirst'"
	end

	local deferral = policy.Deferral

	if deferral ~= nil
		and deferral ~= Policy.Deferral.Queue
		and deferral ~= Policy.Deferral.Drop
	then
		return false, "Deferral must be 'Queue' or 'Drop'"
	end

	local errorPolicy = policy.ErrorPolicy

	if errorPolicy ~= nil
		and errorPolicy ~= "Throw"
		and errorPolicy ~= "Warn"
		and errorPolicy ~= "Swallow"
		and errorPolicy ~= "Collect"
	then
		return false, "ErrorPolicy must be 'Throw', 'Warn', 'Swallow', or 'Collect'"
	end

	local trace = policy.Trace

	if trace ~= nil and type(trace) ~= "boolean" then
		return false, "Trace must be a boolean"
	end

	local tag = policy.Tag

	if tag ~= nil and type(tag) ~= "string" then
		return false, "Tag must be a string"
	end

	return true, nil
end

return table.freeze(Policy)

