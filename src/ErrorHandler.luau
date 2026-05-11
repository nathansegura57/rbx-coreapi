--!strict

local ErrorHandler = {}

export type Policy = "Throw" | "Warn" | "Swallow" | "Collect"

export type ErrorInfo = {
	Phase: string,
	Module: string,
	Name: string?,
	Message: string?,
	Error: unknown,
}

-- Enum table: users reference ErrorHandler.Policy.Throw etc. instead of raw strings.
local _policyEnum = table.freeze({
	Throw = "Throw" :: "Throw",
	Warn = "Warn" :: "Warn",
	Swallow = "Swallow" :: "Swallow",
	Collect = "Collect" :: "Collect",
})

local VALID_POLICIES: { [string]: boolean } = {
	Throw = true,
	Warn = true,
	Swallow = true,
	Collect = true,
}

local _policy: Policy = "Throw"
local _reporter: ((ErrorInfo) -> ())? = nil
local _collected: { ErrorInfo } = {}
local _reporterRunning = false

local function buildMessage(info: ErrorInfo): string
	local location = if info.Name ~= nil
		then `{info.Module}.{info.Phase}[{info.Name}]`
		else `{info.Module}.{info.Phase}`
	local message = if info.Message ~= nil
		then info.Message
		else tostring(info.Error)
	return `{location}: {message}`
end

function ErrorHandler.SetPolicy(policy: Policy): ()
	if VALID_POLICIES[policy] ~= true then
		error(`ErrorHandler.SetPolicy: invalid policy '{tostring(policy)}'`)
	end
	_policy = policy
end

function ErrorHandler.GetPolicy(): Policy
	return _policy
end

function ErrorHandler.SetReporter(fn: ((ErrorInfo) -> ())?): ()
	if fn ~= nil and type(fn) ~= "function" then
		error("ErrorHandler.SetReporter: reporter must be a function or nil")
	end
	_reporter = fn
end

function ErrorHandler.Report(info: ErrorInfo): ()
	-- Cast to untyped map for runtime validation: callers may bypass the type checker.
	local untyped = info :: { [string]: unknown }
	if type(untyped) ~= "table" then
		error("ErrorHandler.Report: info must be a table")
	end
	if type(untyped.Phase) ~= "string" then
		error("ErrorHandler.Report: Phase must be a string")
	end
	if type(untyped.Module) ~= "string" then
		error("ErrorHandler.Report: Module must be a string")
	end
	-- Iterate keys to distinguish "Error key absent" from "Error = nil" (rawget cannot).
	local hasErrorKey = false
	for k in untyped do
		if k == "Error" then
			hasErrorKey = true
			break
		end
	end
	if not hasErrorKey then
		error("ErrorHandler.Report: Error is required")
	end
	if untyped.Name ~= nil and type(untyped.Name) ~= "string" then
		error("ErrorHandler.Report: Name must be a string or nil")
	end
	if untyped.Message ~= nil and type(untyped.Message) ~= "string" then
		error("ErrorHandler.Report: Message must be a string or nil")
	end

	local reporter = _reporter
	if reporter ~= nil and not _reporterRunning then
		_reporterRunning = true
		local ok, err = pcall(reporter, info)
		_reporterRunning = false
		if not ok then
			warn(`ErrorHandler: reporter failed: {tostring(err)}`)
		end
	end

	local policy = _policy
	if policy == "Throw" then
		error(buildMessage(info))
	elseif policy == "Warn" then
		warn(buildMessage(info))
	elseif policy == "Collect" then
		table.insert(_collected, info)
	end
	-- "Swallow": nothing after reporter
end

-- Runs fn(); if it errors, routes through Report and returns (false, err).
-- Returns (true, result) on success. Useful when the return value matters.
function ErrorHandler.Protect(fn: () -> any, module: string, phase: string, name: string?): (boolean, any)
	local ok, result = pcall(fn)
	if not ok then
		ErrorHandler.Report({ Module = module, Phase = phase, Name = name, Error = result })
		return false, result
	end
	return true, result
end

function ErrorHandler.TakeCollected(): { ErrorInfo }
	local result = _collected
	_collected = {}
	return result
end

ErrorHandler.Policy = _policyEnum

return ErrorHandler
