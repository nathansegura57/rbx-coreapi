--!strict

local Types = require(script.Parent._Types)

type Concurrency = Types.Concurrency
type Overflow = Types.Overflow
type Schedule = Types.Schedule
type Policy = Types.Policy
type PartialPolicy = Types.PartialPolicy

local Policy = {}

local knownPolicyKeys: { [string]: boolean } = table.freeze({
	Concurrency = true,
	Capacity = true,
	Overflow = true,
	Cooldown = true,
	Debounce = true,
	Throttle = true,
	Leading = true,
	Trailing = true,
	Schedule = true,
	RecheckGuardBeforeRun = true,
	CancelTasksWhenGuardFalse = true,
	Once = true,
	ErrorPolicy = true,
	Retry = true,
	Trace = true,
	Tag = true,
})

function Policy.createDefaultPolicy(): Policy
	return {
		Concurrency = "Exhaust",
		Capacity = math.huge,
		Overflow = "Drop",
		Cooldown = nil,
		Debounce = nil,
		Throttle = nil,
		Leading = true,
		Trailing = true,
		Schedule = "Deferred",
		RecheckGuardBeforeRun = false,
		CancelTasksWhenGuardFalse = false,
		Once = false,
		ErrorPolicy = nil,
		Retry = nil,
		Trace = false,
		Tag = nil,
	}
end

function Policy.validatePolicy(policy: PartialPolicy): (boolean, string?)
	if typeof(policy) ~= "table" then
		return false, "policy must be a table"
	end

	for policyKey in policy :: any do
		if not knownPolicyKeys[policyKey] then
			return false, `unknown policy key: {tostring(policyKey)}`
		end
	end

	local concurrency = policy.Concurrency

	if concurrency ~= nil
		and concurrency ~= "Exhaust"
		and concurrency ~= "Merge"
		and concurrency ~= "Concat"
		and concurrency ~= "Switch"
	then
		return false, "Concurrency must be 'Exhaust', 'Merge', 'Concat', or 'Switch'"
	end

	local capacity = policy.Capacity

	if capacity ~= nil and (typeof(capacity) ~= "number" or (capacity <= 0 and capacity ~= math.huge)) then
		return false, "Capacity must be a positive number"
	end

	local overflow = policy.Overflow

	if overflow ~= nil
		and overflow ~= "Drop"
		and overflow ~= "Latest"
		and overflow ~= "Fifo"
	then
		return false, "Overflow must be 'Drop', 'Latest', or 'Fifo'"
	end

	local effectiveConcurrency = if concurrency ~= nil then concurrency else "Exhaust"
	local effectiveOverflow = if overflow ~= nil then overflow else "Drop"

	if effectiveConcurrency == "Merge" and effectiveOverflow ~= "Drop" then
		return false, "Merge concurrency only supports Overflow 'Drop'"
	end

	local cooldown = policy.Cooldown

	if cooldown ~= nil and (typeof(cooldown) ~= "number" or cooldown < 0) then
		return false, "Cooldown must be >= 0"
	end

	local debounce = policy.Debounce

	if debounce ~= nil and (typeof(debounce) ~= "number" or debounce < 0) then
		return false, "Debounce must be >= 0"
	end

	local throttle = policy.Throttle

	if throttle ~= nil and (typeof(throttle) ~= "number" or throttle <= 0) then
		return false, "Throttle must be > 0"
	end

	if policy.Leading ~= nil and typeof(policy.Leading) ~= "boolean" then
		return false, "Leading must be a boolean"
	end

	if policy.Trailing ~= nil and typeof(policy.Trailing) ~= "boolean" then
		return false, "Trailing must be a boolean"
	end

	local schedule = policy.Schedule

	if schedule ~= nil and schedule ~= "Immediate" and schedule ~= "Deferred" then
		return false, "Schedule must be 'Immediate' or 'Deferred'"
	end

	if policy.RecheckGuardBeforeRun ~= nil and typeof(policy.RecheckGuardBeforeRun) ~= "boolean" then
		return false, "RecheckGuardBeforeRun must be a boolean"
	end

	if policy.CancelTasksWhenGuardFalse ~= nil and typeof(policy.CancelTasksWhenGuardFalse) ~= "boolean" then
		return false, "CancelTasksWhenGuardFalse must be a boolean"
	end

	if policy.Once ~= nil and typeof(policy.Once) ~= "boolean" then
		return false, "Once must be a boolean"
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

	local retry = policy.Retry

	if retry ~= nil then
		if typeof(retry) ~= "table" then
			return false, "Retry must be a table"
		end

		local retryCount = retry.Count

		if typeof(retryCount) ~= "number" or retryCount < 1 or math.floor(retryCount) ~= retryCount then
			return false, "Retry.Count must be a positive integer"
		end

		local retryBackoff = retry.Backoff

		if retryBackoff ~= "Fixed" and retryBackoff ~= "Expo" then
			return false, "Retry.Backoff must be 'Fixed' or 'Expo'"
		end

		local retryBase = retry.Base

		if typeof(retryBase) ~= "number" or retryBase < 0 then
			return false, "Retry.Base must be >= 0"
		end

		local retryJitter = retry.Jitter

		if retryJitter ~= nil and (typeof(retryJitter) ~= "number" or retryJitter < 0) then
			return false, "Retry.Jitter must be >= 0"
		end
	end

	if policy.Trace ~= nil and typeof(policy.Trace) ~= "boolean" then
		return false, "Trace must be a boolean"
	end

	if policy.Tag ~= nil and typeof(policy.Tag) ~= "string" then
		return false, "Tag must be a string"
	end

	return true, nil
end

return table.freeze(Policy)

