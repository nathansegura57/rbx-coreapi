--!strict

local Validation = {}

function Validation.raiseUsageError(message: string): never
	error(message, 3)
end

function Validation.ensureValueIsFunction(value: unknown, message: string): ()
	if typeof(value) ~= "function" then
		Validation.raiseUsageError(message)
	end
end

function Validation.ensureValueIsTableOrNil(value: unknown, message: string): ()
	if value ~= nil and typeof(value) ~= "table" then
		Validation.raiseUsageError(message)
	end
end

function Validation.ensureValueIsStringOrNil(value: unknown, message: string): ()
	if value ~= nil and typeof(value) ~= "string" then
		Validation.raiseUsageError(message)
	end
end

function Validation.ensureValueIsPositiveNumber(value: unknown, message: string): ()
	if typeof(value) ~= "number" or value <= 0 then
		Validation.raiseUsageError(message)
	end
end

function Validation.ensureValueIsNonNegativeNumber(value: unknown, message: string): ()
	if typeof(value) ~= "number" or value < 0 then
		Validation.raiseUsageError(message)
	end
end

function Validation.ensureValueIsPositiveInteger(value: unknown, message: string): ()
	if typeof(value) ~= "number" or value <= 0 or value % 1 ~= 0 then
		Validation.raiseUsageError(message)
	end
end

function Validation.ensureValueIsNonNegativeNumberOrNil(value: unknown, message: string): ()
	if value ~= nil and (typeof(value) ~= "number" or value < 0) then
		Validation.raiseUsageError(message)
	end
end

function Validation.ensureValueIsBooleanOrNil(value: unknown, message: string): ()
	if value ~= nil and typeof(value) ~= "boolean" then
		Validation.raiseUsageError(message)
	end
end

function Validation.ensureArrayIsNonEmptyDense(array: unknown, message: string): { any }
	if typeof(array) ~= "table" or next(array :: any) == nil then
		Validation.raiseUsageError(message)
	end

	for index = 1, #(array :: any) do
		if (array :: { any })[index] == nil then
			Validation.raiseUsageError(message)
		end
	end

	return array :: { any }
end

return table.freeze(Validation)

