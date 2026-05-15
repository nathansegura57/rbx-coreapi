--!strict

local Snapshots = {}

local InstanceMethods = require(script.Parent._InstanceMethods)
local Records = require(script.Parent._Records)
local Transactions = require(script.Parent._Transactions)
local Types = require(script.Parent._Types)
local Validation = require(script.Parent._Validation)

type ReadableStore<Value> = Types.ReadableStore<Value>
type Snapshot = Types.Snapshot
type RestoreOptions = Types.RestoreOptions

function Snapshots.Snapshot(...: ReadableStore<any>): Snapshot
	local snapshot: Snapshot = {}
	local stores = { ... }

	for _, store in stores do
		local storeRecord = Validation.EnsureValueIsLiveStore(store, "Store.Snapshot: all arguments must be live Stores")

		if storeRecord.Name ~= nil then
			snapshot[storeRecord.Name] = storeRecord.Value
		else
			snapshot[store :: any] = storeRecord.Value
		end
	end

	return snapshot
end

function Snapshots.Restore(snapshot: Snapshot, options: RestoreOptions?): ()
	if type(snapshot) ~= "table" then
		error("Store.Restore: snapshot must be a table", 2)
	end

	local strict = Validation.GetValidatedRestoreStrictOption(options)

	Transactions.Transaction(function()
		for key, value in snapshot do
			if type(key) ~= "string" then
				if strict then
					error("Store.Restore: snapshot contains unnamed store entry which is not restorable")
				end

				continue
			end

			local storeHandle = Records.GetNamedStore(key)

			if storeHandle == nil then
				if strict then
					error(`Store.Restore: unknown store '{key}'`)
				end

				continue
			end

			local storeRecord = Records.GetStoreRecord(storeHandle)

			if storeRecord == nil or storeRecord.Destroyed then
				if strict then
					error(`Store.Restore: store '{key}' is destroyed`)
				end
			elseif storeRecord.Kind ~= "value" then
				if strict then
					error(`Store.Restore: store '{key}' is not writable`)
				end
			else
				InstanceMethods.Set(storeHandle, value)
			end
		end
	end)
end

return Snapshots

