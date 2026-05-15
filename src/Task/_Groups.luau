--!strict

local Runtime = require(script.Parent._Runtime)
local Constructors = require(script.Parent._Constructors)
local Combinators = require(script.Parent._Combinators)

local Groups = {}

function Groups.Create(options: Runtime.GroupOptions?): Runtime.TaskGroup
	local groupName = Runtime.ValidateGroupOptions(options, "Task.Group")
	local group = Runtime.CreateGroupRecord(groupName)
	return group
end

-- Group instance methods live in _Runtime because they operate directly on the
-- private task/group registries. The public constructor stays here so the parent
-- facade can read as a declaration of the Task API surface.

return table.freeze(Groups)

