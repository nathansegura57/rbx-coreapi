--!strict

local Factories = {}

local ErrorHandler = require(script.Parent.Parent.ErrorHandler)
local Records = require(script.Parent._Records)
local Notifications = require(script.Parent._Notifications)
local Types = require(script.Parent._Types)
local Validation = require(script.Parent._Validation)

type ReadableStore<Value> = Types.ReadableStore<Value>
type WritableStore<Value> = Types.WritableStore<Value>
type ValueOptions<Value> = Types.ValueOptions<Value>
type DeriveOptions<Value> = Types.DeriveOptions<Value>
type StoreRecord = Types.StoreRecord

function Factories.Value<Value>(initialValue: Value, options: ValueOptions<Value>?): WritableStore<Value>
	local valueOptions = Validation.GetValidatedValueOptions("Store.Value", options)

	Validation.EnsureNameCanBeRegistered("Store.Value", valueOptions.Name, valueOptions.ReplaceName)

	local storeHandle = Records.CreateStoreHandle("value")
	local storeRecord = Records.GetRequiredStoreRecord(storeHandle, "Store.Value: failed to create store")

	storeRecord.Value = initialValue
	storeRecord.Name = valueOptions.Name
	storeRecord.Equals = valueOptions.Equals

	if valueOptions.Name ~= nil then
		Records.RegisterNamedStore(valueOptions.Name, storeHandle)
	end

	return storeHandle :: WritableStore<Value>
end

function Factories.Const<Value>(value: Value): ReadableStore<Value>
	local storeHandle = Records.CreateStoreHandle("const")
	local storeRecord = Records.GetRequiredStoreRecord(storeHandle, "Store.Const: failed to create store")

	storeRecord.Value = value

	return storeHandle :: ReadableStore<Value>
end

function Factories.Derive<Value>(
	computeValue: () -> Value,
	dependencies: { ReadableStore<any> },
	options: DeriveOptions<Value>?
): ReadableStore<Value>
	if type(computeValue) ~= "function" then
		error("Store.Derive: compute must be a function", 2)
	end

	local dependencyHandles = Validation.EnsureDependencyArrayIsValid(
		"Store.Derive",
		dependencies,
		function(index: number): string
			return `Store.Derive: dep at index {index} is not a live Store`
		end
	)

	local valueOptions = Validation.GetValidatedValueOptions("Store.Derive", options)

	Validation.EnsureNameCanBeRegistered("Store.Derive", valueOptions.Name, valueOptions.ReplaceName)

	local initialComputeSucceeded, initialValue, initialComputeError = ErrorHandler.Protect(function(): Value
		return computeValue()
	end, "Store", "Derive", "InitialCompute")

	if not initialComputeSucceeded then
		error(`Store.Derive: initial compute failed: {tostring(initialComputeError)}`, 2)
	end

	local storeHandle = Records.CreateStoreHandle("derived")
	local storeRecord = Records.GetRequiredStoreRecord(storeHandle, "Store.Derive: failed to create store")

	storeRecord.Value = initialValue
	storeRecord.Compute = computeValue :: () -> any
	storeRecord.Name = valueOptions.Name
	storeRecord.Equals = valueOptions.Equals

	for index, dependencyStore in dependencyHandles do
		storeRecord.Dependencies[index] = dependencyStore

		local dependencyRecord = Records.GetRequiredStoreRecord(dependencyStore, "Store.Derive: dependency was destroyed")
		table.insert(dependencyRecord.DerivedConsumers, storeHandle)
	end

	if valueOptions.Name ~= nil then
		Records.RegisterNamedStore(valueOptions.Name, storeHandle)
	end

	return storeHandle :: ReadableStore<Value>
end

function Factories.Select<InputValue, SelectedValue>(
	sourceStore: ReadableStore<InputValue>,
	selectValue: (InputValue) -> SelectedValue,
	valuesAreEqual: ((SelectedValue, SelectedValue) -> boolean)?
): ReadableStore<SelectedValue>
	Validation.EnsureValueIsLiveStore(sourceStore, "Store.Select: source must be a live Store")

	if type(selectValue) ~= "function" then
		error("Store.Select: picker must be a function", 2)
	end

	if valuesAreEqual ~= nil and type(valuesAreEqual) ~= "function" then
		error("Store.Select: equals must be a function or nil", 2)
	end

	local capturedSourceStore = sourceStore

	return Factories.Derive(function(): SelectedValue
		local sourceRecord = Records.GetRequiredStoreRecord(capturedSourceStore, "Store.Select: source must be a live Store")
		return selectValue(sourceRecord.Value :: InputValue)
	end, { sourceStore :: ReadableStore<any> }, if valuesAreEqual ~= nil then {
		Equals = valuesAreEqual :: (any, any) -> boolean,
	} else nil)
end

