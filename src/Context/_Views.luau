--!strict

local Types = require(script.Parent._Types)


type ContextPrivateState = Types.ContextPrivateState


local Views = {}


function Views.GetVisibleKeySetFromValidatedKeyList(validatedKeyList: { unknown }): { [any]: true }
	local visibleKeySet = {}

	for _, key in validatedKeyList do
		visibleKeySet[key] = true
	end

	return visibleKeySet :: any
end

function Views.ContextPrivateStateCanSeeKey(contextPrivateState: ContextPrivateState, key: unknown): boolean
	local visibleKeySet = contextPrivateState.VisibleKeySet

	return visibleKeySet == nil or visibleKeySet[key] == true
end


return table.freeze(Views)

