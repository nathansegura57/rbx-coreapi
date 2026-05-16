--!strict

local ErrorHandler = require(script.Parent.Parent.ErrorHandler)

local Validation = {}


function Validation.ensureCallback(untrustedCallback: unknown, usageErrorMessage: string): ()
	if type(untrustedCallback) ~= "function" then
		return ErrorHandler.RaiseUsageError(usageErrorMessage)
	end
end

function Validation.ensureNonNegativeSeconds(untrustedSeconds: unknown, usageErrorMessage: string): number
	if type(untrustedSeconds) == "number" and untrustedSeconds >= 0 then
		return untrustedSeconds
	end

	return ErrorHandler.RaiseUsageError(usageErrorMessage)
end

function Validation.ensurePositiveSeconds(untrustedSeconds: unknown, usageErrorMessage: string): number
	if type(untrustedSeconds) == "number" and untrustedSeconds > 0 then
		return untrustedSeconds
	end

	return ErrorHandler.RaiseUsageError(usageErrorMessage)
end

function Validation.ensurePositiveInteger(untrustedNumber: unknown, usageErrorMessage: string): number
	if type(untrustedNumber) == "number"
		and untrustedNumber >= 1
		and untrustedNumber == math.floor(untrustedNumber)
	then
		return untrustedNumber
	end

	return ErrorHandler.RaiseUsageError(usageErrorMessage)
end

function Validation.ensureNonNegativeInteger(untrustedNumber: unknown, usageErrorMessage: string): number
	if type(untrustedNumber) == "number"
		and untrustedNumber >= 0
		and untrustedNumber == math.floor(untrustedNumber)
	then
		return untrustedNumber
	end

	return ErrorHandler.RaiseUsageError(usageErrorMessage)
end


return table.freeze(Validation)
