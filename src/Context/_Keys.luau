--!strict

local Records = require(script.Parent._Records)
local Validation = require(script.Parent._Validation)
local Types = require(script.Parent._Types)


type ContextKey<Value> = Types.ContextKey<Value>


local Keys = {}


function Keys.CreateContextKey<Value>(name: string): ContextKey<Value>
	local validatedName = Validation.GetValidatedKeyName(name)

	return Records.CreateContextKeyHandle(validatedName)
end


return table.freeze(Keys)