function Factories.Combine(values: { [any]: ReadableStore<any> }): ReadableStore<{ any }>
	if type(values) ~= "table" then
		error("Store.Combine: input must be a table", 2)
	end

	local inputValues = values :: { [any]: any }
	local entryCount = 0

	for _ in inputValues do
		entryCount += 1
	end

	if entryCount == 0 then
		error("Store.Combine: input must not be empty", 2)
	end

	local arrayLength = #(inputValues :: { any })
	local inputIsArray = entryCount == arrayLength and arrayLength > 0
	local dependencies = {}

	if inputIsArray then
		for index = 1, arrayLength do
			local entryStore = inputValues[index]
			Validation.EnsureValueIsLiveStore(entryStore, `Store.Combine: entry at index {index} is not a live Store`)
			dependencies[index] = entryStore
		end

		return Factories.Derive(function(): { any }
			local combinedValues = table.create(#dependencies)

			for index, dependencyStore in dependencies do
				combinedValues[index] = Records.GetRequiredStoreRecord(dependencyStore, "Store.Combine: dependency destroyed").Value
			end

			return combinedValues
		end, dependencies :: { ReadableStore<any> })
	end

	local keys = {}
	local storesByKey = {}

	for key, entryStore in inputValues do
		Validation.EnsureValueIsLiveStore(entryStore, `Store.Combine: value for key '{tostring(key)}' is not a live Store`)
		table.insert(keys, key)
		table.insert(dependencies, entryStore)
		storesByKey[key] = entryStore
	end

	return Factories.Derive(function(): { any }
		local combinedValues = {}

		for _, key in keys do
			combinedValues[key] = Records.GetRequiredStoreRecord(storesByKey[key], "Store.Combine: dependency destroyed").Value
		end

		return combinedValues
	end, dependencies :: { ReadableStore<any> })
end

function Factories.AllTruthy(stores: { ReadableStore<any> }): ReadableStore<boolean>
	local storeArray = Validation.EnsureStoreArrayIsValid("Store.AllTruthy", stores)

	return Factories.Derive(function(): boolean
		for _, storeHandle in storeArray do
			if not Records.GetRequiredStoreRecord(storeHandle, "Store.AllTruthy: dependency destroyed").Value then
				return false
			end
		end

		return true
	end, storeArray :: { ReadableStore<any> })
end

function Factories.AnyTruthy(stores: { ReadableStore<any> }): ReadableStore<boolean>
	local storeArray = Validation.EnsureStoreArrayIsValid("Store.AnyTruthy", stores)

	return Factories.Derive(function(): boolean
		for _, storeHandle in storeArray do
			if Records.GetRequiredStoreRecord(storeHandle, "Store.AnyTruthy: dependency destroyed").Value then
				return true
			end
		end

		return false
	end, storeArray :: { ReadableStore<any> })
end

function Factories.Match(sourceStore: ReadableStore<any>, cases: { [any]: ReadableStore<any> }): ReadableStore<any>
	Validation.EnsureValueIsLiveStore(sourceStore, "Store.Match: source must be a live Store")

	if type(cases) ~= "table" then
		error("Store.Match: cases must be a table", 2)
	end

	local caseStoresByKey = {}
	local dependencies = { sourceStore :: ReadableStore<any> }

	for key, caseStore in cases do
		Validation.EnsureValueIsLiveStore(caseStore, `Store.Match: case '{tostring(key)}' is not a live Store`)
		caseStoresByKey[key] = caseStore
		table.insert(dependencies, caseStore :: ReadableStore<any>)
	end

	local initialKey = Records.GetRequiredStoreRecord(sourceStore, "Store.Match: source must be a live Store").Value
	local initialCaseStore = caseStoresByKey[initialKey] or caseStoresByKey["_"]

	if initialCaseStore == nil then
		error("Store.Match: initial case not found and no default '_' case", 2)
	end

	local lastResolvedValue: any = nil
	local hasResolvedAtLeastOnce = false

	return Factories.Derive(function(): any
		local sourceKey = Records.GetRequiredStoreRecord(sourceStore, "Store.Match: source must be a live Store").Value
		local caseStore = caseStoresByKey[sourceKey] or caseStoresByKey["_"]

		if caseStore == nil then
			ErrorHandler.Report({
				Module = "Store",
				Phase = "Match",
				Message = `No case exists for key '{tostring(sourceKey)}'`,
				Error = ErrorHandler.NoError,
			})

			if hasResolvedAtLeastOnce then
				return lastResolvedValue
			end

			error("Store.Match: no case found", 0)
		end

		lastResolvedValue = Records.GetRequiredStoreRecord(caseStore, "Store.Match: case store was destroyed").Value
		hasResolvedAtLeastOnce = true

		return lastResolvedValue
	end, dependencies)
end

function Factories.Readonly<Value>(store: ReadableStore<Value>): ReadableStore<Value>
	local sourceRecord = Validation.EnsureValueIsLiveStore(store, "Store.Readonly: store must be a live Store")
	local storeHandle = Records.CreateStoreHandle("readonly")
	local storeRecord = Records.GetRequiredStoreRecord(storeHandle, "Store.Readonly: failed to create store")

	storeRecord.Value = sourceRecord.Value
	storeRecord.Compute = function(): any
		return Records.GetRequiredStoreRecord(store, "Store.Readonly: source store destroyed").Value
	end
	storeRecord.Dependencies = { store :: any }

	table.insert(sourceRecord.DerivedConsumers, storeHandle)

	return storeHandle :: ReadableStore<Value>
end

return Factories

