--!strict

local Validation = {}


function Validation.ensureCallback(untrustedCallback: unknown, usageErrorMessage: string): ()
	if type(untrustedCallback) ~= "function" then
		error(usageErrorMessage, 3)
	end
end

function Validation.ensureNonNegativeSeconds(untrustedSeconds: unknown, usageErrorMessage: string): number
	if type(untrustedSeconds) == "number" and untrustedSeconds >= 0 then
		return untrustedSeconds
	end

	error(usageErrorMessage, 3)
end

function Validation.ensurePositiveSeconds(untrustedSeconds: unknown, usageErrorMessage: string): number
	if type(untrustedSeconds) == "number" and untrustedSeconds > 0 then
		return untrustedSeconds
	end

	error(usageErrorMessage, 3)
end

function Validation.ensurePositiveInteger(untrustedNumber: unknown, usageErrorMessage: string): number
	if type(untrustedNumber) == "number"
		and untrustedNumber >= 1
		and untrustedNumber == math.floor(untrustedNumber)
	then
		return untrustedNumber
	end

	error(usageErrorMessage, 3)
end

function Validation.ensureNonNegativeInteger(untrustedNumber: unknown, usageErrorMessage: string): number
	if type(untrustedNumber) == "number"
		and untrustedNumber >= 0
		and untrustedNumber == math.floor(untrustedNumber)
	then
		return untrustedNumber
	end

	error(usageErrorMessage, 3)
end


return table.freeze(Validation)

