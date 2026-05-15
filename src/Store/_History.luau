--!strict

local History = {}

local Connection = require(script.Parent.Parent.Connection)
local Factories = require(script.Parent._Factories)
local InstanceMethods = require(script.Parent._InstanceMethods)
local Records = require(script.Parent._Records)
local Types = require(script.Parent._Types)
local Validation = require(script.Parent._Validation)

type WritableStore<Value> = Types.WritableStore<Value>
type ReadableStore<Value> = Types.ReadableStore<Value>
type History<Value> = Types.History<Value>

function History.Create<Value>(store: WritableStore<Value>, limit: number?): History<Value>
	local storeRecord = Validation.EnsureValueIsLiveStore(store, "Store.History: store must be a writable live Store")

	if storeRecord.Kind ~= "value" then
		error("Store.History: store must be a writable live Store", 2)
	end

	local undoLimit = if limit == nil then 100 else Validation.EnsurePositiveInteger(
		limit,
		"Store.History: limit must be a positive integer or nil"
	)

	type HistoryEntry = {
		Value: Value,
	}

	local undoStack: { HistoryEntry } = {}
	local redoStack: { HistoryEntry } = {}
	local canUndo = Factories.Value(false)
	local canRedo = Factories.Value(false)
	local applyingHistoryChange = false
	local historyIsDestroyed = false

	local function updateHistoryAvailabilityStores(): ()
		InstanceMethods.Set(canUndo, #undoStack > 0)
		InstanceMethods.Set(canRedo, #redoStack > 0)
	end

	local subscription = InstanceMethods.Subscribe(store, function(_newValue: Value, oldValue: Value?): ()
		if applyingHistoryChange then
			return
		end

		table.insert(undoStack, {
			Value = oldValue :: Value,
		})

		while #undoStack > undoLimit do
			table.remove(undoStack, 1)
		end

		table.clear(redoStack)
		updateHistoryAvailabilityStores()
	end, {
		Immediate = false,
	})

	return {
		CanUndo = canUndo :: ReadableStore<boolean>,
		CanRedo = canRedo :: ReadableStore<boolean>,

		Undo = function(): boolean
			if historyIsDestroyed or #undoStack == 0 then
				return false
			end

			local undoEntry = table.remove(undoStack, #undoStack) :: HistoryEntry
			local currentStoreRecord = Records.GetRequiredStoreRecord(store, "Store.History: store is destroyed")

			table.insert(redoStack, {
				Value = currentStoreRecord.Value :: Value,
			})

			applyingHistoryChange = true
			InstanceMethods.Set(store, undoEntry.Value)
			applyingHistoryChange = false

			updateHistoryAvailabilityStores()
			return true
		end,

		Redo = function(): boolean
			if historyIsDestroyed or #redoStack == 0 then
				return false
			end

			local redoEntry = table.remove(redoStack, #redoStack) :: HistoryEntry
			local currentStoreRecord = Records.GetRequiredStoreRecord(store, "Store.History: store is destroyed")

			table.insert(undoStack, {
				Value = currentStoreRecord.Value :: Value,
			})

			applyingHistoryChange = true
			InstanceMethods.Set(store, redoEntry.Value)
			applyingHistoryChange = false

			updateHistoryAvailabilityStores()
			return true
		end,

		Clear = function(): ()
			table.clear(undoStack)
			table.clear(redoStack)
			updateHistoryAvailabilityStores()
		end,

		Destroy = function(): ()
			if historyIsDestroyed then
				return
			end

			historyIsDestroyed = true
			subscription:Disconnect()
			InstanceMethods.Destroy(canUndo)
			InstanceMethods.Destroy(canRedo)
		end,
	}
end

return History

