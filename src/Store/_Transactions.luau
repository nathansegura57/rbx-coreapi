--!strict

local Transactions = {}

local ErrorHandler = require(script.Parent.Parent.ErrorHandler)
local Notifications = require(script.Parent._Notifications)

function Transactions.Batch(block: () -> ()): ()
	if type(block) ~= "function" then
		ErrorHandler.RaiseUsageError("Store.Batch: block must be a function")
	end

	Notifications.EnterBatch()

	local blockSucceeded, blockError = pcall(function() block() end)

	Notifications.LeaveBatchAndFlushIfOutermost()

	if not blockSucceeded then
		ErrorHandler.Report({
			Module = "Store",
			Phase = "Batch",
			Error = blockError,
		})
	end
end

function Transactions.Transaction(block: () -> ()): ()
	if type(block) ~= "function" then
		ErrorHandler.RaiseUsageError("Store.Transaction: block must be a function")
	end

	Notifications.EnterTransaction()

	local blockSucceeded, blockError = pcall(function() block() end)

	Notifications.LeaveTransactionAndScheduleFlushIfOutermost()

	if not blockSucceeded then
		ErrorHandler.Report({
			Module = "Store",
			Phase = "Transaction",
			Error = blockError,
		})
	end
end

return table.freeze(Transactions)

