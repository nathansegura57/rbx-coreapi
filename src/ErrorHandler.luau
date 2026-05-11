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
	local raw: any = policy
	if VALID_POLICIES[raw] ~= true then
		error(`ErrorHandler.SetPolicy: invalid policy '{tostring(raw)}'`)
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
	local raw: any = info
	if type(raw) ~= "table" then
		error("ErrorHandler.Report: info must be a table")
	end
	if type(raw.Phase) ~= "string" then
		error("ErrorHandler.Report: Phase must be a string")
	end
	if type(raw.Module) ~= "string" then
		error("ErrorHandler.Report: Module must be a string")
	end
	if rawget(raw, "Error") == nil then
		error("ErrorHandler.Report: Error is required")
	end
	if raw.Name ~= nil and type(raw.Name) ~= "string" then
		error("ErrorHandler.Report: Name must be a string or nil")
	end
	if raw.Message ~= nil and type(raw.Message) ~= "string" then
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

function ErrorHandler.TakeCollected(): { ErrorInfo }
	local result = _collected
	_collected = {}
	return result
end

return ErrorHandler
